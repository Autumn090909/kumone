import Foundation
import os.log

/// QQ Music catalog access — search, browse and lyrics.
///
/// ## Provenance
///
/// The request shapes here (endpoints, query parameter names, the `Referer` QQ
/// insists on, the `while(1);` / `callback({…})` prefixes its older endpoints
/// emit, and the `musicu.fcg` envelope) were ported from **Beans Music**
/// (https://github.com/XIaodou0416/Beans-Music), MIT licensed,
/// Copyright (c) 2026 XIaodou0416 — and then verified against the live
/// endpoints before being relied on.
///
/// ## What is deliberately *not* ported
///
/// Beans also carries a full `vkey.GetVkeyServer` playback path (~300 lines:
/// multi-format `filename` candidates, `media_mid` back-fill, bitrate fallback
/// chain, CDN rotation, a persistent device guid, a Range pre-flight). That path
/// was measured against the live endpoints and **returns an empty `purl` for
/// every track while logged out — including tracks whose `payplay` is 0**, i.e.
/// the free ones. The legacy `fcg_music_express_mobile3` endpoint answers
/// `code 104003` (no permission) under the same conditions. Porting it would
/// have produced dead code plus a QQ login flow; playback is served by the
/// user's compatible custom-source scripts instead.
///
/// ## Two corrections that only live measurement revealed
///
/// 1. Beans' song search uses `client_search_cp`. **That endpoint answered HTTP
///    500 for every `t` value when measured from here**, so the search endpoint
///    below stays on `search_for_qq_cp`, which answered `code 0` across the
///    board. The two are siblings on the same host but are not interchangeable.
/// 2. Beans' artist search leads with `musicu.fcg` `search_type=1`. Measured
///    three times in a row it answered `code 2001` (throttled) every time, so
///    the artist path leads with `smartbox_new.fcg` and treats `musicu` as the
///    fallback rather than the other way round.
///
/// ## Field names
///
/// QQ hands back *different* shapes for the same concept depending on the
/// endpoint — playlist tracks in particular use `mid`/`name`/`album.mid` rather
/// than the flat `songmid`/`songname`/`albummid` that search uses. Every mapper
/// below was written against a dumped live response, never from documentation.
enum QQMusicAPI {
    private static let log = Logger(subsystem: "im.missuo.kumone", category: "qq-api")

    // MARK: - Endpoints

    /// Song (`t=0`), album (`t=8`) and lyric (`t=7`) search.
    private static let searchEndpoint =
        "https://c.y.qq.com/soso/fcgi-bin/search_for_qq_cp"
    /// Artist lookup. A suggestion endpoint rather than a real search — it
    /// returns a handful of names, but it is the only artist path that stayed
    /// up when measured.
    private static let smartboxEndpoint =
        "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg"
    /// JSON gateway behind playlist search. Throttles roughly one request in
    /// three with `code 2001`, hence the retry loop in `searchPlaylists`.
    private static let musicuEndpoint = "https://u.y.qq.com/cgi-bin/musicu.fcg"
    /// Album detail, including its track list.
    private static let albumInfoEndpoint =
        "https://c.y.qq.com/v8/fcg-bin/fcg_v8_album_info_cp.fcg"
    /// Playlist detail, including its track list. Works logged out.
    private static let playlistDetailEndpoint =
        "https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg"
    /// Timed lyrics, plain text when `nobase64=1`.
    private static let lyricEndpoint =
        "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg"
    /// Ranking-board overview (榜单总览). Logged out, no `musicu` involved.
    private static let toplistOverviewEndpoint =
        "https://c.y.qq.com/v8/fcg-bin/fcg_myqq_toplist.fcg"
    /// Songs of one ranking board (`topid` selects the board).
    private static let toplistDetailEndpoint =
        "https://c.y.qq.com/v8/fcg-bin/fcg_v8_toplist_cp.fcg"
    /// The QQ Music homepage. Its server-rendered `__INITIAL_DATA__` ships the
    /// hot-playlist data with the page itself — one request, no throttled
    /// `musicu` round trip.
    private static let homepageURL = "https://y.qq.com/"

