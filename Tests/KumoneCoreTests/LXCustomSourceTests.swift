import Foundation
import JavaScriptCore
import Testing
@testable import KumoneCore

@Suite("LX custom source tests")
struct LXCustomSourceTests {

    // MARK: - Metadata

    @Test func parsesTheLXJSDocHeader() {
        let metadata = LXScriptMetadata.parse(from: Self.echoScript)

        #expect(metadata.name == "回声音源")
        #expect(metadata.author == "unit-test")
        #expect(metadata.version == "1.0.0")
    }

    @Test func ignoresAnAtNameOutsideTheHeader() {
        let script = """
        /**
         * @name 真名
         */
        // @name 假名
        const a = 1
        """

        #expect(LXScriptMetadata.parse(from: script).name == "真名")
    }

    @Test func leavesMissingHeaderFieldsEmpty() {
        let metadata = LXScriptMetadata.parse(from: "const a = 1")

        #expect(metadata.name == nil)
        #expect(metadata.author == nil)
        #expect(metadata.homepage == nil)
    }

    @Test func doesNotSwallowTheNextLineForAValueLessKey() {
        let script = """
        /**
         * @name
         * @author bob
         */
        """

        let metadata = LXScriptMetadata.parse(from: script)
        #expect(metadata.name == nil)
        #expect(metadata.author == "bob")
    }

    // MARK: - Quality negotiation

    @Test func selectsTheBestDeclaredQualityForTheRequestedLevel() {
        let declared = ["128k", "320k"]

        #expect(LXQuality.select(from: declared, for: .standard) == "128k")
        #expect(LXQuality.select(from: declared, for: .exhigh) == "320k")
        // A 320k-only source still has to answer a Hi-Res request.
        #expect(LXQuality.select(from: ["320k"], for: .hires) == "320k")
        #expect(LXQuality.select(from: ["flac24bit", "flac"], for: .lossless) == "flac")
        #expect(LXQuality.select(from: ["flac24bit", "flac"], for: .hires) == "flac24bit")
    }

    @Test func fallsBackToWhateverTheScriptDeclared() {
        // Nothing recognisable: the script still gets asked once, at the quality
        // it claims, rather than at one it never mentioned.
        #expect(LXQuality.select(from: ["hq"], for: .hires) == "hq")
        #expect(LXQuality.select(from: [], for: .hires) == nil)
    }

    // MARK: - Return-value shapes

    @Test func parsesBothReturnShapes() throws {
        #expect(try LXMusicURLParser.parse("\"https://cdn.invalid/a.mp3\"")?.url.absoluteString
            == "https://cdn.invalid/a.mp3")
        #expect(try LXMusicURLParser.parse("\"https://cdn.invalid/b.flac\"")?.quality == nil)

