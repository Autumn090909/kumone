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

    // MARK: - Home content (r10)

    /// The toplist-overview shape (`fcg_myqq_toplist.fcg`): `topTitle`,
    /// `picUrl`, `subTitle` and a `songList` teaser keyed by `songname`.
    private static var toplistItem: [String: Any] {
        [
            "id": 26,
            "topTitle": "巅峰榜·热歌",
            "subTitle": "每天更新",
            "picUrl": "http://y.gtimg.cn/music/photo_new/T003R300x300M000004YAZ8F1r.jpg",
            "songList": [
                ["songname": "茶汤"],
                ["songname": "我不难过"],
                ["songname": "甲乙丙丁"],
                ["songname": "第四首应该被截掉"],
            ],
        ]
    }

    @Test func toplistOverviewKeepsTheTeaserAndUpgradesTheCover() throws {
        let toplist = try #require(QQMusicAPI.toplist(from: Self.toplistItem))
        #expect(toplist.id == 26)
        #expect(toplist.name == "巅峰榜·热歌")
        #expect(toplist.subtitle == "每天更新")
        #expect(toplist.previewSongNames == ["茶汤", "我不难过", "甲乙丙丁"])
        let cover = try #require(toplist.coverURL)
        #expect(cover.hasPrefix("https://"))
    }

    @Test func nonSongToplistsAreDropped() {
        // Measured: id 201 (MV) and id 75 (电台/有声) carry no parseable songs
        // on the detail endpoint, so the overview mapper must drop them
        // instead of rendering dead links.
        var mvBoard = Self.toplistItem
        mvBoard["id"] = 201
        var radioBoard = Self.toplistItem
        radioBoard["id"] = 999
        radioBoard["topTitle"] = "有声书榜"
        var songBoard = Self.toplistItem
        songBoard["id"] = 999
        songBoard["topTitle"] = "国风榜"
        #expect(QQMusicAPI.toplist(from: mvBoard) == nil)
        #expect(QQMusicAPI.toplist(from: radioBoard) == nil)
        #expect(QQMusicAPI.toplist(from: songBoard) != nil)
    }

    /// A board song wrapped in `{data: …}` — the live shape. The wrapper is
    /// unwrapped before the flat search-shape mapper sees it.
    @Test func toplistSongsUnwrapTheirDataEnvelope() throws {
        let entry: [String: Any] = [
            "Franking_value": 1,
            "cur_count": 3,
            "data": Self.songSearchItem,
        ]
        let track = try #require(QQMusicAPI.track(from: (entry["data"] as? [String: Any]) ?? entry))
        #expect(track.platform == .qq)
        #expect(track.songmid == "0039MnYb0qxYhV")
        #expect(track.name == "晴天")
    }

    @Test func aSeededGeneratorIsDeterministic() {
        // Same seed → same sequence: this is what makes 推荐歌曲 rotate daily
        // (the day-of-year seed) yet stay put within a day.
        var a = QQMusicAPI.SeededGenerator(state: 42)
        var b = QQMusicAPI.SeededGenerator(state: 42)
        #expect(a.next() == b.next())
        #expect(a.next() == b.next())
        #expect(a.next() == b.next())
    }

    /// The homepage ships hot playlists inside escaped JSON string fragments —
    /// `\u002F` for `/`. The regex must unescape them, keep the string dissid
    /// (it becomes the `mid` that routes to the QQ playlist page) and dedupe.
    @Test func hotPlaylistsParseOutOfHomepageHTML() throws {
        let html = #"""
        window.__INITIAL_DATA__ = {"hotRecommend":[
          {"imgurl":"https:\u002F\u002Fmusic-file.y.qq.com\u002Fcover.jpg","dissname":"抖音热歌BGM超好听（火爆全网）","listennum":38492944,"dissid":8643520573},
          {"imgurl":"http:\u002F\u002Fy.gtimg.cn\u002Fold.jpg","dissname":"深夜伤感丨emo","listennum":5053695,"dissid":8150218364},
          {"imgurl":"https:\u002F\u002Fmusic-file.y.qq.com\u002Fcover.jpg","dissname":"抖音热歌BGM超好听（火爆全网）","listennum":38492944,"dissid":8643520573}
        ]}
        """#
        let summaries = QQMusicAPI.hotPlaylistSummaries(fromHTML: html, limit: 12)
        #expect(summaries.count == 2) // the duplicate is dropped
        let first = try #require(summaries.first)
        #expect(first.name == "抖音热歌BGM超好听（火爆全网）")
        #expect(first.mid == "8643520573")
        #expect(first.playCount == 38_492_944)
        let cover = try #require(first.coverURL)
        #expect(cover.hasPrefix("https://music-file.y.qq.com/"))
    }

    @Test func jsonEscapesDecodeThroughAJSONRoundTrip() {
        #expect(QQMusicAPI.decodeJSONEscapes(#"https:\u002F\u002Fy.gtimg.cn\u002Fa b.jpg"#) == "https://y.gtimg.cn/a b.jpg")
        #expect(QQMusicAPI.decodeJSONEscapes(#"\u534E\u8BED\u6D41\u884C"#) == "华语流行")
        #expect(QQMusicAPI.decodeJSONEscapes("no escapes") == "no escapes")
        // Unparseable input falls back to the original text rather than crashing.
        #expect(QQMusicAPI.decodeJSONEscapes(#"\q"#) == #"\q"#)
    }
}

// MARK: - QQ Music sign-in (web cookies)

@Suite("QQ 音乐登录")
struct QQAuthTests {
    @Test func gtkHashMatchesTheJavaScriptReference() {
        // Reference values produced by running QQ's own JS algorithm in node.
        #expect(QQMusicAuth.hash5381("") == 5381)
        #expect(QQMusicAuth.hash5381("abc") == 193_485_963)
        #expect(QQMusicAuth.hash5381("Q_H_L_abcdef1234567890") == 505_493_705)
        #expect(QQMusicAuth.hash5381("p_skey_SAMPLE VALUE With=Sign;==") == 1_166_302_605)
        #expect(QQMusicAuth.hash5381("o1234567890") == 2_020_846_529)
    }

    @Test func cookieHeaderKeepsTheCanonicalOrder() {
        let header = QQMusicAuth.cookieHeaderValue(from: [
            "p_skey": "ps",
            "uin": "o12345",
            "qqmusic_key": "Q_H_L_key",
            "noise": "dropped",
        ], includeCompatibilityUIN: true)
        #expect(header == "uin=o12345; qqmusic_key=Q_H_L_key; p_skey=ps")
    }

    @Test func aWeChatJarGetsACompatibilityUINForPlaybackButNotForPlaylists() {
        let cookies = ["wxuin": "998877", "wxskey": "skeyvalue", "wxopenid": "oid"]
        let withCompatibility = QQMusicAuth.cookieHeaderValue(from: cookies, includeCompatibilityUIN: true)
        let forPlaylists = QQMusicAuth.cookieHeaderValue(from: cookies, includeCompatibilityUIN: false)
        #expect(withCompatibility.hasPrefix("uin=998877; "))
        // (wxuin itself contains "uin=" as a substring, so check the prefix.)
        #expect(!forPlaylists.hasPrefix("uin="))
        #expect(QQMusicAuth.playlistUin(from: cookies) == "998877")
    }

    @Test func identityCandidatesCoverEveryUsableAccountIDOnce() {
        let candidates = QQMusicAuth.identityCandidates(from: [
            "uin": "o111", "p_uin": "222", "wxuin": "333",
        ])
        #expect(candidates == ["222", "111", "333", "0"])
        // A bare jar still offers the "let the server decide" candidate.
        #expect(QQMusicAuth.identityCandidates(from: ["pgv_pvid": "x"]) == ["0"])
    }

    @Test func loginValidationSeparatesMissingAccountFromMissingCredential() {
        #expect(QQMusicAuth.loginValidationMessage([:]) != nil)
        // An account id without any music credential is still unusable…
        #expect(QQMusicAuth.loginValidationMessage(["uin": "o12345", "pt2gguin": "o12345"]) != nil)
        // …but uin + any music credential is a valid QQ login.
        #expect(QQMusicAuth.loginValidationMessage(["uin": "o12345", "p_skey": "ps"]) == nil)
        #expect(QQMusicAuth.loginValidationMessage(["wxuin": "998877", "wxskey": "s"]) == nil)
        // "0" is QQ's "not signed in" placeholder, never a usable account.
        #expect(QQMusicAuth.loginValidationMessage(["uin": "0", "p_skey": "ps"]) != nil)
    }

    @Test func pastedCookieHeadersParseIntoAJar() {
        let jar = QQMusicAuth.parseCookieHeader("uin=o12345; qqmusic_key=Q_H_L_key; bad; empty=; p_skey=a=b")
        #expect(jar["uin"] == "o12345")
        #expect(jar["qqmusic_key"] == "Q_H_L_key")
        #expect(jar["p_skey"] == "a=b") // values may legally contain '='
        #expect(jar["empty"] == nil)
        #expect(jar.count == 3)
    }

    @Test func nicknameFallsBackToPtnickThenTheAccountID() {
        #expect(QQMusicAuth.fallbackNickname(["ptnick_1": "%E5%B0%8F%E6%98%8E"]) == "小明")
        #expect(QQMusicAuth.fallbackNickname(["nick": "阿豆"]) == "阿豆")
        #expect(QQMusicAuth.fallbackNickname(["uin": "o12345"]) == "QQ音乐用户 12345")
        #expect(QQMusicAuth.fallbackNickname(["pgv_pvid": "x"]) == "QQ音乐用户")
    }

    @Test func userPlaylistRowsNormaliseAndDropQZoneFolders() throws {
        // Legacy `fcg_user_created_diss` shape.
        let created = try #require(QQMusicAPI.userPlaylistSummary(from: [
            "dissid": 7302685378, "diss_name": "我的最爱",
            "diss_cover": "https://y.gtimg.cn/music/photo_new/T300R800x800M000001.jpg",
            "song_cnt": 42, "dirid": 0,
        ]))
        #expect(created.name == "我的最爱")
        #expect(created.mid == "7302685378")
        #expect(created.trackCount == 42)
        #expect(created.coverURL?.hasPrefix("https://y.gtimg.cn/") == true)

        // Official-gateway shape with `tid` instead of `dissid`.
        let official = try #require(QQMusicAPI.userPlaylistSummary(from: [
            "tid": 8150218364, "dissname": "收藏", "imgurl": "http://y.gtimg.cn/a.jpg",
        ]))
        #expect(official.mid == "8150218364")

        // QZone folder rows have a dirid but no real playlist id — dropped.
        #expect(QQMusicAPI.userPlaylistSummary(from: [
            "dirid": 3, "diss_name": "QQ空间背景音乐", "logo": "https://x/y.jpg",
        ]) == nil)
        // And anything self-identifying as a QZone/背景音乐 playlist is dropped too.
        #expect(QQMusicAPI.userPlaylistSummary(from: [
            "dissid": 100, "dissname": "QQ空间背景音乐",
        ]) == nil)
    }
}
