import Foundation

/// Fetches a track's words from whichever catalog the track belongs to.
///
/// The indirection is not cosmetic. A QQ song id handed to NetEase does not
/// fail — NetEase numbers its own songs independently, so the same integer
/// usually resolves to *a different track*, and the panel would quietly show
/// someone else's lyrics. Wrong words are worse than no words, so the platform
/// stored on the track decides where the request goes.
enum LyricsSource {

    /// `nil` means "this track has no words available" — the same meaning the
    /// callers already attach to a failed NetEase fetch.
    static func fetch(
        id: Int,
        platform: TrackPlatform,
        songmid: String? = nil
    ) async -> LyricResponse? {
        switch platform {
        case .netease:
            return try? await NeteaseAPI.lyric(id: id)
        case .qq:
            // The lyric endpoint is keyed by `songmid`. `mediaMid` is a
            // different identifier that merely looks similar, and the song
            // search response carries neither, so a track without one simply
            // has no words to show.
            guard let mid = songmid, !mid.isEmpty else { return nil }
            return try? await QQMusicAPI.lyric(songmid: mid)
        }
    }

    static func fetch(for track: Track) async -> LyricResponse? {
        await fetch(id: track.id, platform: track.platform,
                    songmid: track.songmid ?? track.mediaMid)
    }
}
