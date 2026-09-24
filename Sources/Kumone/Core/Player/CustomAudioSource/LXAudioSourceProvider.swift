import Foundation

/// One imported LX script, presented as an audio source.
///
/// Deliberately tiny and holding no JS: the runtime lives in
/// `CustomAudioSourceStore` so a script is compiled once and reused by every
/// resolution. This type exists so custom sources travel down the exact same
/// `AudioSourceProvider` path as the built-in three.
struct LXAudioSourceProvider: AudioSourceProvider {
    let id: AudioSourceID
    let displayName: String
    /// Key of the owning script in `CustomAudioSourceStore`.
    let scriptKey: String

    func resolve(track: Track) async throws -> ResolvedAudioSource? {
        // Read on the main actor rather than captured at construction time: the
        // provider outlives a settings change mid-playback.
        let quality = await MainActor.run { SettingsManager.shared.audioQuality }
        return try await CustomAudioSourceStore.shared.resolve(
            track: track,
            scriptKey: scriptKey,
            requestedQuality: quality
        )
    }
}
