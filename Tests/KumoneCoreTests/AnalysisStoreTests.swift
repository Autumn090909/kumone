import Testing
@testable import KumoneCore
import Foundation

// `AnalysisStore` — the analysis's own home, outside the audio LRU cache.
//
// The whole point of the type is two invariants the old sidecars could not
// hold, so both get a test of their own:
//
//   - **a lookup is by track ID, never by quality level**. A track analyzed at
//     the scoring level and later played at `hires` must hit, or the app pays
//     for the same analysis twice.
//   - **quality only goes up**. A cheap scoring analysis arriving after a
//     playback-quality one must not overwrite it, whichever order they land in.
//
// Every case runs against a temporary directory; the real
// `~/Library/Application Support/Kumone/Analysis` (and the real audio cache
// the migration reads) are never touched.

@Suite struct AnalysisStoreTests {

    // MARK: - Fixtures

    private func makeAnalysis(bpm: Double = 120,
                              version: Int = TrackAnalysis.currentVersion) -> TrackAnalysis {
        TrackAnalysis(
            version: version,
            bpm: bpm, bpmConfidence: 0.9,
            beats: [0.4, 0.9, 1.4], downbeats: [0.4],
            phraseBoundaries: [30],
            rmsEnvelope: [0.5, 0.5],
            outroFadeStart: nil, introEnd: 2, duration: 200,
            melProfile: [], keyPitchClass: nil, keyIsMinor: false,
            keyConfidence: 0, vocalActivity: [],
            referenceLoudness: -12, peakDBFS: -6)
    }

