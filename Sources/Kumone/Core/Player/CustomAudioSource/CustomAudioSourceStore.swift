import Combine
import Foundation
import os.log

/// Imported LX-Music custom sources, plus the JS runtimes that run them.
///
/// Persistence is one JSON file under
/// `~/Library/Application Support/Kumone/CustomSources/sources.json`; the
/// scripts themselves are stored inline so a source is always self-contained
/// (export is just a copy of `script`).
///
/// Everything is `@MainActor` for the same reason the rest of the app's stores
/// are: JavaScriptCore's `JSContext` is not thread-safe, and the custom-source
/// work per track is a handful of microseconds of JS plus an await on the
/// network that the script's own `lx.request` started — nothing that blocks the
/// main thread.
@MainActor
final class CustomAudioSourceStore: ObservableObject {
    static let shared = CustomAudioSourceStore()

    private static let log = Logger(subsystem: "im.missuo.kumone", category: "custom-source")

    @Published private(set) var sources: [CustomAudioSource] = []

    private let fileURL: URL
    /// One compiled runtime per script, reused across tracks: creating a
    /// `JSContext` and evaluating a few hundred kilobytes of source is the
    /// expensive part, and a script's `inited` handshake does not need to be
    /// repeated for every song.
    private var runtimes: [String: LXScriptRuntime] = [:]

    private init() {
        self.fileURL = Self.defaultDirectory().appendingPathComponent("sources.json")
        load()
    }

