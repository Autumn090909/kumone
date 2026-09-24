import Foundation
import JavaScriptCore
import os.log

/// File-scope so it is reachable from the native-bridge closures, which are not
/// actor-isolated. `Logger` is `Sendable`, so this needs no synchronisation.
private let lxScriptLog = Logger(subsystem: "im.missuo.kumone", category: "custom-source")

/// One source a script declared in its `inited` event. LX keys these by
/// platform (`kw` / `kg` / `tx` / `wy` / `mg` / `local`); a NetEase client only
/// ever asks for `wy`.
struct LXDeclaredSource: Hashable {
    let key: String
    let name: String
    let type: String
    let actions: [String]
    let qualities: [String]
}

struct LXMusicURL {
    let url: URL
    let quality: String?
}

/// Translates Kumone's NetEase quality levels onto the four labels LX defines.
///
/// The mapping is a preference list rather than a single value because a script
/// usually supports a subset — a 320k-only source still has to answer a Hi-Res
/// request — so the list is intersected with what the script declared.
enum LXQuality {
    static let all: [String] = ["128k", "320k", "flac", "flac24bit"]

    static func preference(for quality: AudioQuality) -> [String] {
        switch quality {
        case .standard: return ["128k", "320k", "flac", "flac24bit"]
        case .higher: return ["320k", "128k", "flac", "flac24bit"]
        case .exhigh: return ["320k", "128k", "flac", "flac24bit"]
        case .lossless: return ["flac", "320k", "128k", "flac24bit"]
        case .hires: return ["flac24bit", "flac", "320k", "128k"]
        }
    }

    static func select(from declared: [String], for quality: AudioQuality) -> String? {
        let available = Set(declared)
        for candidate in preference(for: quality) where available.contains(candidate) {
            return candidate
        }
        // A script that declares nothing recognisable still gets asked once, at
        // the quality it claims rather than at one it never mentioned.
        return declared.first
    }
}

enum LXScriptRuntimeError: LocalizedError {
    case initializationFailed(String)
    case initializationTimedOut
    case notInitialized
    case noNetEaseSource
    case unsupportedAction(String)
    case scriptFailure(String)
    case invalidReturnedURL(String)

    var errorDescription: String? {
        switch self {
        case .initializationFailed(let detail):
            return String(localized: "脚本初始化失败：\(detail)")
        case .initializationTimedOut:
            return String(localized: "脚本初始化超时（未收到 inited 事件）")
        case .notInitialized:
            return String(localized: "脚本尚未初始化")
        case .noNetEaseSource:
            return String(localized: "该脚本没有声明网易云（wy）音源")
        case .unsupportedAction(let action):
            return String(localized: "该脚本不支持 \(action) 操作")
        case .scriptFailure(let detail):
            return detail
        case .invalidReturnedURL(let value):
            return String(localized: "脚本返回了无效的音频地址：\(value)")
        }
    }
}

/// Runs one LX-Music custom-source script.
///
/// The lifecycle mirrors LX's own: build a context, evaluate the script, wait
/// for its `inited` event to learn what it can do, then answer `request` events
/// by calling the handler the script registered. `lx.request` inside the script
/// is served by a real `URLSession`, and `lx.utils.crypto` / `zlib` by `LXCrypto`.
///
/// Confined to the main actor because `JSContext` is not thread-safe. The work
/// per track is short JS plus an await on network I/O the script itself started,
/// so nothing here blocks the UI for a meaningful interval.
@MainActor
final class LXScriptRuntime {
    /// How long a script may take to publish `inited`. LX has no timeout of its
    /// own, but a script that never initialises must not wedge playback.
    private static let initializationTimeout: TimeInterval = 8
    /// Per-action ceiling: the built-in sources' 10s request budget plus room for
    /// a script that makes several hops.
    private static let actionTimeout: TimeInterval = 25

    /// LX's key for 网易云音乐.
    private static let netEaseSourceKey = "wy"

    let scriptKey: String
    let metadata: LXScriptMetadata
    private(set) var declaredSources: [LXDeclaredSource] = []
    private(set) var isInitialized = false

