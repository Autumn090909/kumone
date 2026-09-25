import Foundation
import Testing
@testable import KumoneCore

/// Covers the QQ catalog's parsing and identity layer.
///
/// Every key name below was read off a live response when the mapping was
/// written. QQ renames these fields silently and a wrong key does not throw —
/// it yields an empty album name, a blank artist, or zero tracks out of a
/// hundred. That is the whole reason the mappers are `internal` and pinned by
/// fixtures instead of trusted.
@Suite("QQ catalog tests")
struct QQCatalogTests {

    // MARK: - Fixtures

    /// Computed rather than stored: `[String: Any]` is not `Sendable`, so a
    /// `static let` of one would not compile under Swift 6.
    private static var songSearchItem: [String: Any] {
        [
            "songid": 97_773,
            "songmid": "0039MnYb0qxYhV",
            "songname": "晴天",
            "albumid": 18_883,
            "albummid": "002MAeob3zLXwZ",
            "albumname": "叶惠美",
            "interval": 269,
            "singer": [["id": 4_558, "mid": "0025NhlN2yWrP4", "name": "周杰伦"]],
        ]
    }

    /// The playlist-detail shape (`fcg_ucc_getcdinfo_byids_cp?new_format=1`).
    /// Deliberately **not** the same keys as the search shape above — that
    /// difference is the bug this fixture exists to catch.
    private static var playlistEntry: [String: Any] {
        [
            "id": 97_773,
            "mid": "0039MnYb0qxYhV",
            "name": "晴天",
            "interval": 269,
            "singer": [["id": 4_558, "name": "周杰伦"]],
            "album": ["id": 18_883, "mid": "002MAeob3zLXwZ", "name": "叶惠美"],
            "file": ["media_mid": "1n2Xm3b4K5p6Q7"],
        ]
    }

