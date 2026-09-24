import Foundation

/// Identifies one eligible third-party source for gray-track resolution.
///
/// This began as a closed enum (`pyncmd` / `kugou` / `kuwo`). Importing
/// LX-Music-compatible custom sources (#82, #85, #107, #110) means the set is
/// no longer known at compile time, so the type is now an open string-backed
/// value:
///
/// - the three shipped sources are static constants below;
/// - every imported script contributes one `custom:<scriptKey>` value.
///
/// `rawValue` stays the persisted identity — it is what
/// `SettingsManager.enabledAudioSourceIDs` writes to `UserDefaults` — so the
/// three built-in raw values are unchanged from the enum days and existing
/// installs keep their stored selection.
struct AudioSourceID: RawRepresentable, Hashable, Identifiable, Sendable {
    let rawValue: String

    var id: String { rawValue }

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension AudioSourceID {
    static let pyncmd = AudioSourceID(rawValue: "pyncmd")
    static let kugou = AudioSourceID(rawValue: "kugou")
    static let kuwo = AudioSourceID(rawValue: "kuwo")

    /// The shipped sources, in their built-in resolution order.
    static let builtIn: [AudioSourceID] = [.pyncmd, .kugou, .kuwo]

    private static let customPrefix = "custom:"

    /// Namespaces a custom source by the key of the script providing it.
    static func custom(_ scriptKey: String) -> AudioSourceID {
        AudioSourceID(rawValue: customPrefix + scriptKey)
    }

    /// The owning script's key, when this ID came from an imported LX script.
    var customScriptKey: String? {
        guard rawValue.hasPrefix(Self.customPrefix) else { return nil }
        return String(rawValue.dropFirst(Self.customPrefix.count))
    }

    var isCustom: Bool { customScriptKey != nil }

    /// Built-in sources know their own name. A custom source is named by the
    /// script that declared it and only the store knows that name, so this
    /// falls back to the script key; providers report the real name through
    /// `ResolvedAudioSource.displayName`.
    var displayName: String {
        if self == .pyncmd { return "pyncmd" }
        if self == .kugou { return String(localized: "酷狗音乐") }
        if self == .kuwo { return String(localized: "酷我音乐") }
        return customScriptKey ?? rawValue
    }
}

struct ResolvedAudioSource {
    let id: AudioSourceID
    let displayName: String
    let url: URL
    /// The LX quality label (`128k` / `320k` / `flac` / `flac24bit`) a custom
    /// source served this URL at. `nil` for built-in sources, which report no
    /// quality of their own. Defaulted so the built-in call sites keep using
    /// `ResolvedAudioSource(id:displayName:url:)`.
    var quality: String? = nil
}

protocol AudioSourceProvider {
    var id: AudioSourceID { get }
    var displayName: String { get }

    func resolve(track: Track) async throws -> ResolvedAudioSource?
}

enum AudioSourceProviderError: LocalizedError {
    case invalidResponse
    case invalidURL
    case missingBitrate
    case missingStreamURL

    /// Custom-source failures worth surfacing verbatim: a script that never
    /// initialised, or one whose LX handler rejected.
    case scriptUnavailable(String)
    case scriptFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid audio-source response"
        case .invalidURL: return "Invalid audio-source URL"
        case .missingBitrate: return "Audio-source response has no bitrate"
        case .missingStreamURL: return "Audio-source response has no stream URL"
        case .scriptUnavailable(let detail): return "Custom source unavailable: \(detail)"
        case .scriptFailure(let detail): return "Custom source failed: \(detail)"
        }
    }
}

enum AudioSourceTrackMatcher {
    static func keyword(for track: Track) -> String {
        "\(track.name) \(track.artists.first?.name ?? "")"
            .trimmingCharacters(in: .whitespaces)
    }

    static func matches(
        track: Track,
        title: String,
        artist: String,
        durationMS: Int
    ) -> Bool {
        guard track.durationMS > 0,
              durationMS > 0,
              abs(durationMS - track.durationMS) <= 5_000,
              normalized(title) == normalized(track.name),
              !hasVersionConflict(original: track.name, candidate: title)
        else { return false }

        let expectedArtist = normalized(track.artists.first?.name ?? "")
        guard !expectedArtist.isEmpty else { return false }
        return artistNames(in: artist).contains(expectedArtist)
    }

    private static let versionMarkers = [
        "live", "remix", "伴奏", "dj", "cover", "翻唱", "instrumental", "karaoke"
    ]

    private static func hasVersionConflict(original: String, candidate: String) -> Bool {
        let originalMarkers = Set(versionMarkers.filter { normalized(original).contains($0) })
        let candidateMarkers = Set(versionMarkers.filter { normalized(candidate).contains($0) })
        return originalMarkers != candidateMarkers
    }

    private static func artistNames(in value: String) -> [String] {
        value.split(whereSeparator: { "/&、,，;；".contains($0) })
            .map { normalized(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map { String($0) }
            .joined()
    }
}