    /// Test seam: keep the store off the real Application Support directory.
    init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("sources.json")
        load()
    }

    private static func defaultDirectory() -> URL {
        KumoneDirectories.applicationSupport("CustomSources")
    }

    // MARK: - Catalogue

    /// Providers for every enabled source, in the user's order. Built-in
    /// sources are ordered separately by `UnblockService`, which only needs
    /// these to append after them.
    func enabledProviders() -> [LXAudioSourceProvider] {
        sources
            .filter(\.isEnabled)
            .map {
                LXAudioSourceProvider(
                    id: $0.audioSourceID,
                    displayName: $0.name,
                    scriptKey: $0.id
                )
            }
    }

    // MARK: - Import & edit

    /// Imports a script, or replaces the stored text when the same script is
    /// imported twice — re-importing an updated version of a source you already
    /// have must not leave a stale duplicate behind.
    @discardableResult
    func importScript(_ script: String, fallbackName: String) throws -> CustomAudioSource {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CustomAudioSourceImportError.emptyScript }

        let metadata = LXScriptMetadata.parse(from: trimmed)
        let name = metadata.name ?? fallbackName

        var imported = CustomAudioSource(
            id: UUID().uuidString,
            name: name,
            author: metadata.author,
            version: metadata.version,
            homepage: metadata.homepage,
            summary: metadata.summary,
            script: trimmed
        )

        if let index = sources.firstIndex(where: { $0.script == trimmed }) {
            // Same script body: keep the identity (and the enable state), refresh
            // the metadata in case the header changed.
            imported.id = sources[index].id
            imported.importedAt = sources[index].importedAt
            imported.isEnabled = sources[index].isEnabled
            imported.declaredQualityLabels = sources[index].declaredQualityLabels
            runtimes[sources[index].id] = nil
            sources[index] = imported
        } else {
            sources.append(imported)
        }

        save()
        syncResolutionGate()
        return imported
    }

    func remove(scriptKey: String) {
        guard let removed = sources.first(where: { $0.id == scriptKey }) else { return }
        runtimes[scriptKey]?.shutdown()
        runtimes[scriptKey] = nil
        sources.removeAll { $0.id == scriptKey }
        // A stale identifier is harmless (`UnblockService` can never match it to
        // a provider) but it would linger in the persisted set forever.
        SettingsManager.shared.enabledAudioSourceIDs.remove(removed.audioSourceID)
        save()
    }

    func setEnabled(_ isEnabled: Bool, forScriptKey key: String) {
        update(key) { $0.isEnabled = isEnabled }
        syncResolutionGate()
    }

    /// Mirrors every custom source's switch into
    /// `SettingsManager.enabledAudioSourceIDs`, which stays the single gate
    /// `UnblockService` reads. Owning the mirroring here means the rest of the
    /// app never has to know that a custom source has two pieces of state.
    func syncResolutionGate() {
        let customIDs = Set(sources.map(\.audioSourceID))
        let enabledIDs = Set(sources.filter(\.isEnabled).map(\.audioSourceID))
        var updated = SettingsManager.shared.enabledAudioSourceIDs
        updated.subtract(customIDs)
        updated.formUnion(enabledIDs)
        guard updated != SettingsManager.shared.enabledAudioSourceIDs else { return }
        SettingsManager.shared.enabledAudioSourceIDs = updated
    }

    /// Reorders a source. Phrased as "move this one to that index" rather than
    /// SwiftUI's `move(fromOffsets:toOffset:)` so the store keeps no UI import.
    /// Order matters: `UnblockService` tries sources in list order.
    func move(scriptKey: String, toIndex index: Int) {
        guard let current = sources.firstIndex(where: { $0.id == scriptKey }), !sources.isEmpty else {
            return
        }
        let target = max(0, min(index, sources.count - 1))
        guard target != current else { return }
        let moved = sources.remove(at: current)
        sources.insert(moved, at: target)
        save()
    }

    // MARK: - Resolution

    /// Runs the script's `musicUrl` action for one track. Called from
    /// `LXAudioSourceProvider`, which hops onto the main actor to get here.
    func resolve(
        track: Track,
        scriptKey: String,
        requestedQuality: AudioQuality
    ) async throws -> ResolvedAudioSource? {
        guard let source = sources.first(where: { $0.id == scriptKey }) else {
            throw AudioSourceProviderError.scriptUnavailable("脚本已删除")
        }
        guard source.isEnabled else {
            throw AudioSourceProviderError.scriptUnavailable("脚本已停用")
        }

        let runtime = try await runtime(for: source)
        guard let resolved = try await runtime.musicURL(
            for: track,
            requestedQuality: requestedQuality
        ) else { return nil }

        return ResolvedAudioSource(
            id: source.audioSourceID,
            displayName: source.name,
            url: resolved.url,
            quality: resolved.quality
        )
    }

    /// Initialises a script and reports what it declared, so Settings can tell
    /// "this script is fine" from "this script never sent `inited`".
    func verify(scriptKey: String) async throws -> String {
        guard let source = sources.first(where: { $0.id == scriptKey }) else {
            throw AudioSourceProviderError.scriptUnavailable("脚本已删除")
        }
        runtimes[scriptKey]?.shutdown()
        runtimes[scriptKey] = nil
        let runtime = try await runtime(for: source)

        let declared = runtime.declaredSources
        guard !declared.isEmpty else {
            throw AudioSourceProviderError.scriptFailure("脚本初始化成功，但没有声明任何音源")
        }
        let summary = declared
            .map { "\($0.key)（\($0.name.isEmpty ? "未命名" : $0.name)）：音质 \($0.qualities.joined(separator: " / "))" }
            .joined(separator: "\n")
        return summary
    }

    private func runtime(for source: CustomAudioSource) async throws -> LXScriptRuntime {
        if let existing = runtimes[source.id] { return existing }

        let runtime: LXScriptRuntime
        do {
            runtime = try LXScriptRuntime(scriptKey: source.id, script: source.script)
            try await runtime.initialize()
        } catch {
            let detail = error.localizedDescription
            update(source.id) { $0.lastError = detail }
            Self.log.error(
                "script=\(source.id, privacy: .public) init-failed detail=\(detail, privacy: .public)"
            )
            throw AudioSourceProviderError.scriptUnavailable(detail)
        }

        runtimes[source.id] = runtime
        let labels = runtime.declaredQualityLabels
        update(source.id) { updated in
            updated.lastError = nil
            updated.declaredQualityLabels = labels
        }
        return runtime
    }

    // MARK: - Persistence

    private func update(_ key: String, _ mutate: (inout CustomAudioSource) -> Void) {
        guard let index = sources.firstIndex(where: { $0.id == key }) else { return }
        mutate(&sources[index])
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            sources = try JSONDecoder().decode([CustomAudioSource].self, from: data)
        } catch {
            // A corrupt catalogue must not take the app down or silently
            // disappear: keep the file for inspection and start empty.
            Self.log.error("catalogue decode failed: \(error.localizedDescription, privacy: .public)")
            sources = []
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(sources) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.log.error("catalogue write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

enum CustomAudioSourceImportError: LocalizedError {
    case emptyScript

    var errorDescription: String? {
        switch self {
        case .emptyScript: return String(localized: "脚本内容为空")
        }
    }
}