    private static func makeTrack(
        platform: TrackPlatform = .netease,
        id: Int = 1,
        songmid: String? = nil,
        mediaMid: String? = nil
    ) -> Track {
        Track(
            id: id,
            name: "歌",
            artists: [ArtistRef(id: 1, name: "歌手")],
            album: AlbumRef(id: 2, name: "专辑", picUrl: nil),
            durationMS: 1_000,
            platform: platform,
            songmid: songmid,
            mediaMid: mediaMid
        )
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Platform identity

    @Test func onlyNetEaseTracksAreAccountBound() {
        #expect(Self.makeTrack(platform: .netease).isAccountBound)
        #expect(!Self.makeTrack(platform: .qq, songmid: "abc").isAccountBound)
    }

    @Test func shareLinksPointAtTheCatalogTheSongCameFrom() {
        #expect(Self.makeTrack(platform: .netease, id: 42).shareURL
            == "https://music.163.com/#/song?id=42")
        #expect(Self.makeTrack(platform: .qq, songmid: "0039MnYb0qxYhV").shareURL
            == "https://y.qq.com/n/ryqq/songDetail/0039MnYb0qxYhV")
    }

    /// A URL holding an empty mid would open QQ's error page, so the caller gets
    /// nothing to paste rather than something broken.
    @Test func aQQTrackWithoutAMidHasNoShareLink() {
        #expect(Self.makeTrack(platform: .qq, songmid: nil, mediaMid: nil).shareURL.isEmpty)
    }

    @Test func aQQTrackFallsBackToItsMediaMidForSharing() {
        #expect(Self.makeTrack(platform: .qq, songmid: nil, mediaMid: "1n2Xm3b4K5p6Q7").shareURL
            == "https://y.qq.com/n/ryqq/songDetail/1n2Xm3b4K5p6Q7")
    }

    // MARK: - Album / artist / playlist mids

    @Test func albumSummaryKeepsTheQQAlbumMid() throws {
        let album = try Self.decode(AlbumSummary.self,
                                    #"{"id":18883,"name":"叶惠美","albumMID":"002MAeob3zLXwZ"}"#)
        #expect(album.mid == "002MAeob3zLXwZ")
    }

    @Test func albumSummaryAlsoReadsTheLowerCasedMid() throws {
        let album = try Self.decode(AlbumSummary.self,
                                    #"{"id":1,"name":"a","mid":"lowerCasedMid"}"#)
        #expect(album.mid == "lowerCasedMid")
    }

    @Test func aNetEaseAlbumHasNoMid() throws {
        let album = try Self.decode(AlbumSummary.self, #"{"id":1,"name":"a"}"#)
        #expect(album.mid == nil)
    }

    @Test func artistSummaryKeepsTheQQSingerMid() throws {
        let artist = try Self.decode(ArtistSummary.self,
                                     #"{"id":4558,"name":"周杰伦","singerMID":"0025NhlN2yWrP4"}"#)
        #expect(artist.mid == "0025NhlN2yWrP4")
    }

    @Test func aNetEaseArtistHasNoMid() throws {
        let artist = try Self.decode(ArtistSummary.self, #"{"id":6452,"name":"周杰伦"}"#)
        #expect(artist.mid == nil)
    }

    @Test func playlistSummaryKeepsTheStringDissID() throws {
        let playlist = try Self.decode(PlaylistSummary.self,
                                       #"{"id":7039749142,"name":"歌单","dissid":"7039749142"}"#)
        #expect(playlist.mid == "7039749142")
    }

    @Test func aNetEasePlaylistHasNoMid() throws {
        let playlist = try Self.decode(PlaylistSummary.self, #"{"id":1,"name":"a"}"#)
        #expect(playlist.mid == nil)
    }

    // MARK: - Track mapping: search shape

    @Test func songSearchMapsTheFlatShape() throws {
        let track = try #require(QQMusicAPI.track(from: Self.songSearchItem))

        #expect(track.platform == .qq)
        #expect(track.id == 97_773)
        #expect(track.name == "晴天")
        #expect(track.songmid == "0039MnYb0qxYhV")
        #expect(track.albumMid == "002MAeob3zLXwZ")
        #expect(track.artists.first?.name == "周杰伦")
        #expect(track.album.name == "叶惠美")
        // `interval` is seconds on the wire, milliseconds in the app.
        #expect(track.durationMS == 269_000)
        // The paywall flag is deliberately not copied across: a custom source
        // decides playability at play time.
        #expect(track.fee == 0)
    }

    @Test func songSearchBuildsTheAlbumCoverFromTheTemplate() throws {
        let track = try #require(QQMusicAPI.track(from: Self.songSearchItem))
        #expect(track.album.picUrl
            == "https://y.gtimg.cn/music/photo_new/T002R300x300M000002MAeob3zLXwZ.jpg")
    }

    @Test func anEntryWithoutASongMidIsDropped() {
        var item = Self.songSearchItem
        item.removeValue(forKey: "songmid")
        #expect(QQMusicAPI.track(from: item) == nil)
    }

    @Test func anEntryWithoutASongIDIsDropped() {
        var item = Self.songSearchItem
        item.removeValue(forKey: "songid")
        #expect(QQMusicAPI.track(from: item) == nil)
    }

    // MARK: - Track mapping: playlist shape

    @Test func playlistEntriesUseTheirOwnKeyNames() throws {
        let track = try #require(QQMusicAPI.playlistTrack(from: Self.playlistEntry))

        #expect(track.id == 97_773)
        #expect(track.name == "晴天")
        // The playlist shape spells the same data `mid`, not `songmid`.
        #expect(track.songmid == "0039MnYb0qxYhV")
        // …and nests the album rather than flattening it.
        #expect(track.albumMid == "002MAeob3zLXwZ")
        #expect(track.album.name == "叶惠美")
        #expect(track.durationMS == 269_000)
    }

    /// The regression that motivated the separate mapper: feeding the flat
    /// search keys to a playlist entry finds nothing and returns zero tracks
    /// rather than failing, which reads as "the playlist is empty".
    @Test func aPlaylistEntryIsNotTheFlatSearchShape() {
        var flatLooking = Self.playlistEntry
        flatLooking.removeValue(forKey: "mid")
        #expect(QQMusicAPI.playlistTrack(from: flatLooking) == nil)
    }

    @Test func aPlaylistEntryCarriesItsFileMediaMid() throws {
        let track = try #require(QQMusicAPI.playlistTrack(from: Self.playlistEntry))
        #expect(track.mediaMid == "1n2Xm3b4K5p6Q7")
    }

    // MARK: - Summaries from live shapes

    @Test func albumSearchReadsTheUpperCasedKeys() throws {
        let album = try #require(QQMusicAPI.albumSummary(from: [
            "albumID": 18_883,
            "albumMID": "002MAeob3zLXwZ",
            "albumName": "叶惠美",
            "singerName": "周杰伦",
            "publicTime": "2003-07-31",
        ]))

        #expect(album.mid == "002MAeob3zLXwZ")
        #expect(album.name == "叶惠美")
        #expect(album.artistName == "周杰伦")
        #expect(album.publishTime > 0)
    }

    @Test func artistLookupUpgradesThePlainHTTPAvatar() throws {
        let artist = try #require(QQMusicAPI.artistSummary(from: [
            "mid": "0025NhlN2yWrP4",
            "name": "周杰伦",
            "pic": "http://y.gtimg.cn/music/photo_new/T001R300x300M0000025NhlN2yWrP4_11.jpg",
        ]))

        #expect(artist.mid == "0025NhlN2yWrP4")
        // Plain http is dropped silently by ATS, which renders as a blank face.
        #expect(artist.picUrl?.hasPrefix("https://") == true)
    }

    @Test func artistLookupToleratesTheMusicuSpelling() throws {
        let artist = try #require(QQMusicAPI.artistSummary(from: [
            "singerID": 4_558,
            "singerMID": "0025NhlN2yWrP4",
            "singerName": "周杰伦",
        ]))
        #expect(artist.mid == "0025NhlN2yWrP4")
        #expect(artist.name == "周杰伦")
    }

    /// The fallback used when `smartbox` (a suggestion endpoint) comes back
    /// empty for a name the caller already knows.
    @Test func anArtistCanBeBuiltFromJustAMidAndName() throws {
        let artist = try #require(QQMusicAPI.artistSummary(mid: "0025NhlN2yWrP4", name: "周杰伦"))
        #expect(artist.mid == "0025NhlN2yWrP4")
        #expect(artist.picUrl?.contains("T001R") == true)
    }

    @Test func anArtistCannotBeBuiltWithoutAName() {
        #expect(QQMusicAPI.artistSummary(mid: "abc", name: "") == nil)
    }

    @Test func playlistSearchKeepsTheDissIDAsTheMid() throws {
        let playlist = try #require(QQMusicAPI.playlistSummary(from: [
            "dissid": "7039749142",
            "dissname": "华语流行",
            "listennum": 1_234,
            "song_count": 29,
            "imgurl": "http://qpic.y.qq.com/x.jpg",
        ]))

        #expect(playlist.mid == "7039749142")
        #expect(playlist.id == 7_039_749_142)
        #expect(playlist.name == "华语流行")
        #expect(playlist.trackCount == 29)
        #expect(playlist.coverURL?.hasPrefix("https://") == true)
    }

    // MARK: - Lyrics

    @Test func lyricsAreReshapedAndEntityDecoded() throws {
        let response = try #require(QQMusicAPI.lyricResponse(from: [
            "lyric": "[ti:晴天]&apos;[ar:周杰伦]\n[00:01.00]故事的小黄花",
            "trans": "[00:01.00]The little yellow flower",
        ]))

        #expect(response.lrc?.lyric?.contains("[ti:晴天]'[ar:周杰伦]") == true)
        #expect(response.tlyric?.lyric?.contains("yellow flower") == true)
    }

    @Test func lyricsWithoutABodyAreNil() {
        #expect(QQMusicAPI.lyricResponse(from: [:]) == nil)
    }

    /// `&amp;` is replaced last so an escaped entity survives one pass instead
    /// of collapsing into a real one.
    @Test func htmlEntitiesDecodeExactlyOnce() {
        #expect(QQMusicAPI.decodeHTMLEntities("&amp;lt;") == "&lt;")
        #expect(QQMusicAPI.decodeHTMLEntities("&lt;3") == "<3")
        #expect(QQMusicAPI.decodeHTMLEntities("no entities") == "no entities")
    }

    // MARK: - Small helpers

    @Test func plainHTTPImagesAreUpgradedButOthersAreUntouched() {
        #expect(QQMusicAPI.httpsURL("http://y.qq.com/a.jpg") == "https://y.qq.com/a.jpg")
        #expect(QQMusicAPI.httpsURL("https://y.qq.com/a.jpg") == "https://y.qq.com/a.jpg")
        #expect(QQMusicAPI.httpsURL("") == nil)
    }

    @Test func publishDatesParseAsBejingCalendarDates() throws {
        let ms = try #require(QQMusicAPI.publishTimeMS("2005-11-01"))
        // 2005-11-01 00:00 +08:00 == 2005-10-31 16:00 UTC.
        #expect(ms == 1_130_774_400_000)
    }

    @Test func anUnparseablePublishDateIsNil() {
        #expect(QQMusicAPI.publishTimeMS("") == nil)
        #expect(QQMusicAPI.publishTimeMS("不是日期") == nil)
        #expect(QQMusicAPI.publishTimeMS(nil) == nil)
    }

    // MARK: - Envelope unwrapping

    @Test func jsonpAndWhilePrefixesAreUnwrapped() throws {
        let body = #"while(1);{"code":0,"data":{"song":{"list":[]}}}"#
        let object = try #require(QQMusicAPI.parseObject(from: Data(body.utf8)))
        #expect(object["code"] as? Int == 0)
    }

    @Test func aCallbackEnvelopeIsUnwrapped() throws {
        let body = #"callback({"code":0})"#
        let object = try #require(QQMusicAPI.parseObject(from: Data(body.utf8)))
        #expect(object["code"] as? Int == 0)
    }
}