    /// Every quality label any declared source supports, for Settings.
    var declaredQualityLabels: [String] {
        var seen = Set<String>()
        var labels: [String] = []
        for source in declaredSources {
            for quality in source.qualities where seen.insert(quality).inserted {
                labels.append(quality)
            }
        }
        return labels
    }

    private let script: String
    private let context: JSContext
    private let http: LXHTTPBridge

    private var hasReceivedInited = false
    private var initWaiter: CheckedContinuation<Void, Error>?
    private var initFailure: Error?

    private var actionWaiters: [Int: CheckedContinuation<String, Error>] = [:]
    private var actionTimeouts: [Int: Task<Void, Never>] = [:]
    private var actionSequence = 1

    private var timers: [Int: Timer] = [:]
    private var isShutDown = false

    init(scriptKey: String, script: String) throws {
        guard let context = JSContext() else {
            throw LXScriptRuntimeError.initializationFailed("无法创建 JavaScript 运行环境")
        }
        self.scriptKey = scriptKey
        self.script = script
        self.metadata = LXScriptMetadata.parse(from: script)
        self.context = context
        self.http = LXHTTPBridge(scriptKey: scriptKey)
        installBridges()
        evaluatePrelude()
        publishScriptInfo()
    }

    // MARK: - Lifecycle

    func initialize() async throws {
        guard !isInitialized else { return }

        context.exception = nil
        _ = context.evaluateScript(script)
        if let exception = context.exception, !exception.isUndefined {
            context.exception = nil
            throw LXScriptRuntimeError.initializationFailed(describe(exception))
        }

        if !hasReceivedInited {
            try await awaitInited()
        }
        isInitialized = true
        guard !declaredSources.isEmpty else {
            throw LXScriptRuntimeError.initializationFailed("脚本没有声明任何音源")
        }
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true

        for timer in timers.values { timer.invalidate() }
        timers.removeAll()
        for timeout in actionTimeouts.values { timeout.cancel() }
        actionTimeouts.removeAll()

        let pendingActions = actionWaiters
        actionWaiters.removeAll()
        for continuation in pendingActions.values {
            continuation.resume(throwing: LXScriptRuntimeError.scriptFailure("脚本已卸载"))
        }
        if let waiter = initWaiter {
            initWaiter = nil
            waiter.resume(throwing: LXScriptRuntimeError.scriptFailure("脚本已卸载"))
        }
        http.shutdown()
    }

    private func evaluatePrelude() {
        context.exception = nil
        _ = context.evaluateScript(LXRuntimePrelude.source)
        if let exception = context.exception, !exception.isUndefined {
            lxScriptLog.error(
                "script=\(self.scriptKey, privacy: .public) prelude-failed detail=\(self.describe(exception), privacy: .public)"
            )
        }
        context.exception = nil
    }

    /// Fills `lx.currentScriptInfo` before the script itself is evaluated, so a
    /// source that reports its own name or version at load time reads real values
    /// instead of the prelude's empty defaults. LX populates this field too, and
    /// published sources do read it.
    private func publishScriptInfo() {
        let payload: [String: String] = [
            "name": metadata.name ?? "",
            "description": metadata.summary ?? "",
            "version": metadata.version ?? "",
            "author": metadata.author ?? "",
            "homepage": metadata.homepage ?? "",
            "rawScript": script,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return }
        callJS("__kumoneSetScriptInfo", arguments: [json])
    }

