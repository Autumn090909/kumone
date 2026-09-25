import Foundation
import os.log

/// QQ Music catalog access — search only.
///
/// ## Provenance
///
/// The request shape here (endpoint, query parameter names, the `Referer` QQ
/// insists on, and the `while(1);` / `callback({…})` prefixes its older
/// endpoints emit) was ported from **Beans Music**
/// (https://github.com/XIaodou0416/Beans-Music), MIT licensed,
/// Copyright (c) 2026 XIaodou0416.
///
/// ## Why only search
///
/// Beans also carries a full `vkey.GetVkeyServer` playback path (~300 lines:
/// multi-format `filename` candidates, `media_mid` back-fill, bitrate fallback
/// chain, CDN rotation, a persistent device guid, a Range pre-flight). That path
/// was measured against the live endpoints before porting and **returns an empty
/// `purl` for every track while logged out — including tracks whose `payplay`
/// is 0**, i.e. the free ones. The legacy
/// `fcg_music_express_mobile3` endpoint answers `code 104003` (no permission)
/// under the same conditions.
///
/// Porting it would therefore have produced dead code plus a QQ login flow.
/// Playback here is instead served by the user's compatible custom-source
/// scripts, which were measured to accept `source: "tx"` and to request the
/// correct song mid — so this type's only job is to turn "search QQ" into
/// `Track` values that the script layer can act on.
enum QQMusicAPI {
    private static let log = Logger(subsystem: "im.missuo.kumone", category: "qq-api")

    private static let searchEndpoint =
        "https://c.y.qq.com/soso/fcgi-bin/search_for_qq_cp"

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

        var errorDescription: String? {
            switch self {
            case .invalidURL: return String(localized: "无法构造 QQ 音乐请求地址")
            case .malformedResponse: return String(localized: "QQ 音乐返回了无法解析的内容")
            }
        }
    }

    /// Searches QQ's song catalog.
    ///
    /// - Parameter limit: how many results to ask for. QQ caps this quietly, so
    ///   the caller gets whatever comes back rather than an error.
    static func searchSongs(
        _ keyword: String,
        limit: Int = 30,
        page: Int = 1
    ) async throws -> [Track] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: searchEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "w", value: trimmed),
            URLQueryItem(name: "n", value: String(limit)),
            URLQueryItem(name: "p", value: String(max(page, 1))),
            // 0 = songs. Artist / album / playlist search use a different
            // `search_type` on the `musicu.fcg` gateway and are not wired up yet.
            URLQueryItem(name: "t", value: "0"),
        ]
        guard let url = components?.url else { throw QQError.invalidURL }

        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            log.error("QQ search HTTP \(http.statusCode, privacy: .public)")
            throw QQError.malformedResponse
        }

        guard let object = parseObject(from: data),
              let data0 = object["data"] as? [String: Any],
              let song = data0["song"] as? [String: Any],
              let list = song["list"] as? [[String: Any]]
        else {
            throw QQError.malformedResponse
        }

        return list.compactMap(track(from:))
    }

    // MARK: - Parsing

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

    /// Field names here are the ones the search endpoint actually returned when
    /// this was written — verified against a live response rather than taken
    /// from documentation, since QQ shifts them. Notably `songname` /
    /// `albumname` / `albummid` (no underscores) and `interval` in **seconds**.
    /// Internal rather than private so the mapping can be unit-tested against a
    /// fixture of the live response; field names move, and a wrong one here
    /// fails silently as an empty album or a blank artist.
    static func track(from item: [String: Any]) -> Track? {
        guard let songID = intValue(item["songid"]), songID > 0,
              let songmid = item["songmid"] as? String, !songmid.isEmpty
        else { return nil }

        let artists: [ArtistRef] = (item["singer"] as? [[String: Any]])?.map { singer in
            ArtistRef(
                id: intValue(singer["id"]) ?? 0,
                name: (singer["name"] as? String) ?? ""
            )
        } ?? []

        let albumMid = (item["albummid"] as? String) ?? ""
        let albumID = intValue(item["albumid"]) ?? 0
        let albumName = (item["albumname"] as? String) ?? ""
        let cover = TrackPlatform.qqAlbumCoverURL(albumMid: albumMid)

        return Track(
            id: songID,
            name: (item["songname"] as? String) ?? "",
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
            // Not returned by search; only QQ's own `get_song_detail` carries it,
            // and the script layer falls back to `songmid` which is what the
            // aggregators actually request.
            mediaMid: nil,
            albumMid: albumMid.isEmpty ? nil : albumMid
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
}
