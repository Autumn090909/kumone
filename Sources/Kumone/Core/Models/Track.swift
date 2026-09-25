import Foundation

struct ArtistRef: Codable, Hashable, Identifiable {
    let id: Int
    let name: String

    init(id: Int, name: String) {
        self.id = id
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
    }
}

struct AlbumRef: Codable, Hashable, Identifiable {
    let id: Int
    let name: String
    let picUrl: String?

    init(id: Int, name: String, picUrl: String?) {
        self.id = id
        self.name = name
        self.picUrl = picUrl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        picUrl = try? c.decode(String.self, forKey: .picUrl)
    }
}

/// Which platform's catalog a track came from.
///
/// The app was a NetEase client before QQ Music was added, so every payload
/// persisted by an older build (favourites, play history, cached metadata,
/// downloads) carries no platform. Those decode to `.netease` rather than
/// failing, which is why `init(from:)` uses `try?` plus a default instead of a
/// required decode.
enum TrackPlatform: String, Codable, Hashable, Sendable, CaseIterable {
    case netease
    case qq

    /// The key a compatible custom-source script is asked for when serving a
    /// track from this platform. These are LX Music's own codes — `wy` for
    /// 网易云 and `tx` for QQ音乐 — and scripts in the wild match on exactly
    /// these strings, so they are not ours to rename.
    var lxSourceKey: String {
        switch self {
        case .netease: return "wy"
        case .qq: return "tx"
        }
    }

    var displayName: String {
        switch self {
        case .netease: return String(localized: "网易云音乐")
        case .qq: return String(localized: "QQ音乐")
        }
    }

    /// The two platforms number their songs independently, so an `Int` song id
    /// is only unique *within* a platform. Anything keyed by that id alone has
    /// to say which platform it means.
    var cacheKeyPrefix: String { rawValue }

    /// QQ's own artwork CDN. NetEase's `?param=WyH` resize convention does not
    /// apply here, so covers are built by template instead.
    static func qqAlbumCoverURL(albumMid: String, size: Int = 300) -> URL? {
        guard !albumMid.isEmpty else { return nil }
        return URL(string: "https://y.gtimg.cn/music/photo_new/T002R\(size)x\(size)M000\(albumMid).jpg")
    }
}

/// A unified track model that decodes both the "v3" song shape (`ar`/`al`/`dt`)
/// and the legacy shape (`artists`/`album`/`duration`).
struct Track: Codable, Hashable, Identifiable {
    let id: Int
    let name: String
    let artists: [ArtistRef]
    let album: AlbumRef
    let durationMS: Int
    let alias: [String]
    let transNames: [String]
    let fee: Int
    let mvID: Int
    let trackNo: Int
    let disc: String?
    let noCopyright: Bool
    /// Cloud-disk song marker (`pc` field present).
    let isCloud: Bool
    /// Some endpoints (cloudsearch, FM) embed the privilege in the track itself.
    let embeddedPrivilege: TrackPrivilege?

    /// Defaults to `.netease` so tracks decoded from pre-QQ payloads, and every
    /// call site that predates the field, keep meaning what they meant.
    let platform: TrackPlatform
    /// QQ's string song mid. **This is the identifier third-party scripts want**
    /// for `source: "tx"`; the numeric `id` is not a substitute.
    let songmid: String?
    /// QQ's `file.media_mid` / `strMediaMid`. Frequently equal to `songmid` but
    /// not always, and a script handed the wrong one gets nothing back, so the
    /// two are carried separately rather than assumed equal.
    let mediaMid: String?
    /// QQ album mid — the input to the artwork template and, for some scripts,
    /// the key they request album data with.
    let albumMid: String?

    var artistNames: String { artists.map(\.name).joined(separator: " / ") }
    var duration: TimeInterval { TimeInterval(durationMS) / 1000 }
    var subtitle: String? { transNames.first ?? alias.first }

    /// Explicit because a custom `init(from:)` in the body suppresses the
    /// synthesised memberwise one, and the QQ catalog needs to build tracks.
    init(
        id: Int,
        name: String,
        artists: [ArtistRef],
        album: AlbumRef,
        durationMS: Int,
        alias: [String] = [],
        transNames: [String] = [],
        fee: Int = 0,
        mvID: Int = 0,
        trackNo: Int = 0,
        disc: String? = nil,
        noCopyright: Bool = false,
        isCloud: Bool = false,
        embeddedPrivilege: TrackPrivilege? = nil,
        platform: TrackPlatform = .netease,
        songmid: String? = nil,
        mediaMid: String? = nil,
        albumMid: String? = nil
    ) {
        self.id = id
        self.name = name
        self.artists = artists
        self.album = album
        self.durationMS = durationMS
        self.alias = alias
        self.transNames = transNames
        self.fee = fee
        self.mvID = mvID
        self.trackNo = trackNo
        self.disc = disc
        self.noCopyright = noCopyright
        self.isCloud = isCloud
        self.embeddedPrivilege = embeddedPrivilege
        self.platform = platform
        self.songmid = songmid
        self.mediaMid = mediaMid
        self.albumMid = albumMid
    }