    /// QQ returns an empty body to its own app's default client UA, and the
    /// `Referer` is not optional — without it the endpoint replies with an
    /// error page rather than JSON.
    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 QQMusic/9.0.5"
    private static let referer = "https://y.qq.com/portal/player.html"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Referer": referer,
        ]
        return URLSession(configuration: config)
    }()

    enum QQError: LocalizedError {
        case invalidURL
        case malformedResponse
        /// `code 2001` from the `musicu` gateway. Retried by the caller rather
        /// than surfaced, because it clears on its own within a second or two.
        case rateLimited
        /// A QQ identifier the call cannot work without (`dissid`, `albummid`,
        /// `songmid`) was missing from the value the caller passed in — usually
        /// because a response carried a name but no mid.
        case missingIdentifier

        var errorDescription: String? {
            switch self {
            case .invalidURL: return String(localized: "无法构造 QQ 音乐请求地址")
            case .malformedResponse: return String(localized: "QQ 音乐返回了无法解析的内容")
            case .rateLimited: return String(localized: "QQ 音乐暂时限流，请稍后重试")
            case .missingIdentifier: return String(localized: "这条 QQ 音乐内容缺少必要的标识，无法打开")
            }
        }
    }

    // MARK: - Search: songs

    /// Searches QQ's song catalog.
    ///
    /// - Parameter limit: how many results to ask for. QQ caps this quietly, so
    ///   the caller gets whatever comes back rather than an error.
    static func searchSongs(
        _ keyword: String,
        limit: Int = 30,
        page: Int = 1
    ) async throws -> [Track] {
        let items = try await searchSongItems(keyword, limit: limit, page: page)
        return items.compactMap(track(from:))
    }

    /// The raw song entries, so callers that need fields `Track` drops (the
    /// singer mids, for instance) can filter on them before mapping.
    private static func searchSongItems(
        _ keyword: String,
        limit: Int,
        page: Int
    ) async throws -> [[String: Any]] {
        let data = try await searchData(keyword, type: 0, limit: limit, page: page)
        guard let song = data["song"] as? [String: Any],
              let list = song["list"] as? [[String: Any]]
        else { throw QQError.malformedResponse }
        return list
    }

    /// Shared body of `search_for_qq_cp`. `t` selects the result family:
    /// measured `0` → `data.song.list`, `7` → `data.lyric.list`,
    /// `8` → `data.album.list`; every other value silently degrades to songs.
    private static func searchData(
        _ keyword: String,
        type: Int,
        limit: Int,
        page: Int
    ) async throws -> [String: Any] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }

        var components = URLComponents(string: searchEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "w", value: trimmed),
            URLQueryItem(name: "n", value: String(max(limit, 1))),
            URLQueryItem(name: "p", value: String(max(page, 1))),
            URLQueryItem(name: "t", value: String(type)),
        ]
        guard let url = components?.url else { throw QQError.invalidURL }
        let object = try await getJSON(url)
        guard let data = object["data"] as? [String: Any] else {
            throw QQError.malformedResponse
        }
        return data
    }

    // MARK: - Search: albums

    /// Album search via `t=8` on the same endpoint songs use — measured stable,
    /// unlike the `musicu` `search_type=2` path Beans treats as its fallback.
    static func searchAlbums(_ keyword: String, limit: Int = 30) async throws -> [AlbumSummary] {
        let data = try await searchData(keyword, type: 8, limit: limit, page: 1)
        guard let album = data["album"] as? [String: Any],
              let list = album["list"] as? [[String: Any]]
        else { throw QQError.malformedResponse }
        return list.compactMap(albumSummary(from:))
    }

    // MARK: - Search: artists

    /// Artist lookup through `smartbox_new.fcg`.
    ///
    /// QQ's real artist search lives on `musicu.fcg` (`search_type=1`), but
    /// three consecutive live calls all answered `code 2001`, so that path can
    /// only be a fallback. `smartbox` returns few results — two for a query as
    /// broad as 周杰伦 — but it is the one that stays up.
    static func searchArtists(_ keyword: String, limit: Int = 30) async throws -> [ArtistSummary] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let list = try? await smartboxArtists(trimmed), !list.isEmpty {
            return Array(list.compactMap(artistSummary(from:)).prefix(limit))
        }
        return try await musicuArtists(trimmed, limit: limit)
    }

    private static func smartboxArtists(_ keyword: String) async throws -> [[String: Any]] {
        var components = URLComponents(string: smartboxEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "s_from", value: "pc_header"),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "key", value: keyword),
        ]
        guard let url = components?.url else { throw QQError.invalidURL }
        let object = try await getJSON(url)
        guard let data = object["data"] as? [String: Any],
              let singer = data["singer"] as? [String: Any],
              let list = singer["itemlist"] as? [[String: Any]]
        else { throw QQError.malformedResponse }
        return list
    }

    private static func musicuArtists(_ keyword: String, limit: Int) async throws -> [ArtistSummary] {
        let payload = musicuSearchPayload(keyword: keyword, limit: limit, searchType: 1)
        let object = try await postJSON(musicuEndpoint, payload)
        try checkMusicuThrottle(object)
        let list = nestedList(object, path: ["req_1", "data", "body", "singer", "list"]) ?? []
        return list.compactMap(artistSummary(from:))
    }

    // MARK: - Search: playlists

    /// Playlist search through `musicu.fcg` `search_type=3`.
    ///
    /// Measured: of three consecutive identical requests, two returned 20
    /// results and one returned `code 2001`. A single attempt would therefore
    /// look like "playlist search doesn't work" about a third of the time, so
    /// this retries with a growing pause and only gives up after `attempts`.
    static func searchPlaylists(
        _ keyword: String,
        limit: Int = 30,
        attempts: Int = 4
    ) async throws -> [PlaylistSummary] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let payload = musicuSearchPayload(keyword: trimmed, limit: limit, searchType: 3)
        var lastError: Error = QQError.malformedResponse

        for attempt in 1...max(1, attempts) {
            do {
                let object = try await postJSON(musicuEndpoint, payload)
                try checkMusicuThrottle(object)
                let list = nestedList(object, path: ["req_1", "data", "body", "songlist", "list"]) ?? []
                let mapped = list.compactMap(playlistSummary(from:))
                if !mapped.isEmpty { return mapped }
                lastError = QQError.malformedResponse
            } catch {
                lastError = error
            }
            if attempt < attempts {
                // `2001` is a throttle, not a ban — a short back-off is what the
                // endpoint wants.
                try? await Task.sleep(nanoseconds: 500_000_000 * UInt64(attempt))
            }
        }
        throw lastError
    }

    /// The `musicu` envelope: a JSON body with named request slots.
    private static func musicuSearchPayload(
        keyword: String,
        limit: Int,
        searchType: Int
    ) -> [String: Any] {
        [
            // `ct 19 / cv 1859 / uin "0"` is the combination that returns data
            // logged out. Measured alternatives (`ct 24`, `cv 0`) answer
            // `code 0` with a *silently empty* list, which is worse than an
            // error because it looks like "no results".
            "comm": ["ct": 19, "cv": 1859, "uin": "0", "format": "json"],
            "req_1": [
                "module": "music.search.SearchCgiService",
                "method": "DoSearchForQQMusicDesktop",
                "param": [
                    "query": keyword,
                    "num_per_page": max(limit, 1),
                    "page_num": 1,
                    "search_type": searchType,
                    "grp": 1,
                ],
            ],
        ]
    }

    private static func checkMusicuThrottle(_ object: [String: Any]) throws {
        let code = intValue((object["req_1"] as? [String: Any])?["code"]) ?? 0
        if code == 2001 { throw QQError.rateLimited }
    }

    // MARK: - Album detail

    static func albumDetail(mid: String) async throws -> AlbumDetailResponse {
        let trimmed = mid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QQError.invalidURL }

        var components = URLComponents(string: albumInfoEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "albummid", value: trimmed),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components?.url else { throw QQError.invalidURL }
        let object = try await getJSON(url)
        guard let data = object["data"] as? [String: Any] else {
            throw QQError.malformedResponse
        }

        // The album's own tracks share the flat shape search returns, so the
        // same mapper applies.
        let songs = (data["list"] as? [[String: Any]])?.compactMap(track(from:)) ?? []

        var shaped: [String: Any] = [
            "id": intValue(data["id"]) ?? 0,
            "name": stringValue(data["name"]) ?? "",
            "mid": stringValue(data["mid"]) ?? trimmed,
        ]
        if let cover = TrackPlatform.qqAlbumCoverURL(albumMid: trimmed, size: 500)?.absoluteString {
            shaped["picUrl"] = cover
        }
        if let description = stringValue(data["desc"]) { shaped["description"] = description }
        if let company = stringValue(data["company"]) { shaped["company"] = company }
        if let published = publishTimeMS(data["aDate"]) { shaped["publishTime"] = published }
        if let total = intValue(data["total_song_num"]) { shaped["size"] = total }

        let singerName = stringValue(data["singername"]) ?? ""
        if !singerName.isEmpty {
            var artist: [String: Any] = [
                "id": intValue(data["singerid"]) ?? 0,
                "name": singerName,
            ]
            if let singerMid = stringValue(data["singermid"]), !singerMid.isEmpty {
                artist["mid"] = singerMid
                if let avatar = TrackPlatform.qqSingerAvatarURL(singerMid: singerMid)?.absoluteString {
                    artist["picUrl"] = avatar
                }
            }
            shaped["artist"] = artist
        }

        guard let album = decode(AlbumDetail.self, from: shaped) else {
            throw QQError.malformedResponse
        }
        return AlbumDetailResponse(album: album, songs: songs)
    }

    // MARK: - Playlist detail

    /// A QQ playlist: the header NetEase's `PlaylistDetail` can express, plus
    /// the tracks carried separately.
    ///
    /// They travel apart because `PlaylistDetail.tracks` is `let` and the model
    /// has no memberwise initialiser — route the tracks through it and they
    /// would have to be re-encoded to JSON just to be decoded again. The
    /// `trackIds` list is filled to the same length as `tracks` on purpose: the
    /// playlist screen pages in the rest of a NetEase playlist whenever
    /// `trackIds` is longer, and that follow-up call is a NetEase endpoint.
    struct PlaylistPayload {
        let detail: PlaylistDetail
        let tracks: [Track]
    }

    static func playlistDetail(dissID: String) async throws -> PlaylistPayload {
        let trimmed = dissID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QQError.invalidURL }

        var components = URLComponents(string: playlistDetailEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "utf8", value: "1"),
            URLQueryItem(name: "onlysong", value: "0"),
            URLQueryItem(name: "new_format", value: "1"),
            URLQueryItem(name: "disstid", value: trimmed),
            URLQueryItem(name: "loginUin", value: "0"),
            URLQueryItem(name: "hostUin", value: "0"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "inCharset", value: "utf8"),
            URLQueryItem(name: "outCharset", value: "utf-8"),
            URLQueryItem(name: "notice", value: "0"),
            URLQueryItem(name: "platform", value: "yqq.json"),
            URLQueryItem(name: "needNewCode", value: "0"),
        ]
        guard let url = components?.url else { throw QQError.invalidURL }
        let object = try await getJSON(url)
        guard let cd = (object["cdlist"] as? [[String: Any]])?.first else {
            throw QQError.malformedResponse
        }

        let tracks = (cd["songlist"] as? [[String: Any]])?.compactMap(playlistTrack(from:)) ?? []

        var shaped: [String: Any] = [
            // `disstid` is the full id; the `dissid` field next to it comes back
            // *truncated* (`7039749142` → `7039749`) on the live endpoint.
            "id": intValue(stringValue(cd["disstid"]) ?? trimmed) ?? 0,
            "name": stringValue(cd["dissname"]) ?? "",
            "trackCount": intValue(cd["songnum"]) ?? tracks.count,
            "playCount": intValue(cd["visitnum"]) ?? 0,
            // Deliberately empty — the caller reads `tracks` off this payload.
            "tracks": [],
            "trackIds": tracks.map { ["id": $0.id] },
        ]
        if let cover = stringValue(cd["logo"]) { shaped["coverImgUrl"] = httpsURL(cover) }
        if let description = stringValue(cd["desc"]) { shaped["description"] = description }
        let creatorName = stringValue(cd["nickname"]) ?? stringValue(cd["nick"])
        if let creatorName {
            shaped["creator"] = ["nickname": creatorName]
        }
        if let created = intValue(cd["ctime"]) { shaped["updateTime"] = created }

        guard let detail = decode(PlaylistDetail.self, from: shaped) else {
            throw QQError.malformedResponse
        }
        return PlaylistPayload(detail: detail, tracks: tracks)
    }

    // MARK: - Artist songs

    /// Songs by one artist.
    ///
    /// QQ's dedicated artist-song endpoints are gone: `fcg_v8_singer_track_cp`
    /// answers HTTP 404 and `fcg_v8_singer_album` answers `code 400`, and five
    /// alternative `musicu` module names all came back `code 500003` with no
    /// data. What does work is filtering song search by the artist mid — for
    /// 周杰伦, 20 of 20 results carried `singer[0].mid == 0025NhlN2yWrP4`.
    ///
    /// The honest caveat, which the UI repeats: this is *that artist's songs
    /// that came back for their name*, not their complete catalogue.
    static func artistSongs(
        singerMid: String,
        keyword: String,
        limit: Int = 100
    ) async throws -> [Track] {
        let mid = singerMid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mid.isEmpty else { return [] }
        let items = try await searchSongItems(keyword, limit: limit, page: 1)
        let matching = items.filter { item in
            guard let singers = item["singer"] as? [[String: Any]] else { return false }
            return singers.contains { stringValue($0["mid"]) == mid }
        }
        return matching.compactMap(track(from:))
    }

    // MARK: - Lyrics

    /// Timed lyrics for a QQ track, reshaped into NetEase's `LyricResponse`.
    ///
    /// QQ answers flat (`{lyric: "…", trans: "…"}`) while the app's model is
    /// nested (`{lrc: {lyric}, tlyric: {lyric}}`), so the two keys are rewrapped
    /// rather than the model being forked.
    static func lyric(songmid: String) async throws -> LyricResponse? {
        let trimmed = songmid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var components = URLComponents(string: lyricEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "songmid", value: trimmed),
            URLQueryItem(name: "format", value: "json"),
            // Without this the body arrives base64-encoded.
            URLQueryItem(name: "nobase64", value: "1"),
            URLQueryItem(name: "g_tk", value: "5381"),
        ]
        guard let url = components?.url else { throw QQError.invalidURL }
        let object = try await getJSON(url)
        return lyricResponse(from: object)
    }

    static func lyricResponse(from object: [String: Any]) -> LyricResponse? {
        var shaped: [String: Any] = [:]
        if let main = stringValue(object["lyric"]) {
            shaped["lrc"] = ["lyric": decodeHTMLEntities(main)]
        }
        if let translation = stringValue(object["trans"]) {
            shaped["tlyric"] = ["lyric": decodeHTMLEntities(translation)]
        }
        guard !shaped.isEmpty else { return nil }
        return decode(LyricResponse.self, from: shaped)
    }

    // MARK: - Home content (榜单 / 推荐歌曲 / 热门歌单)

    /// One ranking board from the overview endpoint.
    struct Toplist: Identifiable, Hashable {
        let id: Int
        let name: String
        let subtitle: String?
        /// Up to three song names the overview bundles in as a teaser.
        let previewSongNames: [String]
        /// Raw URL string — `resizedImageURL` is a `String` extension.
        let coverURL: String?
    }

    /// The ranking-board overview: `data.topList[]` with `topTitle` / `picUrl`
    /// and a three-song teaser per board. Measured 25 boards, no login.
    static func toplists() async throws -> [Toplist] {
        guard var components = URLComponents(string: toplistOverviewEndpoint) else {
            throw QQError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "format", value: "json")]
        guard let url = components.url else { throw QQError.invalidURL }
        let object = try await getJSON(url)
        let data = object["data"] as? [String: Any] ?? object
        let list = data["topList"] as? [[String: Any]] ?? []
        return list.compactMap(toplist(from:))
    }

    /// Internal for tests — field names move, and a wrong one here silently
    /// empties the whole 榜单 shelf.
    static func toplist(from item: [String: Any]) -> Toplist? {
        guard let id = intValue(item["id"]), id > 0 else { return nil }
        let name = stringValue(item["topTitle"]) ?? stringValue(item["title"]) ?? ""
        guard !name.isEmpty, !isNonSongToplist(id: id, name: name) else { return nil }
        let previews = ((item["songList"] as? [[String: Any]]) ?? [])
            .compactMap { stringValue($0["songname"]) }
        let cover = (stringValue(item["picUrl"]) ?? stringValue(item["headPicUrl"]))
            .flatMap(httpsURL)
        return Toplist(
            id: id,
            name: name,
            subtitle: stringValue(item["subTitle"]),
            previewSongNames: Array(previews.prefix(3)),
            coverURL: cover
        )
    }

    /// The overview mixes in MV / audiobook / radio boards whose detail
    /// endpoint carries no parseable songs — measured `id 201` and `id 75`
    /// return empty song lists — so they are filtered rather than rendered as
    /// dead links.
    private static func isNonSongToplist(id: Int, name: String) -> Bool {
        if id == 201 || id == 75 { return true }
        let lowered = name.lowercased()
        return lowered.contains("mv") || name.contains("有声") || name.contains("电台")
    }

    /// Songs of one board. Entries arrive as `{data: {…song…}}`, and the inner
    /// shape is exactly the flat search shape (`songid` / `songmid` / `songname`
    /// / `singer[]` / `albummid` / `interval` in seconds, `strMediaMid`) —
    /// measured live — so `track(from:)` maps it directly.
    static func toplistSongs(topID: Int, limit: Int = 100) async throws -> [Track] {
        guard var components = URLComponents(string: toplistDetailEndpoint) else {
            throw QQError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "page", value: "detail"),
            URLQueryItem(name: "type", value: "top"),
            URLQueryItem(name: "topid", value: String(topID)),
            URLQueryItem(name: "song_begin", value: "0"),
            URLQueryItem(name: "song_num", value: String(max(limit, 1))),
        ]
        guard let url = components.url else { throw QQError.invalidURL }
        let object = try await getJSON(url)
        let list = object["songlist"] as? [[String: Any]] ?? []
        return list.compactMap { entry in
            track(from: (entry["data"] as? [String: Any]) ?? entry)
        }
    }

    /// "推荐歌曲" for a logged-out visitor.
    ///
    /// QQ has no logged-out personalised feed, so this is assembled the way
    /// Beans Music does it: the hot / new / surging boards (26 / 27 / 62)
    /// mixed and deduplicated, then shuffled with a day-seeded generator so
    /// the mix rotates daily but stays put within a day.
    static func recommendedSongs(limit: Int = 30) async throws -> [Track] {
        let day = Calendar(identifier: .gregorian)
            .ordinality(of: .day, in: .year, for: Date()) ?? 0
        var songs: [Track] = []
        var seen = Set<String>()
        let per = max(8, (limit + 2) / 3)
        for topID in [26, 27, 62] {
            guard let list = try? await toplistSongs(topID: topID, limit: per) else { continue }
            for song in list where seen.insert(song.songmid ?? song.name).inserted {
                songs.append(song)
            }
        }
        var rng = SeededGenerator(state: UInt64(truncatingIfNeeded: day) &* 2_654_435_761)
        songs.shuffle(using: &rng)
        return Array(songs.prefix(limit))
    }

    /// Deterministic LCG — `RandomNumberGenerator` needs no more than this for
    /// "shuffle differently tomorrow, identically today".
    struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(state: UInt64) { self.state = state &* 0x9E37_79B9_7F4A_7C15 &+ 1 }
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    /// Hot playlists scraped from the homepage's server-rendered data.
    ///
    /// The `musicu` `RecommendPlaylist` module throttles hard (the same
    /// `code 2001` behaviour as search), while this data ships with the page —
    /// the homepage itself has to render it. Covers arrive inside escaped JSON
    /// string fragments (`\u002F` for `/`), hence `decodeJSONEscapes`.
    /// Internal for tests; the fetching wrapper is `hotPlaylists(limit:)`.
    static func hotPlaylistSummaries(fromHTML html: String, limit: Int) -> [PlaylistSummary] {
        let pattern = #""imgurl"\s*:\s*"([^"]+)"\s*,\s*"dissname"\s*:\s*"([^"]*)"\s*,\s*"listennum"\s*:\s*([0-9]+)\s*,\s*"dissid"\s*:\s*([0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var summaries: [PlaylistSummary] = []
        var seen = Set<Int>()

        for match in regex.matches(in: html, range: range) {
            if summaries.count >= max(1, limit) { break }
            guard let imageRange = Range(match.range(at: 1), in: html),
                  let nameRange = Range(match.range(at: 2), in: html),
                  let playsRange = Range(match.range(at: 3), in: html),
                  let idRange = Range(match.range(at: 4), in: html)
            else { continue }

            let dissID = String(html[idRange])
            let name = decodeJSONEscapes(String(html[nameRange]))
            guard let id = Int(dissID), id > 0, !name.isEmpty, seen.insert(id).inserted
            else { continue }

            var shaped: [String: Any] = ["id": id, "name": name, "mid": dissID]
            if let cover = httpsURL(decodeJSONEscapes(String(html[imageRange]))) {
                shaped["coverImgUrl"] = cover
            }
            if let plays = Int(html[playsRange]) {
                shaped["playCount"] = plays
            }
            if let summary = decode(PlaylistSummary.self, from: shaped) {
                summaries.append(summary)
            }
        }
        return summaries
    }

    static func hotPlaylists(limit: Int = 12) async throws -> [PlaylistSummary] {
        guard let url = URL(string: homepageURL) else { throw QQError.invalidURL }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            log.error("QQ homepage HTTP \(http.statusCode, privacy: .public)")
            throw QQError.malformedResponse
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw QQError.malformedResponse
        }
        let summaries = hotPlaylistSummaries(fromHTML: html, limit: limit)
        guard !summaries.isEmpty else { throw QQError.malformedResponse }
        return summaries
    }

    // MARK: - Parsing: tracks

    /// Field names here are the ones the search endpoint actually returned when
    /// this was written — verified against a live response rather than taken
    /// from documentation, since QQ shifts them. Notably `songname` /
    /// `albumname` / `albummid` (no underscores) and `interval` in **seconds**.
    /// Internal rather than private so the mapping can be unit-tested against a
    /// fixture of the live response; field names move, and a wrong one here
    /// fails silently as an empty album or a blank artist.
    static func track(from item: [String: Any]) -> Track? {
        guard let songID = intValue(item["songid"]), songID > 0,
              let songmid = stringValue(item["songmid"])
        else { return nil }

        let artists: [ArtistRef] = (item["singer"] as? [[String: Any]])?.map { singer in
            ArtistRef(
                id: intValue(singer["id"]) ?? 0,
                name: stringValue(singer["name"]) ?? ""
            )
        } ?? []

        let albumMid = stringValue(item["albummid"]) ?? ""
        let albumID = intValue(item["albumid"]) ?? 0
        let albumName = stringValue(item["albumname"]) ?? ""
        let cover = TrackPlatform.qqAlbumCoverURL(albumMid: albumMid)

        return Track(
            id: songID,
            name: stringValue(item["songname"]) ?? "",
            artists: artists,
            album: AlbumRef(id: albumID, name: albumName, picUrl: cover?.absoluteString),
            // QQ reports `interval` in seconds; the rest of the app is in ms.
            durationMS: (intValue(item["interval"]) ?? 0) * 1_000,
            // `fee` is deliberately left at 0. QQ's `pay.payplay` flag marks
            // paid catalogue entries, but whether a track is playable here is
            // decided by a custom source at play time, not by QQ's paywall.
            // Copying the flag across would grey out songs in the UI that the
            // script layer answers perfectly well.
            fee: 0,
            platform: .qq,
            songmid: songmid,
            mediaMid: mediaMid(from: item),
            albumMid: albumMid.isEmpty ? nil : albumMid
        )
    }

    /// Playlist entries are **not** the flat shape. With `new_format=1` they
    /// look like `{id, mid, name, interval, singer[], album{id,mid,name},
    /// file{media_mid}}` — no `songmid`, no `albummid`, no `songname`. Reading
    /// the flat keys here yields 0 tracks out of 99 rather than an error, which
    /// is exactly what happened the first time this was measured.
    static func playlistTrack(from item: [String: Any]) -> Track? {
        guard let songID = intValue(item["id"]), songID > 0,
              let songmid = stringValue(item["mid"])
        else { return nil }

        let artists: [ArtistRef] = (item["singer"] as? [[String: Any]])?.map { singer in
            ArtistRef(
                id: intValue(singer["id"]) ?? 0,
                name: stringValue(singer["name"]) ?? ""
            )
        } ?? []

        let album = item["album"] as? [String: Any]
        let albumMid = stringValue(album?["mid"]) ?? ""
        let cover = TrackPlatform.qqAlbumCoverURL(albumMid: albumMid)

        return Track(
            id: songID,
            name: stringValue(item["name"]) ?? stringValue(item["title"]) ?? "",
            artists: artists,
            album: AlbumRef(
                id: intValue(album?["id"]) ?? 0,
                name: stringValue(album?["name"]) ?? "",
                picUrl: cover?.absoluteString
            ),
            durationMS: (intValue(item["interval"]) ?? 0) * 1_000,
            fee: 0,
            platform: .qq,
            songmid: songmid,
            mediaMid: mediaMid(from: item),
            albumMid: albumMid.isEmpty ? nil : albumMid
        )
    }

    /// `file.media_mid` exists on album and playlist entries but not on search
    /// results; `strMediaMid` is the album/toplist spelling of the same thing.
    /// Frequently equal to the song mid but not always, and a script handed the
    /// wrong one gets nothing back.
    private static func mediaMid(from item: [String: Any]) -> String? {
        stringValue((item["file"] as? [String: Any])?["media_mid"])
            ?? stringValue(item["strMediaMid"])
            ?? stringValue(item["media_mid"])
            ?? stringValue(item["mediaMid"])
    }

    // MARK: - Parsing: album / artist / playlist summaries

    /// Maps a QQ album entry into NetEase's `AlbumSummary` fields.
    ///
    /// Handles both the `t=8` search shape (`albumID`, `albumMID`, `albumName`,
    /// `singerName`, `publicTime`) and the `musicu` shape (`albumName`,
    /// `singer_list`, `song_count`) — they agree on the important names.
    static func albumSummary(from item: [String: Any]) -> AlbumSummary? {
        guard let mid = stringValue(item["albumMID"]) ?? stringValue(item["albummid"]),
              let name = stringValue(item["albumName"]) ?? stringValue(item["name"])
        else { return nil }

        var shaped: [String: Any] = [
            "id": intValue(item["albumID"]) ?? intValue(item["albumid"]) ?? 0,
            "name": name,
            "mid": mid,
        ]
        if let cover = TrackPlatform.qqAlbumCoverURL(albumMid: mid, size: 300)?.absoluteString {
            shaped["picUrl"] = cover
        }
        var artistName = stringValue(item["singerName"]) ?? stringValue(item["singername"]) ?? ""
        if artistName.isEmpty, let singers = item["singer_list"] as? [[String: Any]] {
            artistName = singers.compactMap { stringValue($0["name"]) }.joined(separator: " / ")
        }
        if !artistName.isEmpty { shaped["artist"] = ["name": artistName] }
        if let published = publishTimeMS(item["publicTime"]) { shaped["publishTime"] = published }
        if let total = intValue(item["song_count"]) ?? intValue(item["total"]) {
            shaped["size"] = total
        }
        return decode(AlbumSummary.self, from: shaped)
    }

    /// Handles both the `smartbox` shape (`id`/`mid`/`name`/`pic`, ids as
    /// strings) and the `musicu` shape (`singerID`/`singerMID`/`singerName`).
    static func artistSummary(from item: [String: Any]) -> ArtistSummary? {
        guard let name = stringValue(item["name"]) ?? stringValue(item["singerName"])
        else { return nil }

        var shaped: [String: Any] = [
            "id": intValue(item["id"]) ?? intValue(item["singerID"]) ?? 0,
            "name": name,
        ]
        if let mid = stringValue(item["mid"]) ?? stringValue(item["singerMID"]) {
            shaped["mid"] = mid
        }
        // `smartbox` still hands back plain `http://` (measured 2 of 2), and
        // iOS App Transport Security drops those silently — a broken avatar
        // rather than an error.
        if let pic = stringValue(item["pic"]) ?? stringValue(item["picUrl"]),
           let upgraded = httpsURL(pic) {
            shaped["picUrl"] = upgraded
        }
        return decode(ArtistSummary.self, from: shaped)
    }

    /// A minimal artist value for a page whose caller already knows who it
    /// wants but whose lookup came back empty.
    ///
    /// QQ's artist lookup is `smartbox`, which is a *suggestion* endpoint: ask
    /// it about a lesser-known name and it can answer with nothing at all. The
    /// artist page is entered from a search result that already carried a mid
    /// and a name, so rather than rendering a blank page the header is built
    /// from what the caller passed in.
    static func artistSummary(mid: String?, name: String) -> ArtistSummary? {
        guard !name.isEmpty else { return nil }
        var shaped: [String: Any] = ["id": 0, "name": name]
        if let mid, !mid.isEmpty {
            shaped["mid"] = mid
            if let avatar = TrackPlatform.qqSingerAvatarURL(singerMid: mid)?.absoluteString {
                shaped["picUrl"] = avatar
            }
        }
        return decode(ArtistSummary.self, from: shaped)
    }

    /// The `musicu` playlist-search shape: `dissid` (string), `dissname`,
    /// `imgurl` (plain http), `listennum`, `song_count`, `creator.name`.
    static func playlistSummary(from item: [String: Any]) -> PlaylistSummary? {
        guard let dissID = stringValue(item["dissid"]) ?? stringValue(item["disstid"]),
              let name = stringValue(item["dissname"]) ?? stringValue(item["name"])
        else { return nil }

        var shaped: [String: Any] = [
            "id": Int(dissID) ?? 0,
            "name": name,
            "mid": dissID,
        ]
        if let img = stringValue(item["imgurl"]), let upgraded = httpsURL(img) {
            shaped["coverImgUrl"] = upgraded
        }
        if let plays = intValue(item["listennum"]) { shaped["playCount"] = plays }
        if let count = intValue(item["song_count"]) { shaped["trackCount"] = count }
        if let creator = item["creator"] as? [String: Any],
           let creatorName = stringValue(creator["name"]) {
            shaped["creator"] = ["nickname": creatorName]
        }
        return decode(PlaylistSummary.self, from: shaped)
    }

    // MARK: - Transport

    private static func getJSON(_ url: URL) async throws -> [String: Any] {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            log.error("QQ HTTP \(http.statusCode, privacy: .public) \(url.absoluteString, privacy: .public)")
            throw QQError.malformedResponse
        }
        guard let object = parseObject(from: data) else {
            throw QQError.malformedResponse
        }
        return object
    }

    private static func postJSON(
        _ urlString: String,
        _ payload: [String: Any]
    ) async throws -> [String: Any] {
        guard let url = URL(string: urlString),
              JSONSerialization.isValidJSONObject(payload),
              let body = try? JSONSerialization.data(withJSONObject: payload)
        else { throw QQError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            log.error("QQ musicu HTTP \(http.statusCode, privacy: .public)")
            throw QQError.malformedResponse
        }
        guard let object = parseObject(from: data) else {
            throw QQError.malformedResponse
        }
        return object
    }

    /// QQ's older `fcg` endpoints wrap JSON in a JS call, and some answer with a
    /// `while(1);` anti-hijacking prefix. Both forms show up across QQ's own
    /// endpoints, so both are unwrapped before `JSONSerialization` sees them.
    static func parseObject(from data: Data) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        guard var text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }

        if text.hasPrefix("while(1);") {
            text = String(text.dropFirst("while(1);".count))
        }
        // `callback({...});`
        if let open = text.firstIndex(of: "("), text.hasSuffix(")") || text.hasSuffix(");") {
            let inner = text[text.index(after: open)...]
            let trimmedInner = inner.hasSuffix(");")
                ? String(inner.dropLast(2))
                : String(inner.dropLast())
            if let data = trimmedInner.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
        }
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Small helpers

    /// Re-encodes a dictionary of NetEase-shaped keys into an app model.
    ///
    /// Going through JSON is what lets QQ's catalog reuse NetEase's models —
    /// and therefore their whole decode path — without a memberwise initialiser
    /// for every one of them. `try?` throughout matches the models' own
    /// tolerance for missing keys.
    static func decode<T: Decodable>(_ type: T.Type, from object: [String: Any]) -> T? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    /// QQ mixes types freely — ids arrive as strings in `smartbox` and numbers
    /// in search. Empty strings become `nil` so they cannot masquerade as a
    /// usable identifier.
    static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value.isEmpty ? nil : value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    /// Several QQ endpoints still emit plain `http://` image URLs (measured
    /// 5 of 5 on the playlist-square endpoint). iOS drops those silently under
    /// ATS, so an unupgraded URL shows as a blank cover.
    static func httpsURL(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("http://") {
            return "https://" + raw.dropFirst("http://".count)
        }
        return raw
    }

    /// QQ dates are `yyyy-MM-dd` strings ("2005-11-01"). Parsed by hand rather
    /// than through a shared `DateFormatter`, which is not `Sendable` and would
    /// need locking to live in a `static let` under Swift 6.
    static func publishTimeMS(_ value: Any?) -> Int? {
        guard let text = stringValue(value) else { return nil }
        let parts = text.prefix(10).split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: components) else { return nil }
        return Int(date.timeIntervalSince1970 * 1000)
    }

    /// QQ answers lyrics with HTML entities (`&apos;` and friends) left in.
    /// `&amp;` is replaced last so that `&amp;lt;` cannot be double-decoded.
    static func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        let entities: [(String, String)] = [
            ("&apos;", "'"), ("&#39;", "'"),
            ("&quot;", "\""), ("&#34;", "\""),
            ("&lt;", "<"), ("&gt;", ">"),
            ("&nbsp;", " "),
            ("&amp;", "&"),
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }

    /// Unescapes the `\u002F`-style JSON string fragments the homepage embeds
    /// in its HTML. A JSON round trip rather than hand-rolled scanning, so
    /// `\\`, `\"`, `\n` and surrogate pairs decode exactly like a JSON parser
    /// would. Callers pass captures of `[^"]+`, which cannot contain raw
    /// quotes, so the text can be wrapped and re-parsed safely.
    static func decodeJSONEscapes(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        let wrapped = Data("\"\(text)\"".utf8)
        if let object = try? JSONSerialization.jsonObject(with: wrapped, options: [.fragmentsAllowed]),
           let string = object as? String {
            return string
        }
        return text
    }

    private static func nestedList(_ object: [String: Any], path: [String]) -> [[String: Any]]? {
        var current: Any? = object
        for key in path {
            current = (current as? [String: Any])?[key]
        }
        return current as? [[String: Any]]
    }
}