    private func awaitInited() async throws {
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.initializationTimeout * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.hasReceivedInited else { return }
            self.failInitialization(LXScriptRuntimeError.initializationTimedOut)
        }
        defer { timeout.cancel() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if let failure = initFailure {
                continuation.resume(throwing: failure)
                return
            }
            if hasReceivedInited {
                // The script published `inited` while evaluating; the deferred
                // bridge hop already landed before we got here.
                continuation.resume()
                return
            }
            initWaiter = continuation
        }
    }

    private func failInitialization(_ error: Error) {
        guard !hasReceivedInited else { return }
        initFailure = error
        guard let waiter = initWaiter else { return }
        initWaiter = nil
        waiter.resume(throwing: error)
    }

    // MARK: - Acting on a track

    func musicURL(for track: Track, requestedQuality: AudioQuality) async throws -> LXMusicURL? {
        guard isInitialized else { throw LXScriptRuntimeError.notInitialized }
        guard let declared = declaredSources.first(where: { $0.key == Self.netEaseSourceKey }) else {
            throw LXScriptRuntimeError.noNetEaseSource
        }
        guard declared.actions.contains("musicUrl") else {
            throw LXScriptRuntimeError.unsupportedAction("musicUrl")
        }

        let quality = LXQuality.select(from: declared.qualities, for: requestedQuality)
        let encoded = try await runAction(
            sourceKey: Self.netEaseSourceKey,
            action: "musicUrl",
            quality: quality,
            track: track
        )
        return try LXMusicURLParser.parse(encoded)
    }

    private func runAction(
        sourceKey: String,
        action: String,
        quality: String?,
        track: Track
    ) async throws -> String {
        guard let dispatch = context.objectForKeyedSubscript("__kumoneRunAction"),
              !dispatch.isUndefined
        else {
            throw LXScriptRuntimeError.initializationFailed("运行环境缺少 __kumoneRunAction")
        }

        let id = actionSequence
        actionSequence += 1

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            actionWaiters[id] = continuation

            let timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.actionTimeout * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.settleAction(id: id, error: "脚本响应超时", encoded: nil)
            }
            actionTimeouts[id] = timeout

            context.exception = nil
            _ = dispatch.call(withArguments: [
                id,
                sourceKey,
                action,
                quality ?? NSNull(),
                musicInfoJSON(for: track),
            ])
            if let exception = context.exception, !exception.isUndefined {
                context.exception = nil
                settleAction(id: id, error: describe(exception), encoded: nil)
            }
        }
    }

    private func settleAction(id: Int, error: String?, encoded: String?) {
        actionTimeouts.removeValue(forKey: id)?.cancel()
        guard let continuation = actionWaiters.removeValue(forKey: id) else { return }
        if let error, !error.isEmpty {
            continuation.resume(throwing: LXScriptRuntimeError.scriptFailure(error))
        } else {
            continuation.resume(returning: encoded ?? "null")
        }
    }

    /// The `musicInfo` LX hands a script. NetEase sources in the wild read `id`,
    /// `songmid`, `name` and `interval`, so all of them are populated even
    /// though they carry the same track.
    private func musicInfoJSON(for track: Track) -> String {
        var info: [String: Any] = [
            "source": Self.netEaseSourceKey,
            "id": track.id,
            "songmid": String(track.id),
            "name": track.name,
            "singer": track.artistNames,
            "albumName": track.album.name,
            "albumId": track.album.id,
            "albumMid": "",
            "interval": Self.interval(ms: track.durationMS),
            "duration": track.durationMS,
            "copyrightId": "",
            "hash": "",
            "types": [],
            "_types": [String: Any](),
            "typeUrl": [String: Any](),
        ]
        if let primary = track.artists.first {
            info["singerId"] = String(primary.id)
        }
        if let alias = track.alias.first {
            info["alias"] = alias
        }

        guard let data = try? JSONSerialization.data(withJSONObject: info),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }

    nonisolated private static func interval(ms: Int) -> String {
        guard ms > 0 else { return "00:00" }
        let totalSeconds = ms / 1_000
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func describe(_ exception: JSValue) -> String {
        if let message = exception.objectForKeyedSubscript("message")?.toString(), !message.isEmpty {
            if let line = exception.objectForKeyedSubscript("line")?.toInt32(), line > 0 {
                return "\(message)（第 \(line) 行）"
            }
            return message
        }
        return exception.toString() ?? "未知错误"
    }

    // MARK: - Native bridge

    /// The bridge is deliberately split by what each entry point needs:
    ///
    /// - hash / AES / RSA / random are pure, so they answer synchronously out of
    ///   `LXCrypto` and never touch actor state;
    /// - everything that does touch this runtime hops back onto the main actor
    ///   through a `Task`, which keeps the `@convention(block)` closures free of
    ///   isolation assumptions — JavaScriptCore only ever calls them from the
    ///   main thread anyway, because that is the only place we evaluate JS.
    private func installBridges() {
        let key = scriptKey

        context.exceptionHandler = { _, exception in
            guard let exception else { return }
            lxScriptLog.error(
                "script=\(key, privacy: .public) uncaught detail=\(exception.toString() ?? "", privacy: .public)"
            )
        }

        let httpStart: @convention(block) (Double, String, String) -> Void = { [weak self] id, url, options in
            Task { @MainActor in
                self?.http.start(id: Int(id), url: url, optionsJSON: options) { requestID, error, json in
                    Task { @MainActor in
                        self?.callHTTPComplete(id: requestID, error: error, json: json)
                    }
                }
            }
        }
        let httpCancel: @convention(block) (Double) -> Void = { [weak self] id in
            Task { @MainActor in self?.http.cancel(id: Int(id)) }
        }
        let log: @convention(block) (String, String) -> Void = { consoleLevel, message in
            let trimmed = message.count > 2_000 ? String(message.prefix(2_000)) : message
            let severity: OSLogType
            switch consoleLevel {
            case "error": severity = .error
            case "warn": severity = .default
            default: severity = .debug
            }
            lxScriptLog.log(
                level: severity,
                "script=\(key, privacy: .public) console=\(consoleLevel, privacy: .public) \(trimmed, privacy: .public)"
            )
        }
        let emit: @convention(block) (String, String) -> Void = { [weak self] event, payload in
            Task { @MainActor in self?.handleEmit(event, payload: payload) }
        }
        let md5: @convention(block) (String) -> String = { input in
            LXCrypto.md5Hex(input)
        }
        let randomBytes: @convention(block) (Double) -> String = { size in
            Self.envelope { try LXCrypto.randomBytes(Int(size)).base64EncodedString() }
        }
        let aes: @convention(block) (String, String, String, String, Bool) -> String = { data, mode, key, iv, encrypt in
            Self.envelope {
                guard let payload = Self.decodeBase64(data),
                      let keyData = Self.decodeBase64(key)
                else { throw LXCryptoError.notBase64 }
                let parsed = try LXCrypto.parseAESMode(mode, keyByteCount: keyData.count)
                let ivData = iv.isEmpty ? nil : Self.decodeBase64(iv)
                let output = try LXCrypto.aes(
                    payload,
                    mode: parsed.mode,
                    key: keyData,
                    iv: ivData,
                    encrypt: encrypt
                )
                return output.base64EncodedString()
            }
        }
        let rsa: @convention(block) (String, String) -> String = { data, pem in
            Self.envelope {
                guard let payload = Self.decodeBase64(data) else { throw LXCryptoError.notBase64 }
                return try LXCrypto.rsaPublicEncrypt(payload, pem: pem).base64EncodedString()
            }
        }
        let zlibRun: @convention(block) (Double, String, String) -> Void = { [weak self] id, operation, payload in
            Task { @MainActor in self?.runZlib(id: Int(id), operation: operation, payload: payload) }
        }
        let timerStart: @convention(block) (Double, Double, Bool) -> Void = { [weak self] id, delay, repeats in
            Task { @MainActor in self?.startTimer(id: Int(id), delayMS: delay, repeats: repeats) }
        }
        let timerClear: @convention(block) (Double) -> Void = { [weak self] id in
            Task { @MainActor in self?.stopTimer(id: Int(id)) }
        }
        let actionSettled: @convention(block) (Double, String?, String?) -> Void = { [weak self] id, error, encoded in
            Task { @MainActor in
                guard let self else { return }
                self.settleAction(
                    id: Int(id),
                    error: Self.bridgeText(error),
                    encoded: Self.bridgeText(encoded)
                )
            }
        }

        context.setObject(httpStart, forKeyedSubscript: "__knHttpStart" as NSString)
        context.setObject(httpCancel, forKeyedSubscript: "__knHttpCancel" as NSString)
        context.setObject(log, forKeyedSubscript: "__knLog" as NSString)
        context.setObject(emit, forKeyedSubscript: "__knEmit" as NSString)
        context.setObject(md5, forKeyedSubscript: "__knCryptoMD5" as NSString)
        context.setObject(randomBytes, forKeyedSubscript: "__knCryptoRandomBytes" as NSString)
        context.setObject(aes, forKeyedSubscript: "__knCryptoAES" as NSString)
        context.setObject(rsa, forKeyedSubscript: "__knCryptoRSA" as NSString)
        context.setObject(zlibRun, forKeyedSubscript: "__knZlibRun" as NSString)
        context.setObject(timerStart, forKeyedSubscript: "__knTimerStart" as NSString)
        context.setObject(timerClear, forKeyedSubscript: "__knTimerClear" as NSString)
        context.setObject(actionSettled, forKeyedSubscript: "__knActionSettled" as NSString)
    }

    /// Crypto and zlib answer through a JSON envelope rather than by throwing: a
    /// Swift error must never unwind across the JavaScriptCore boundary.
    nonisolated private static func envelope(_ body: () throws -> String) -> String {
        let payload: [String: Any]
        do {
            payload = ["ok": true, "value": try body()]
        } catch {
            payload = ["ok": false, "error": error.localizedDescription]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else {
            return #"{"ok":false,"error":"bridge serialization failed"}"#
        }
        return json
    }

    nonisolated private static func decodeBase64(_ value: String) -> Data? {
        if value.isEmpty { return Data() }
        return Data(base64Encoded: value, options: [.ignoreUnknownCharacters])
    }

    /// Reads a `String?` parameter that JavaScript handed across the block
    /// boundary.
    ///
    /// JavaScriptCore does **not** bridge the JavaScript `null` it is given to
    /// Swift's `nil`: it arrives as the four-character string `"null"`. A
    /// successful `actionSettled(id, null, encoded)` would therefore be read as
    /// a failure whose message is literally `null`, which is exactly what the
    /// runtime tests caught. Normalising here — rather than only on the JS side
    /// — keeps the bridge honest no matter which of `null` / `undefined` / `''`
    /// a script's promise chain happens to hand us.
    nonisolated private static func bridgeText(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value != "null", value != "undefined" else {
            return nil
        }
        return value
    }

    // MARK: - Inbound events

    private func handleEmit(_ event: String, payload: String) {
        switch event {
        case "inited":
            parseDeclarations(payload)
            hasReceivedInited = true
            if let waiter = initWaiter {
                initWaiter = nil
                waiter.resume()
            }
        case "updateAlert":
            lxScriptLog.notice(
                "script=\(self.scriptKey, privacy: .public) updateAlert payload=\(payload, privacy: .public)"
            )
        default:
            break
        }
    }

    private func parseDeclarations(_ payload: String) {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sources = object["sources"] as? [String: Any]
        else { return }

        // Sorted so Settings and the quality summary are deterministic across
        // runs; a dictionary's enumeration order is not.
        declaredSources = sources.compactMap { key, value in
            guard let value = value as? [String: Any] else { return nil }
            return LXDeclaredSource(
                key: key,
                name: value["name"] as? String ?? "",
                type: value["type"] as? String ?? "music",
                actions: value["actions"] as? [String] ?? [],
                // LX's published field name is `qualitys` — the missing "i" is
                // part of the API, not a typo on our side, and every real script
                // emits it that way. `qualities` is accepted as well because a
                // fair number of hand-written sources "correct" the spelling;
                // reading only one of the two silently produces an empty
                // quality list, which leaves every request asking for `null`.
                qualities: value["qualitys"] as? [String]
                    ?? value["qualities"] as? [String]
                    ?? []
            )
        }
        .sorted { $0.key < $1.key }
    }

    // MARK: - zlib

    private func runZlib(id: Int, operation: String, payload: String) {
        let result: Result<Data, Error>
        if let data = Self.decodeBase64(payload) {
            result = Result {
                switch operation {
                case "deflate": return try LXCrypto.deflate(data)
                default: return try LXCrypto.inflate(data)
                }
            }
        } else {
            result = .failure(LXCryptoError.notBase64)
        }

        switch result {
        case .success(let data):
            callJS("__kumoneZlibComplete", arguments: [id, NSNull(), data.base64EncodedString()])
        case .failure(let error):
            callJS("__kumoneZlibComplete", arguments: [id, error.localizedDescription, NSNull()])
        }
    }

    // MARK: - Timers

    private func startTimer(id: Int, delayMS: Double, repeats: Bool) {
        timers.removeValue(forKey: id)?.invalidate()
        let interval = max(0, delayMS) / 1_000
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats) { [weak self] fired in
            Task { @MainActor in
                guard let self else {
                    fired.invalidate()
                    return
                }
                if !repeats { self.timers.removeValue(forKey: id) }
                self.callJS("__kumoneTimerFire", arguments: [id])
            }
        }
        timers[id] = timer
    }

    private func stopTimer(id: Int) {
        timers.removeValue(forKey: id)?.invalidate()
    }

    // MARK: - Outbound calls

    private func callHTTPComplete(id: Int, error: String?, json: String?) {
        guard !isShutDown else { return }
        callJS("__kumoneHTTPComplete", arguments: [id, error ?? NSNull(), json ?? NSNull()])
    }

    private func callJS(_ function: String, arguments: [Any]) {
        guard !isShutDown else { return }
        context.exception = nil
        _ = context.objectForKeyedSubscript(function)?.call(withArguments: arguments)
        if let exception = context.exception, !exception.isUndefined {
            context.exception = nil
            lxScriptLog.error(
                "script=\(self.scriptKey, privacy: .public) callback=\(function, privacy: .public) detail=\(self.describe(exception), privacy: .public)"
            )
        }
    }
}