    private enum CodingKeys: String, CodingKey {
        case id, name
        case ar, artists
        case al, album
        case dt, duration
        case alia, alias
        case tns, fee, mv, no, cd, noCopyrightRcmd, pc, privilege
        case platform, songmid, mediaMid, albumMid
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        artists = (try? c.decode([ArtistRef].self, forKey: .ar))
            ?? (try? c.decode([ArtistRef].self, forKey: .artists)) ?? []
        album = (try? c.decode(AlbumRef.self, forKey: .al))
            ?? (try? c.decode(AlbumRef.self, forKey: .album))
            ?? AlbumRef(id: 0, name: "", picUrl: nil)
        durationMS = (try? c.decode(Int.self, forKey: .dt))
            ?? (try? c.decode(Int.self, forKey: .duration)) ?? 0
        alias = (try? c.decode([String].self, forKey: .alia))
            ?? (try? c.decode([String].self, forKey: .alias)) ?? []
        transNames = (try? c.decode([String].self, forKey: .tns)) ?? []
        fee = (try? c.decode(Int.self, forKey: .fee)) ?? 0
        mvID = (try? c.decode(Int.self, forKey: .mv)) ?? 0
        trackNo = (try? c.decode(Int.self, forKey: .no)) ?? 0
        disc = try? c.decode(String.self, forKey: .cd)
        noCopyright = c.contains(.noCopyrightRcmd)
            && (try? c.decodeNil(forKey: .noCopyrightRcmd)) == false
        isCloud = c.contains(.pc) && (try? c.decodeNil(forKey: .pc)) == false
        embeddedPrivilege = try? c.decode(TrackPrivilege.self, forKey: .privilege)
        // Absent means "written before the field existed", which can only be
        // NetEase — that was the only platform then.
        platform = (try? c.decode(TrackPlatform.self, forKey: .platform)) ?? .netease
        songmid = try? c.decode(String.self, forKey: .songmid)
        mediaMid = try? c.decode(String.self, forKey: .mediaMid)
        albumMid = try? c.decode(String.self, forKey: .albumMid)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(artists, forKey: .ar)
        try c.encode(album, forKey: .al)
        try c.encode(durationMS, forKey: .dt)
        try c.encode(alias, forKey: .alia)
        try c.encode(transNames, forKey: .tns)
        try c.encode(fee, forKey: .fee)
        try c.encode(mvID, forKey: .mv)
        try c.encode(trackNo, forKey: .no)
        try c.encodeIfPresent(disc, forKey: .cd)
        // Omitted for NetEase so its persisted payloads stay byte-identical to
        // what earlier builds wrote — cached metadata and downloads keep
        // round-tripping through code that predates this field.
        if platform != .netease { try c.encode(platform, forKey: .platform) }
        try c.encodeIfPresent(songmid, forKey: .songmid)
        try c.encodeIfPresent(mediaMid, forKey: .mediaMid)
        try c.encodeIfPresent(albumMid, forKey: .albumMid)
    }
}

/// Playability flags per track, returned in parallel `privileges` arrays.
struct TrackPrivilege: Codable, Hashable {
    let id: Int
    let fee: Int?
    let pl: Int?
    let st: Int?
    let cs: Bool?
    let maxbr: Int?
}

enum TrackPlayability: Hashable {
    case playable
    case vipOnly
    case paidAlbum
    case noCopyright
    case delisted

    var reason: String? {
        switch self {
        case .playable: return nil
        case .vipOnly: return String(localized: "VIP 专属")
        case .paidAlbum: return String(localized: "付费专辑")
        case .noCopyright: return String(localized: "无版权")
        case .delisted: return String(localized: "已下架")
        }
    }
}

extension Track {
    /// Mirrors YesPlayMusic's `isTrackPlayable` decision chain,
    /// with the VIP check widened to cover 黑胶 SVIP (vipType 110 etc).
    ///
    /// Only meaningful for NetEase: the privileges it reads are NetEase's, and a
    /// QQ track carries none. QQ playability is decided by whether a custom
    /// source can serve the track, not by this.
    func playability(privilege: TrackPrivilege?, isLoggedIn: Bool, vipType: Int) -> TrackPlayability {
        let privilege = privilege ?? embeddedPrivilege
        if let pl = privilege?.pl, pl > 0 { return .playable }
        if isLoggedIn, privilege?.cs == true { return .playable }
        let effectiveFee = privilege?.fee ?? fee
        if effectiveFee == 1 {
            return vipType > 0 ? .playable : .vipOnly
        }
        if effectiveFee == 4 { return .paidAlbum }
        if noCopyright { return .noCopyright }
        if let st = privilege?.st, st < 0, isLoggedIn { return .delisted }
        return .playable
    }
}

extension Array where Element == Track {
    @discardableResult
    mutating func replaceRecommendation(_ rejected: Track, with replacement: Track) -> Bool {
        guard let index = firstIndex(where: { $0.id == rejected.id }),
              replacement.id != rejected.id,
              !contains(where: { $0.id == replacement.id }) else { return false }
        self[index] = replacement
        return true
    }
}
