import Foundation
import os.log

/// Resolves gray tracks from the direct pyncmd source, then built-in search
/// providers when pyncmd cannot serve the original NetEase song ID, then any
/// imported LX custom sources the user switched on.
enum UnblockService {
    private static let log = Logger(subsystem: "im.missuo.kumone", category: "audio-source")
    private static let httpClient = AudioSourceClient.shared
    private static let fallbackProviders: [any AudioSourceProvider] = [
        KugouAudioSourceProvider(),
        KuwoAudioSourceProvider(),
    ]

    struct Resolution {
        let source: ResolvedAudioSource?
        let attemptedSources: Set<AudioSourceID>
    }

    /// Custom sources are passed in rather than looked up here so this stays a
    /// pure function of its inputs — and so the JS-backed providers, which are
    /// main-actor bound, are only ever constructed by a caller that is already
    /// there.
    static func resolve(
        _ track: Track,
        enabledSources: Set<AudioSourceID>,
        excluding attemptedSources: Set<AudioSourceID>,
        customProviders: [LXAudioSourceProvider] = []
    ) async -> Resolution {
        var newlyAttemptedSources = Set<AudioSourceID>()
        // pyncmd is a NetEase-indexed aggregator: its `source` parameter accepts
        // only `netease` (verified against the live API — `tencent` is rejected
        // outright), so a foreign track would be chased by an id that belongs to
        // a different platform's numbering. At best that misses, at worst it
        // matches an unrelated NetEase song that happens to share the number.
        // Skipped rather than guessed at.
        if track.platform == .netease,
           enabledSources.contains(.pyncmd), !attemptedSources.contains(.pyncmd) {
            newlyAttemptedSources.insert(.pyncmd)
            do {
                return Resolution(
                    source: try await pyncmd(track),
                    attemptedSources: newlyAttemptedSources
                )
            } catch {
                logFailure(source: .pyncmd, operation: "resolve", error: error)
            }
        }

        // Built-ins first: they are the shipped, best-tested path. Imported
        // scripts run after them, in the order the user arranged.
        let ordered: [any AudioSourceProvider] =
            fallbackProviders + customProviders.map { $0 as any AudioSourceProvider }

        for provider in ordered where enabledSources.contains(provider.id)
            && !attemptedSources.contains(provider.id) {
            newlyAttemptedSources.insert(provider.id)
            do {
                if let resolved = try await provider.resolve(track: track) {
                    return Resolution(source: resolved, attemptedSources: newlyAttemptedSources)
                }
            } catch {
                logFailure(source: provider.id, operation: "resolve", error: error)
            }
        }
        return Resolution(source: nil, attemptedSources: newlyAttemptedSources)
    }

    private static func pyncmd(_ track: Track) async throws -> ResolvedAudioSource {
        let urlString = "https://music-api.gdstudio.xyz/api.php?types=url&source=netease&id=\(track.id)&br=320"
        let data = try await httpClient.data(
            from: urlString,
            source: .pyncmd,
            operation: "resolve"
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AudioSourceProviderError.invalidResponse
        }
        guard let bitrate = object["br"] as? Int, bitrate > 0 else {
            throw AudioSourceProviderError.missingBitrate
        }
        guard let urlValue = object["url"] as? String else {
            throw AudioSourceProviderError.missingStreamURL
        }
        guard let url = URL(string: urlValue.replacingOccurrences(of: "http://", with: "https://")) else {
            throw AudioSourceProviderError.invalidURL
        }
        return ResolvedAudioSource(id: .pyncmd, displayName: AudioSourceID.pyncmd.displayName, url: url)
    }

    private static func logFailure(source: AudioSourceID, operation: String, error: Error) {
        log.error(
            "source=\(source.rawValue, privacy: .public) operation=\(operation, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
        )
    }
}