/// Parses whatever a script's `musicUrl` handler resolved to. LX documents a
/// plain URL string, but a good number of published sources return
/// `{ url, quality }`, so both shapes are accepted.
enum LXMusicURLParser {
    static func parse(_ encoded: String) throws -> LXMusicURL? {
        guard encoded != "null", !encoded.isEmpty else { return nil }
        guard let data = encoded.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { throw LXScriptRuntimeError.scriptFailure("脚本返回了无法解析的数据") }

        var urlString: String?
        var quality: String?
        if let string = value as? String {
            urlString = string
        } else if let object = value as? [String: Any] {
            if let candidate = object["url"] as? String { urlString = candidate }
            quality = object["quality"] as? String
        }

        // A `null` result is the script saying "I have no source for this
        // track" — a miss, not a failure, so the next source gets its turn.
        guard let urlString, !urlString.isEmpty else { return nil }

        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { throw LXScriptRuntimeError.invalidReturnedURL(urlString) }

        return LXMusicURL(url: url, quality: quality)
    }
}

/// A minimal `URLSession` wrapper backing the script-facing `lx.request`.
///
/// One session per script, and specifically *not* the app's: a script keeps its
/// own cookies across calls (several sources log in first), but it can never see
/// or overwrite the NetEase session cookies Kumone itself uses.
@MainActor
private final class LXHTTPBridge {
    typealias Completion = (_ id: Int, _ error: String?, _ responseJSON: String?) -> Void

