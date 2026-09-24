import Foundation

/// One imported LX-Music custom source: the script text plus the metadata the
/// UI needs without executing it.
struct CustomAudioSource: Codable, Identifiable, Hashable, Sendable {
    /// Stable key. It is both the persistence key and the `custom:<key>` half of
    /// the source ID, so renaming a script — or re-importing it with a different
    /// `@name` — never orphans the user's enable/disable choice.
    let id: String
    var name: String
    var author: String?
    var version: String?
    var homepage: String?
    var summary: String?
    var script: String
    var importedAt: Date
    var isEnabled: Bool
    /// Quality labels the script declared the last time it initialised. Cached
    /// so Settings can show them without paying for a JS context on every draw.
    var declaredQualityLabels: [String]
    /// The last initialisation failure, surfaced verbatim in Settings. Cleared
    /// on a successful init.
    var lastError: String?

    var audioSourceID: AudioSourceID { .custom(id) }

    init(
        id: String,
        name: String,
        author: String? = nil,
        version: String? = nil,
        homepage: String? = nil,
        summary: String? = nil,
        script: String,
        importedAt: Date = Date(),
        isEnabled: Bool = true,
        declaredQualityLabels: [String] = [],
        lastError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.author = author
        self.version = version
        self.homepage = homepage
        self.summary = summary
        self.script = script
        self.importedAt = importedAt
        self.isEnabled = isEnabled
        self.declaredQualityLabels = declaredQualityLabels
        self.lastError = lastError
    }
}