    /// A store over a fresh temporary directory, plus the (empty) fake audio
    /// cache directory the migration reads.
    private func makeStore(withAudioDirectory: Bool = true)
        -> (store: AnalysisStore, root: URL, audio: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnalysisStoreTests-\(UUID().uuidString)", isDirectory: true)
        let analysis = root.appendingPathComponent("Analysis", isDirectory: true)
        let audio = root.appendingPathComponent("Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        return (AnalysisStore(directory: analysis,
                              audioDirectory: withAudioDirectory ? audio : nil),
                root, audio)
    }

    private func writeSidecar(_ analysis: TrackAnalysis, trackID: Int, level: String,
                              source: String = "netease", ext: String = "mp3",
                              in audio: URL) throws {
        let name = "\(trackID)-\(level)-\(source).\(ext).analysis.json"
        try JSONEncoder().encode(analysis)
            .write(to: audio.appendingPathComponent(name))
    }

    // MARK: - Store and load

    @Test("an analysis stored at one level is found by track ID at any other")
    func storeAndLoadIgnoresLevel() async throws {
        let (store, root, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.storeAnalysis(makeAnalysis(bpm: 128), forTrackID: 42,
                                  level: "standard", source: "netease")

        // By ID, and by a playback key whose level and container are nothing
        // like the ones the analysis was computed from.
        #expect(await store.loadAnalysis(forTrackID: 42)?.bpm == 128)
        let key = AudioCache.Key(trackID: 42, level: "hires",
                                 source: "netease", fileExtension: "flac")
        #expect(await store.loadAnalysis(for: key)?.bpm == 128)
        #expect(await store.loadAnalysis(forTrackID: 43) == nil)

        let found = await store.analyses(forTrackIDs: [42, 43])
        #expect(found.keys.sorted() == [42])
        #expect(await store.totalUsageBytes() > 0)
    }

    @Test("a record from an older analyzer version is a miss, not a stale hit")
    func versionMismatchMisses() async throws {
        let (store, root, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.storeAnalysis(makeAnalysis(version: TrackAnalysis.currentVersion - 1),
                                  forTrackID: 7, level: "exhigh", source: "netease")

        #expect(await store.loadAnalysis(forTrackID: 7) == nil)
        #expect(await store.analyses(forTrackIDs: [7]).isEmpty)

        // And it is not a tombstone: a current-version analysis overwrites it,
        // even from cheaper audio than the stale record claimed.
        await store.storeAnalysis(makeAnalysis(bpm: 90), forTrackID: 7,
                                  level: "standard", source: "netease")
        #expect(await store.loadAnalysis(forTrackID: 7)?.bpm == 90)
    }

    // MARK: - Precedence

    @Test("better audio wins whichever order the two analyses arrive in")
    func qualityPrecedence() async throws {
        let (store, root, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        // Upgrade: a playback-quality analysis replaces the scoring one.
        await store.storeAnalysis(makeAnalysis(bpm: 100), forTrackID: 1,
                                  level: "standard", source: "netease")
        await store.storeAnalysis(makeAnalysis(bpm: 200), forTrackID: 1,
                                  level: "lossless", source: "netease")
        #expect(await store.loadAnalysis(forTrackID: 1)?.bpm == 200)

        // Downgrade: the scoring pass arriving second changes nothing.
        await store.storeAnalysis(makeAnalysis(bpm: 100), forTrackID: 1,
                                  level: "standard", source: "netease")
        #expect(await store.loadAnalysis(forTrackID: 1)?.bpm == 200)

        // Same level re-analyzed: the newer result lands (no reason to keep
        // the old bytes, and this is how a re-analysis at the same quality
        // takes effect).
        await store.storeAnalysis(makeAnalysis(bpm: 150), forTrackID: 1,
                                  level: "lossless", source: "netease")
        #expect(await store.loadAnalysis(forTrackID: 1)?.bpm == 150)

        // An unknown level sorts above every known one rather than being
        // silently preferred against.
        await store.storeAnalysis(makeAnalysis(bpm: 175), forTrackID: 1,
                                  level: "jymaster", source: "netease")
        #expect(await store.loadAnalysis(forTrackID: 1)?.bpm == 175)
    }

    // MARK: - Migration

    @Test("legacy sidecars are imported once, best level wins, and are deleted")
    func migratesSidecarsFromTheAudioCache() async throws {
        let (store, root, audio) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeSidecar(makeAnalysis(bpm: 100), trackID: 5, level: "standard", in: audio)
        try writeSidecar(makeAnalysis(bpm: 140), trackID: 5, level: "exhigh",
                         ext: "flac", in: audio)
        try writeSidecar(makeAnalysis(bpm: 111), trackID: 6, level: "standard",
                         source: "unblock_kuwo", in: audio)
        try writeSidecar(makeAnalysis(version: TrackAnalysis.currentVersion - 1),
                         trackID: 8, level: "exhigh", in: audio)
        // Not a sidecar: the audio itself must survive the walk untouched.
        let audioFile = audio.appendingPathComponent("5-exhigh-netease.flac")
        try Data([0x00]).write(to: audioFile)

        #expect(await store.loadAnalysis(forTrackID: 5)?.bpm == 140)
        #expect(await store.loadAnalysis(forTrackID: 6)?.bpm == 111)
        #expect(await store.loadAnalysis(forTrackID: 8) == nil)
        #expect(FileManager.default.fileExists(atPath: audioFile.path))

        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: audio.path)
            .filter { $0.hasSuffix(".analysis.json") }
        #expect(leftovers.isEmpty)

        // The import respects precedence like any other write: a sidecar
        // reappearing at a worse level (a second machine, a restored backup)
        // cannot demote what is already stored.
        try writeSidecar(makeAnalysis(bpm: 60), trackID: 5, level: "standard", in: audio)
        let second = AnalysisStore(directory: root.appendingPathComponent("Analysis"),
                                   audioDirectory: audio)
        #expect(await second.loadAnalysis(forTrackID: 5)?.bpm == 140)
    }

    @Test("the migration is one-shot: a later sidecar is not re-imported")
    func migrationRunsOnce() async throws {
        let (store, root, audio) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = await store.loadAnalysis(forTrackID: 1)  // marks the import done
        try writeSidecar(makeAnalysis(bpm: 128), trackID: 1, level: "exhigh", in: audio)

        #expect(await store.loadAnalysis(forTrackID: 1) == nil)
        // A fresh store over the same directory finds the marker and leaves
        // the file alone, so the walk really is paid for once.
        let second = AnalysisStore(directory: root.appendingPathComponent("Analysis"),
                                   audioDirectory: audio)
        #expect(await second.loadAnalysis(forTrackID: 1) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: audio.path)
                    .contains { $0.hasSuffix(".analysis.json") })
    }

    // MARK: - Clearing

    @Test("clear() empties the store and survives being used afterwards")
    func clearEmptiesTheStore() async throws {
        let (store, root, _) = makeStore(withAudioDirectory: false)
        defer { try? FileManager.default.removeItem(at: root) }

        await store.storeAnalysis(makeAnalysis(), forTrackID: 3,
                                  level: "exhigh", source: "netease")
        #expect(await store.totalUsageBytes() > 0)

        await store.clear()
        #expect(await store.loadAnalysis(forTrackID: 3) == nil)

        await store.storeAnalysis(makeAnalysis(bpm: 95), forTrackID: 3,
                                  level: "standard", source: "netease")
        #expect(await store.loadAnalysis(forTrackID: 3)?.bpm == 95)
    }
}