    private let session: URLSession
    private var tasks: [Int: URLSessionDataTask] = [:]

    init(scriptKey: String) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        // `ephemeral` gives the script a private cookie jar, which is exactly
        // the boundary wanted here.
        self.session = URLSession(configuration: configuration)
        _ = scriptKey
    }

    func start(id: Int, url: String, optionsJSON: String, completion: @escaping Completion) {
        guard let url = URL(string: url) else {
            completion(id, "无效的请求地址", nil)
            return
        }
        let options = LXRequestOptions(json: optionsJSON)

        do {
            let request = try options.makeRequest(url: url)
            let task = session.dataTask(with: request) { data, response, error in
                let encoded = Self.encodeResponse(
                    data: data,
                    response: response as? HTTPURLResponse,
                    error: error
                )
                Task { @MainActor in
                    completion(id, encoded.error, encoded.json)
                }
            }
            tasks[id] = task
            task.resume()
        } catch {
            completion(id, error.localizedDescription, nil)
        }
    }

    func cancel(id: Int) {
        tasks.removeValue(forKey: id)?.cancel()
    }

    func shutdown() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        session.invalidateAndCancel()
    }

    private struct EncodedResponse {
        let error: String?
        let json: String?
    }

    /// `nonisolated` because the URLSession completion runs off the main actor;
    /// nothing here reads bridge state.
    nonisolated private static func encodeResponse(
        data: Data?,
        response: HTTPURLResponse?,
        error: Error?
    ) -> EncodedResponse {
        if let error {
            return EncodedResponse(error: error.localizedDescription, json: nil)
        }
        guard let response else {
            return EncodedResponse(error: "没有收到 HTTP 响应", json: nil)
        }

        let raw = decode(data ?? Data(), response: response)
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            headers["\(key)"] = "\(value)"
        }

        var envelope: [String: Any] = [
            "statusCode": response.statusCode,
            "statusMessage": HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
            "headers": headers,
            "raw": raw,
        ]
        // LX hands scripts a parsed body when the response is JSON, so sources
        // can read `resp.body.xxx` directly.
        envelope["body"] = jsonObject(from: raw) ?? raw

        guard let encoded = try? JSONSerialization.data(withJSONObject: envelope),
              let json = String(data: encoded, encoding: .utf8)
        else {
            return EncodedResponse(error: "响应无法编码", json: nil)
        }
        return EncodedResponse(error: nil, json: json)
    }

    nonisolated private static func jsonObject(from raw: String) -> Any? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    nonisolated private static func decode(_ data: Data, response: HTTPURLResponse) -> String {
        if let charset = response.textEncodingName {
            let encoding = CFStringConvertEncodingToNSStringEncoding(
                CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            )
            if encoding != kCFStringEncodingInvalidId,
               let decoded = String(data: data, encoding: String.Encoding(rawValue: encoding)) {
                return decoded
            }
        }
        if let decoded = String(data: data, encoding: .utf8) { return decoded }
        // Last resort for the occasional GBK payload a source forgot to label.
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        if let decoded = String(data: data, encoding: gb18030) { return decoded }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The subset of `lx.request`'s options object this bridge honours.
private struct LXRequestOptions {
    var method: String = "get"
    var headers: [String: String] = [:]
    var body: String?
    var form: [String: String]?
    var formData: [String: String]?
    var timeout: TimeInterval = 0

    init(json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let method = object["method"] as? String, !method.isEmpty { self.method = method }
        if let timeout = object["timeout"] as? Double, timeout > 0 { self.timeout = timeout / 1_000 }

        if let headers = object["headers"] as? [String: Any] {
            var parsed: [String: String] = [:]
            for (key, value) in headers {
                parsed[key] = value is NSNull ? "" : "\(value)"
            }
            self.headers = parsed
        }
        if let body = object["body"] as? String { self.body = body }
        if let form = object["form"] as? [String: Any] {
            var parsed: [String: String] = [:]
            for (key, value) in form { parsed[key] = value is NSNull ? "" : "\(value)" }
            self.form = parsed
        }
        if let formData = object["formData"] as? [String: Any] {
            var parsed: [String: String] = [:]
            for (key, value) in formData { parsed[key] = value is NSNull ? "" : "\(value)" }
            self.formData = parsed
        }
    }

    func makeRequest(url: URL) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method.uppercased()
        if timeout > 0 { request.timeoutInterval = timeout }

        // Body and the two form encodings are mutually exclusive; the more
        // specific one wins so a script that sets several still sends something
        // the server can parse.
        if let formData, !formData.isEmpty {
            let boundary = "----KumoneBoundary\(UUID().uuidString)"
            var body = ""
            for (key, value) in formData.sorted(by: { $0.key < $1.key }) {
                body += "--\(boundary)\r\n"
                body += "Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n"
                body += "\(value)\r\n"
            }
            body += "--\(boundary)--\r\n"
            request.httpBody = Data(body.utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue(
                    "multipart/form-data; boundary=\(boundary)",
                    forHTTPHeaderField: "Content-Type"
                )
            }
        } else if let form, !form.isEmpty {
            var components = URLComponents()
            components.queryItems = form
                .sorted(by: { $0.key < $1.key })
                .map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        } else if let body {
            request.httpBody = Data(body.utf8)
        }

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        }
        return request
    }
}