        let rich = try LXMusicURLParser.parse(
            "{\"url\":\"https://cdn.invalid/c.flac\",\"quality\":\"flac\"}"
        )
        #expect(rich?.url.absoluteString == "https://cdn.invalid/c.flac")
        #expect(rich?.quality == "flac")
    }

    @Test func treatsNullAsAMiss() throws {
        // A miss, not a failure: the next source in line must get its turn.
        #expect(try LXMusicURLParser.parse("null") == nil)
        #expect(try LXMusicURLParser.parse("{\"url\":null}") == nil)
    }

    @Test func rejectsNonHTTPResults() {
        #expect(throws: LXScriptRuntimeError.self) {
            _ = try LXMusicURLParser.parse("\"file:///etc/passwd\"")
        }
    }

    // MARK: - Crypto primitives

    @Test func md5MatchesTheKnownVector() {
        #expect(LXCrypto.md5Hex("abc") == "900150983cd24fb0d6963f7d28e17f72")
        #expect(LXCrypto.md5Hex("") == "d41d8cd98f00b204e9800998ecf8427e")
    }

    @Test func aesCBCRoundTripsWithPKCS7Padding() throws {
        let key = Data(repeating: 0x11, count: 16)
        let iv = Data(repeating: 0x22, count: 16)
        let plaintext = Data("kumone custom source".utf8)

        let cipher = try LXCrypto.aes(plaintext, mode: .cbc, key: key, iv: iv, encrypt: true)
        #expect(cipher != plaintext)
        // PKCS#7 pads to the block size, and 20 bytes of input needs a full pad block.
        #expect(cipher.count == 32)

        let restored = try LXCrypto.aes(cipher, mode: .cbc, key: key, iv: iv, encrypt: false)
        #expect(restored == plaintext)
    }

    @Test func aesECBDoesNotNeedAnIV() throws {
        let key = Data(repeating: 0x33, count: 32)
        let plaintext = Data("kumone".utf8)

        let cipher = try LXCrypto.aes(plaintext, mode: .ecb, key: key, iv: nil, encrypt: true)
        let restored = try LXCrypto.aes(cipher, mode: .ecb, key: key, iv: nil, encrypt: false)
        #expect(restored == plaintext)
    }

    @Test func aesCBCWithoutAnIVIsRefused() {
        #expect(throws: LXCryptoError.self) {
            _ = try LXCrypto.aes(
                Data("kumone".utf8),
                mode: .cbc,
                key: Data(repeating: 0, count: 16),
                iv: nil,
                encrypt: true
            )
        }
    }

    @Test func parsesNodeStyleAESModes() throws {
        #expect(try LXCrypto.parseAESMode("aes-128-cbc", keyByteCount: 16).mode == .cbc)
        #expect(try LXCrypto.parseAESMode("aes-256-ecb", keyByteCount: 32).mode == .ecb)
        // No size in the name: the supplied key decides.
        #expect(try LXCrypto.parseAESMode("aes-cbc", keyByteCount: 24).keyLength == 24)
    }

    @Test func rejectsMismatchedOrUnknownAESModes() {
        #expect(throws: LXCryptoError.self) {
            _ = try LXCrypto.parseAESMode("aes-128-cbc", keyByteCount: 32)
        }
        #expect(throws: LXCryptoError.self) {
            _ = try LXCrypto.parseAESMode("chacha20-poly1305", keyByteCount: 32)
        }
    }

    @Test func zlibRoundTripsThroughItsWrapper() throws {
        let payload = Data(String(repeating: "kumone", count: 512).utf8)

        let deflated = try LXCrypto.deflate(payload)
        // zlib wrapper: 0x78 0x9C header, raw DEFLATE, 4-byte Adler-32 trailer.
        #expect(deflated.prefix(2) == Data([0x78, 0x9C]))
        #expect(deflated.count < payload.count)

        #expect(try LXCrypto.inflate(deflated) == payload)
    }

    @Test func adler32MatchesTheKnownVector() {
        #expect(LXCrypto.adler32(Data("Wikipedia".utf8)) == 0x11E6_0398)
    }

    // MARK: - The JS prelude

    @MainActor
    @Test func preludeExposesTheLXSurface() throws {
        let context = try Self.makeStubbedContext()
        _ = context.evaluateScript(LXRuntimePrelude.source)

        let lx = try #require(context.objectForKeyedSubscript("lx"))
        #expect(lx.objectForKeyedSubscript("env")?.toString() == "desktop")
        #expect(lx.objectForKeyedSubscript("EVENT_NAMES")?
            .objectForKeyedSubscript("request")?.toString() == "request")
        #expect(lx.objectForKeyedSubscript("utils")?
            .objectForKeyedSubscript("crypto")?
            .objectForKeyedSubscript("md5")?.isUndefined == false)

        _ = context.evaluateScript(
            "__kumoneSetScriptInfo(JSON.stringify({ name: '脚本', author: 'me', rawScript: 'x' }))"
        )
        #expect(lx.objectForKeyedSubscript("currentScriptInfo")?
            .objectForKeyedSubscript("name")?.toString() == "脚本")
    }

    @MainActor
    @Test func preludeProvidesAWorkingBuffer() throws {
        let context = try Self.makeStubbedContext()
        _ = context.evaluateScript(LXRuntimePrelude.source)

        // Scripts are evaluated at global scope, so the shim has to leave the
        // prelude's IIFE: a `var Buffer` alone is invisible to them and every
        // real source calls bare `Buffer.from(...)`. Regression guard.
        #expect(context.objectForKeyedSubscript("Buffer")?.isUndefined == false)
        #expect(context.objectForKeyedSubscript("globalThis")?
            .objectForKeyedSubscript("Buffer")?.isUndefined == false)

        // The shim's whole point: Node's Buffer, which JavaScriptCore lacks.
        #expect(context.evaluateScript("Buffer.from('kumone').toString('base64')")?.toString()
            == "a3Vtb25l")
        #expect(context.evaluateScript("Buffer.from('a3Vtb25l', 'base64').toString('utf8')")?.toString()
            == "kumone")
        #expect(context.evaluateScript("Buffer.from('ff', 'hex')[0]")?.toInt32() == 255)
        #expect(context.evaluateScript("Buffer.concat([Buffer.from('ku'), Buffer.from('mone')]).toString()")?.toString()
            == "kumone")
        #expect(context.evaluateScript("Buffer.from('中文').length")?.toInt32() == 6)
    }

    /// Names a published source reaches for that JavaScriptCore does not
    /// provide. Each one is a shim, and a missing shim is the worst kind of
    /// failure: the script dies on a `ReferenceError` before it registers
    /// anything, so the user sees "this source does nothing" with no clue why.
    @MainActor
    @Test func preludeExposesTheEcosystemShims() throws {
        let context = try Self.makeStubbedContext()
        _ = context.evaluateScript(LXRuntimePrelude.source)

        // `module.exports` is a second entry point, not a nicety: a large share
        // of sources assign `musicUrl` there instead of registering a handler.
        #expect(context.evaluateScript("typeof module")?.toString() == "object")
        #expect(context.evaluateScript("exports === module.exports")?.toBool() == true)

        // Text-first cousins of `lx.request`, plus the namespace a second
        // family of sources reads instead of `lx`.
        #expect(context.evaluateScript("typeof customFetch")?.toString() == "function")
        #expect(context.evaluateScript("typeof fetch")?.toString() == "function")
        #expect(context.evaluateScript("typeof cerumusic")?.toString() == "object")
        #expect(context.evaluateScript("cerumusic.utils === lx.utils")?.toBool() == true)

        // Used by sources that race several mirrors.
        #expect(context.evaluateScript("typeof Promise.any")?.toString() == "function")

        // The shims must not displace what the prelude already published.
        #expect(context.evaluateScript("typeof Buffer")?.toString() == "function")
        #expect(context.evaluateScript("typeof setTimeout")?.toString() == "function")
        #expect(context.evaluateScript("typeof lx.request")?.toString() == "function")
    }

    // MARK: - The runtime, end to end and offline

    @MainActor
    @Test func runtimeInitialisesAndResolvesATrack() async throws {
        let runtime = try LXScriptRuntime(scriptKey: "unit-test", script: Self.echoScript)
        defer { runtime.shutdown() }

        try await runtime.initialize()
        #expect(runtime.declaredSources.map(\.key) == ["wy"])
        #expect(runtime.declaredQualityLabels == ["128k", "320k"])

        let track = try Self.makeTrack(id: 42, name: "测试歌曲", artist: "测试歌手", durationMS: 200_000)
        let resolved = try await runtime.musicURL(for: track, requestedQuality: .exhigh)

        #expect(resolved?.url.absoluteString == "https://example.invalid/42.mp3")
        #expect(resolved?.quality == "320k")
    }

    @MainActor
    @Test func runtimeRejectsAScriptWithoutANetEaseSource() async throws {
        let runtime = try LXScriptRuntime(scriptKey: "kugou-only", script: Self.kugouOnlyScript)
        defer { runtime.shutdown() }

        try await runtime.initialize()
        let track = try Self.makeTrack(id: 1, name: "歌", artist: "人", durationMS: 100_000)

        await #expect(throws: LXScriptRuntimeError.self) {
            _ = try await runtime.musicURL(for: track, requestedQuality: .standard)
        }
    }

    @MainActor
    @Test func runtimeSurfacesAHandlerRejection() async throws {
        // This is the path `UnblockService` depends on to move on to the next
        // source, so a rejection must arrive as an error and not as a crash or a
        // silent miss.
        let runtime = try LXScriptRuntime(scriptKey: "failing", script: Self.failingScript)
        defer { runtime.shutdown() }

        try await runtime.initialize()
        let track = try Self.makeTrack(id: 7, name: "歌", artist: "人", durationMS: 100_000)

        await #expect(throws: LXScriptRuntimeError.self) {
            _ = try await runtime.musicURL(for: track, requestedQuality: .standard)
        }
    }

    /// The host has to publish `lx.currentScriptInfo` before evaluating the
    /// script, and it has to mutate the object `lx` already captured — rebinding
    /// the binding would leave every script reading empty strings forever.
    @MainActor
    @Test func runtimePublishesScriptInfoBeforeTheScriptRuns() async throws {
        let runtime = try LXScriptRuntime(scriptKey: "info", script: Self.scriptInfoProbeScript)
        defer { runtime.shutdown() }

        try await runtime.initialize()
        let track = try Self.makeTrack(id: 1, name: "歌", artist: "人", durationMS: 100_000)
        let resolved = try await runtime.musicURL(for: track, requestedQuality: .standard)

        #expect(resolved?.url.absoluteString == "https://example.invalid/probe/3.1.4")
    }

    /// The prelude runs headlessly under Node with the same fixtures, so what a
    /// live `JSContext` adds here is proof that the *native* crypto and zlib
    /// bridges answer in the envelope the prelude parses: md5 raw, the rest as
    /// `{"ok":true,"value":...}`.
    @MainActor
    @Test func runtimeAnswersCryptoAndZlibInsideAScript() async throws {
        let runtime = try LXScriptRuntime(scriptKey: "bridges", script: Self.bridgeProbeScript)
        defer { runtime.shutdown() }

        try await runtime.initialize()
        let track = try Self.makeTrack(id: 1, name: "歌", artist: "人", durationMS: 100_000)
        let resolved = try await runtime.musicURL(for: track, requestedQuality: .standard)

        // md5 crosses the bridge raw; zlib round-trips through its envelope and
        // the Buffer it hands back decodes back to the original text.
        #expect(resolved?.url.absoluteString
            == "https://example.invalid/900150983cd24fb0d6963f7d28e17f72/kumone")
    }

    /// A script with no `lx.on` at all: `module.exports` is the only way in.
    /// Before the export was reachable, this shape of source initialised fine
    /// and then failed every request.
    @MainActor
    @Test func runtimeCallsTheExportedMusicURL() async throws {
        let runtime = try LXScriptRuntime(scriptKey: "exported", script: Self.exportedMusicURLScript)
        defer { runtime.shutdown() }

        try await runtime.initialize()
        let track = try Self.makeTrack(id: 7, name: "歌", artist: "人", durationMS: 100_000)
        let resolved = try await runtime.musicURL(for: track, requestedQuality: .exhigh)

        #expect(resolved?.url.absoluteString == "https://example.invalid/export/wy/7")
        #expect(resolved?.quality == "320k")
    }

    /// `MusicPlugin.getMusicUrl(source, id, type)` is the third shape in the
    /// wild, and the last one tried.
    @MainActor
    @Test func runtimeCallsTheMusicPluginEntryPoint() async throws {
        let runtime = try LXScriptRuntime(scriptKey: "plugin", script: Self.musicPluginScript)
        defer { runtime.shutdown() }

        try await runtime.initialize()
        let track = try Self.makeTrack(id: 13, name: "歌", artist: "人", durationMS: 100_000)
        let resolved = try await runtime.musicURL(for: track, requestedQuality: .standard)

        #expect(resolved?.url.absoluteString == "https://example.invalid/plugin/wy/13/320k")
    }

    /// Both routes present. The registered handler must keep winning, so every
    /// script that works today takes exactly the path it took before the export
    /// fallback existed.
    @MainActor
    @Test func runtimePrefersARegisteredHandlerOverAnExport() async throws {
        let runtime = try LXScriptRuntime(scriptKey: "both", script: Self.handlerAndExportScript)
        defer { runtime.shutdown() }

        try await runtime.initialize()
        let track = try Self.makeTrack(id: 1, name: "歌", artist: "人", durationMS: 100_000)
        let resolved = try await runtime.musicURL(for: track, requestedQuality: .standard)

        #expect(resolved?.url.absoluteString == "https://example.invalid/handler")
    }

    // MARK: - The store

    @MainActor
    @Test func storePersistsImportsTogglesAndOrder() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kumone-lx-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = CustomAudioSourceStore(directory: directory)
        #expect(store.sources.isEmpty)

        try store.importScript(Self.echoScript, fallbackName: "fallback")
        #expect(store.sources.count == 1)
        #expect(store.sources.first?.name == "回声音源")
        #expect(store.sources.first?.author == "unit-test")
        #expect(store.sources.first?.isEnabled == true)
        #expect(store.enabledProviders().count == 1)

        // Re-importing the same body must refresh, not duplicate.
        try store.importScript(Self.echoScript, fallbackName: "fallback")
        #expect(store.sources.count == 1)

        try store.importScript(Self.kugouOnlyScript, fallbackName: "second")
        #expect(store.sources.map(\.name) == ["回声音源", "只有酷狗"])

        let secondKey = try #require(store.sources.last?.id)
        store.move(scriptKey: secondKey, toIndex: 0)
        #expect(store.sources.map(\.name) == ["只有酷狗", "回声音源"])

        let firstKey = try #require(store.sources.last?.id)
        store.setEnabled(false, forScriptKey: firstKey)
        #expect(store.enabledProviders().map(\.scriptKey) == [secondKey])

        // A fresh store over the same directory sees what was persisted.
        let reloaded = CustomAudioSourceStore(directory: directory)
        #expect(reloaded.sources.map(\.name) == ["只有酷狗", "回声音源"])
        #expect(reloaded.sources.last?.isEnabled == false)

        store.remove(scriptKey: secondKey)
        #expect(store.sources.map(\.name) == ["回声音源"])
    }

    @MainActor
    @Test func storeRejectsAnEmptyScript() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kumone-lx-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = CustomAudioSourceStore(directory: directory)
        #expect(throws: CustomAudioSourceImportError.self) {
            try store.importScript("   \n  ", fallbackName: "空")
        }
    }

    // MARK: - Fixtures

    /// A script that needs no network, so the whole runtime can be exercised
    /// offline.
    private static let echoScript = """
    /**
     * @name 回声音源
     * @description 只用于单元测试
     * @version 1.0.0
     * @author unit-test
     */

    const { EVENT_NAMES, on, send } = globalThis.lx

    on(EVENT_NAMES.request, (payload) => {
      if (payload.action !== 'musicUrl') return Promise.resolve(null)
      return Promise.resolve({
        url: 'https://example.invalid/' + payload.info.musicInfo.id + '.mp3',
        quality: payload.info.type,
      })
    })

    send(EVENT_NAMES.inited, {
      status: true,
      sources: {
        wy: {
          name: '网易云',
          type: 'music',
          actions: ['musicUrl'],
          qualitys: ['128k', '320k'],
        },
      },
    })
    """

    private static let kugouOnlyScript = """
    /**
     * @name 只有酷狗
     * @author unit-test
     */

    const { EVENT_NAMES, on, send } = globalThis.lx

    on(EVENT_NAMES.request, () => Promise.resolve(null))

    send(EVENT_NAMES.inited, {
      status: true,
      sources: {
        kg: {
          name: '酷狗音乐',
          type: 'music',
          actions: ['musicUrl'],
          qualitys: ['320k'],
        },
      },
    })
    """

    private static let failingScript = """
    /**
     * @name 会失败的音源
     * @author unit-test
     */

    const { EVENT_NAMES, on, send } = globalThis.lx

    on(EVENT_NAMES.request, () => Promise.reject(new Error('no source for this track')))

    send(EVENT_NAMES.inited, {
      status: true,
      sources: {
        wy: {
          name: '网易云',
          type: 'music',
          actions: ['musicUrl'],
          qualitys: ['320k'],
        },
      },
    })
    """

    /// Reads the host-published script info at load time and echoes it back, so
    /// the assertion fails loudly if `__kumoneSetScriptInfo` never ran.
    private static let scriptInfoProbeScript = """
    /**
     * @name probe
     * @version 3.1.4
     * @author unit-test
     */

    const { EVENT_NAMES, on, send } = globalThis.lx

    const seenName = lx.currentScriptInfo.name
    const seenVersion = lx.currentScriptInfo.version

    on(EVENT_NAMES.request, () => Promise.resolve({
      url: 'https://example.invalid/' + seenName + '/' + seenVersion,
      quality: '128k',
    }))

    send(EVENT_NAMES.inited, {
      status: true,
      sources: {
        wy: {
          name: '网易云',
          type: 'music',
          actions: ['musicUrl'],
          qualitys: ['128k'],
        },
      },
    })
    """

    /// Exercises the bridges that answer through an envelope, plus the `Buffer`
    /// global a real LX source assumes it can reach without qualification.
    private static let bridgeProbeScript = """
    /**
     * @name 桥接探针
     * @author unit-test
     */

    const { EVENT_NAMES, on, send } = globalThis.lx

    on(EVENT_NAMES.request, async () => {
      const digest = lx.utils.crypto.md5('abc')
      const packed = await lx.utils.zlib.deflate(Buffer.from('kumone'))
      const unpacked = await lx.utils.zlib.inflate(packed)
      const text = Buffer.from(unpacked).toString('utf8')
      return { url: 'https://example.invalid/' + digest + '/' + text, quality: '128k' }
    })

    send(EVENT_NAMES.inited, {
      status: true,
      sources: {
        wy: {
          name: '网易云',
          type: 'music',
          actions: ['musicUrl'],
          qualitys: ['128k'],
        },
      },
    })
    """

    /// Only an export — no `lx.on` anywhere. This is the shape the export
    /// fallback exists for.
    private static let exportedMusicURLScript = """
    /**
     * @name 导出的音源
     * @author unit-test
     */

    const { EVENT_NAMES, send } = globalThis.lx

    module.exports = {
      musicUrl: function (source, musicInfo, quality) {
        return {
          url: 'https://example.invalid/export/' + source + '/' + musicInfo.id,
          quality: quality,
        }
      },
    }

    send(EVENT_NAMES.inited, {
      status: true,
      sources: {
        wy: {
          name: '网易云',
          type: 'music',
          actions: ['musicUrl'],
          qualitys: ['320k'],
        },
      },
    })
    """

    /// The `MusicPlugin` namespace: the same idea under a different global, and
    /// the last entry point tried.
    private static let musicPluginScript = """
    /**
     * @name MusicPlugin 音源
     * @author unit-test
     */

    const { EVENT_NAMES, send } = globalThis.lx

    globalThis.MusicPlugin = {
      getMusicUrl: function (source, id, quality) {
        return 'https://example.invalid/plugin/' + source + '/' + id + '/' + quality
      },
    }

    send(EVENT_NAMES.inited, {
      status: true,
      sources: {
        wy: {
          name: '网易云',
          type: 'music',
          actions: ['musicUrl'],
          qualitys: ['320k'],
        },
      },
    })
    """

    /// Both routes present at once, so the precedence between them is pinned.
    private static let handlerAndExportScript = """
    /**
     * @name 双入口
     * @author unit-test
     */

    const { EVENT_NAMES, on, send } = globalThis.lx

    module.exports = {
      musicUrl: function () {
        return 'https://example.invalid/export'
      },
    }

    on(EVENT_NAMES.request, function () {
      return { url: 'https://example.invalid/handler', quality: '320k' }
    })

    send(EVENT_NAMES.inited, {
      status: true,
      sources: {
        wy: {
          name: '网易云',
          type: 'music',
          actions: ['musicUrl'],
          qualitys: ['320k'],
        },
      },
    })
    """

    /// The prelude only insists on two bridge entries being present before it
    /// will run, and nothing on the paths these tests take calls the rest.
    private static func makeStubbedContext() throws -> JSContext {
        let context = try #require(JSContext())
        let httpStart: @convention(block) (Double, String, String) -> Void = { _, _, _ in }
        let actionSettled: @convention(block) (Double, String?, String?) -> Void = { _, _, _ in }
        context.setObject(httpStart, forKeyedSubscript: "__knHttpStart" as NSString)
        context.setObject(actionSettled, forKeyedSubscript: "__knActionSettled" as NSString)
        return context
    }

    private static func makeTrack(
        id: Int,
        name: String,
        artist: String,
        durationMS: Int
    ) throws -> Track {
        let data = Data(
            """
            {
              "id": \(id),
              "name": "\(name)",
              "ar": [{"id": 2, "name": "\(artist)"}],
              "al": {"id": 3, "name": "Album", "picUrl": null},
              "dt": \(durationMS)
            }
            """.utf8
        )
        return try JSONDecoder().decode(Track.self, from: data)
    }
}
