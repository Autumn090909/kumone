import Foundation

/// Persistent, quality-independent home for `TrackAnalysis` (spec §3).
///
/// Analyses used to live as `<key>.analysis.json` sidecars inside the audio
/// LRU cache, which cost them twice:
///
/// - **Lifetime.** Clearing or evicting the audio deleted the analysis with
///   it, even though the analysis is ~17 KB and the audio is tens of MB. The
///   only way to get it back was to re-download the file and re-analyze.
/// - **Identity.** The sidecar key carried the served quality level, so a
///   track analyzed at `standard` for queue scoring and later played at
///   `exhigh` was analyzed twice, and an exact-key lookup missed the other
///   level's perfectly good result.
///
/// So the store lives in **Application Support** (survives cache clearing) and
/// is keyed by track ID alone: `<trackID>.json`. Each file records which level
/// and source it was computed from, and a higher-quality analysis replaces a
/// lower-quality one — never the other way round. A caller playing at `hires`
/// is welcome to a `standard` analysis (it is good enough to plan with) and
/// may re-analyze and store, which upgrades the file for everyone after it.
actor AnalysisStore {
    static let shared = AnalysisStore()

    /// One track's analysis plus the provenance the precedence rule needs.
    ///
    /// `TrackAnalysis` is nested rather than flattened so its own `Codable`
    /// keeps working unchanged — the sidecar bytes decode as the `analysis`
    /// member verbatim, and a future field added here cannot collide with one
    /// added there.
    struct Record: Codable, Sendable {
        var analysis: TrackAnalysis
        /// Served quality level the audio was analyzed at, e.g. "exhigh".
        var level: String
        /// "netease" or "unblock:<source>", as in `AudioCache.Key`.
        var source: String
    }

    /// Quality levels cheapest first. Unknown names sort last, so a level this
    /// build has never heard of is treated as the best thing on disk rather
    /// than silently preferred against.
    private static let levelLadder = ["standard", "higher", "exhigh", "lossless", "hires"]

    static func levelRank(_ level: String) -> Int {
        levelLadder.firstIndex(of: level) ?? levelLadder.count
    }

    private static let sidecarSuffix = ".analysis.json"
    private static let migrationMarker = ".sidecars-migrated"

    private let directory: URL
    /// Where the old sidecars live. Nil disables migration entirely (tests
    /// that must never touch the real audio cache).
    private let audioDirectory: URL?
    private var migrationChecked = false

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        directory = support.appendingPathComponent("Kumone/Analysis", isDirectory: true)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        audioDirectory = caches.appendingPathComponent("Kumone/Audio", isDirectory: true)
        ensureDirectory()
    }

    /// Test seam: an isolated store over a temporary directory.
    init(directory: URL, audioDirectory: URL?) {
        self.directory = directory
        self.audioDirectory = audioDirectory
        ensureDirectory()
    }

    // MARK: - Lookup

    /// The analysis for this track at **any** quality level, or nil on a miss
    /// (absent, unreadable, or written by an older analyzer version).
    func loadAnalysis(forTrackID id: Int) -> TrackAnalysis? {
        migrateSidecarsIfNeeded()
        return record(forTrackID: id)?.analysis
    }

    /// Convenience for the playback path, which already holds an
    /// `AudioCache.Key`. Only the track ID of the key is used — see the type
    /// note above on why the level is deliberately ignored.
    func loadAnalysis(for key: AudioCache.Key) -> TrackAnalysis? {
        loadAnalysis(forTrackID: key.trackID)
    }

    /// Every stored analysis for the given tracks in one directory walk.
    ///
    /// This is the free half of the queue-order candidate pool (predev §2.2):
    /// a track heard before has an analysis on disk, and asking for it costs
    /// no network call, no download and no analyzer pass.
    func analyses(forTrackIDs ids: Set<Int>) -> [Int: TrackAnalysis] {
        guard !ids.isEmpty else { return [:] }
        migrateSidecarsIfNeeded()
        var found: [Int: TrackAnalysis] = [:]
        for id in ids {
            if let record = record(forTrackID: id) { found[id] = record.analysis }
        }
        return found
    }

    // MARK: - Writing

    /// Persists an analysis, keeping whichever of the two was computed from
    /// better audio. A stale-version file on disk always loses.
    func storeAnalysis(_ analysis: TrackAnalysis, forTrackID id: Int,
                       level: String, source: String) {
        migrateSidecarsIfNeeded()
        write(Record(analysis: analysis, level: level, source: source), forTrackID: id)
    }

    func storeAnalysis(_ analysis: TrackAnalysis, for key: AudioCache.Key) {
        storeAnalysis(analysis, forTrackID: key.trackID,
                      level: key.level, source: key.source)
    }

    // MARK: - Maintenance

    /// Total bytes on disk. No limit is enforced: ~17 KB per track means even
    /// a library of thousands costs less than one lossless album.
    func totalUsageBytes() -> Int64 {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return urls.reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    /// Throws away every analysis. Deliberately separate from the audio cache's
    /// `removeAll()`: clearing playback bytes must not cost the expensive part.
    func clear() {
        try? FileManager.default.removeItem(at: directory)
        ensureDirectory()
        // The audio sidecars are gone for good, so the marker goes back
        // immediately rather than inviting a pointless walk on the next read.
        markMigrated()
        migrationChecked = true
    }

    // MARK: - Storage

    private func recordURL(forTrackID id: Int) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    private func record(forTrackID id: Int) -> Record? {
        guard let data = try? Data(contentsOf: recordURL(forTrackID: id)),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.analysis.version == TrackAnalysis.currentVersion else { return nil }
        return record
    }

    /// The precedence rule, in one place: a record only lands if nothing
    /// usable is already there from equal-or-better audio.
    private func write(_ record: Record, forTrackID id: Int) {
        if let existing = self.record(forTrackID: id),
           Self.levelRank(existing.level) > Self.levelRank(record.level) { return }
        ensureDirectory()
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: recordURL(forTrackID: id), options: .atomic)
    }

    private nonisolated func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Migration

    /// One-shot import of the legacy `<id>-<level>-<source>.<ext>.analysis.json`
    /// sidecars from the audio cache, respecting precedence, deleting each
    /// sidecar as it lands. Guarded by a marker file so a launch after the
    /// import does not even list the audio directory.
    private func migrateSidecarsIfNeeded() {
        guard !migrationChecked else { return }
        migrationChecked = true
        guard let audioDirectory,
              !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(Self.migrationMarker).path),
              let names = try? FileManager.default.contentsOfDirectory(
                atPath: audioDirectory.path)
        else { markMigrated(); return }

        // Best level first, so the winner is written once and the rest are
        // rejected by the same precedence check the live path uses.
        let sidecars = names
            .filter { $0.hasSuffix(Self.sidecarSuffix) }
            .compactMap { name -> (id: Int, level: String, source: String, name: String)? in
                // "<trackID>-<level>-<source>.<ext>.analysis.json"
                let parts = name.split(separator: "-", maxSplits: 2,
                                       omittingEmptySubsequences: false)
                guard parts.count == 3, let id = Int(parts[0]) else { return nil }
                let tail = String(parts[2]).dropLast(Self.sidecarSuffix.count)
                let source = tail.split(separator: ".").first.map(String.init) ?? "netease"
                return (id, String(parts[1]), source, name)
            }
            .sorted { Self.levelRank($0.level) > Self.levelRank($1.level) }

        for sidecar in sidecars {
            let url = audioDirectory.appendingPathComponent(sidecar.name)
            if let data = try? Data(contentsOf: url),
               let analysis = try? JSONDecoder().decode(TrackAnalysis.self, from: data),
               analysis.version == TrackAnalysis.currentVersion {
                write(Record(analysis: analysis, level: sidecar.level, source: sidecar.source),
                      forTrackID: sidecar.id)
            }
            try? FileManager.default.removeItem(at: url)
        }
        markMigrated()
    }

    private func markMigrated() {
        ensureDirectory()
        try? Data().write(to: directory.appendingPathComponent(Self.migrationMarker))
    }
}
