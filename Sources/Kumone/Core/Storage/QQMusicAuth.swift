import Foundation

/// QQ Music signed-in state, backed by the cookies a web login produces.
///
/// ## Provenance
///
/// Ported from **Beans Music** (`QQMusicAuth.swift` / `QQWebLoginSheet.swift`),
/// MIT licensed, Copyright (c) 2026 XIaodou0416 — trimmed to the web-login path.
/// Beans' reverse-engineered QR-scan flow (`ptqrshow` → `ptqrlogin` →
/// `graph.qq.com` oauth → `QQConnectLogin`) was deliberately *not* ported: it
/// depends on hard-coded app ids that QQ can rotate, whereas the web flow uses
/// QQ's own login page and cannot be revoked from under us.
///
/// ## How login works
///
/// The in-app WebView (iOS) loads `y.qq.com`; the user completes QQ's own
/// login there. The login cookies (`uin`, `qqmusic_key`/`qm_keyst`, `p_skey`,
/// …) land in the WebView's cookie store; the sheet reads them back and hands
/// them here via `importCookies`. A paste-the-cookie fallback covers desktop.
final class QQMusicAuth: ObservableObject {
    static let shared = QQMusicAuth()

    @Published private(set) var isLoggedIn = false
    @Published private(set) var nickname = ""

    private var cookies: [String: String] = [:]

    private let defaults = UserDefaults.standard
    private static let cookieKey = "kumone.qqmusic.cookie.v1"
    private static let nickKey = "kumone.qqmusic.nickname.v1"

    static let loginDidUpdateNotification = Notification.Name("kumone.qqmusic.loginDidUpdate")

    private init() {
        if let saved = defaults.dictionary(forKey: Self.cookieKey) as? [String: String], !saved.isEmpty {
            cookies = saved
            isLoggedIn = true
            nickname = defaults.string(forKey: Self.nickKey) ?? Self.fallbackNickname(saved)
        }
    }

    // MARK: - Identities read out of the cookie jar

    /// Numeric account id ("o1234567" → "1234567"). WeChat sessions carry
    /// `wxuin` instead, so both are accepted.
    var uin: String {
        Self.normalizedUIN(Self.accountID(from: cookies))
    }

    /// First identity candidate that playlist endpoints recognise. WeChat
    /// logins often lack a usable `uin`, in which case `wxuin` is used.
    var playlistUin: String {
        Self.playlistUin(from: cookies)
    }

    static func playlistUin(from cookies: [String: String]) -> String {
        if isWeChatLogin(cookies: cookies),
           !hasUsableAccountID(cookies["p_uin"]),
           !hasUsableAccountID(cookies["pt2gguin"]) {
            return normalizedUIN(cookies["wxuin"] ?? "0")
        }
        for key in ["uin", "p_uin", "pt2gguin"] {
            guard let value = cookies[key], hasUsableAccountID(value) else { continue }
            return normalizedUIN(value)
        }
        return "0"
    }

    var isWeChatLogin: Bool {
        Self.isWeChatLogin(cookies: cookies)
    }

    static func isWeChatLogin(cookies: [String: String]) -> Bool {
        hasUsableAccountID(cookies["wxuin"]) || !(cookies["wxopenid"] ?? "").isEmpty
    }

    /// Every account id the playlist endpoints should be tried with. Some
    /// accounts only answer when the request carries `wxuin` explicitly.
    var playlistIdentityCandidates: [String] {
        Self.identityCandidates(from: cookies)
    }

    static func identityCandidates(from cookies: [String: String]) -> [String] {
        [cookies["p_uin"], cookies["pt2gguin"], cookies["uin"], cookies["wxuin"], playlistUin(from: cookies), "0"]
            .compactMap { value -> String? in
                guard let value, hasUsableAccountID(value) || value == "0" else { return nil }
                return normalizedUIN(value)
            }
            .reduce(into: [String]()) { result, value in
                if !result.contains(value) { result.append(value) }
            }
    }

    /// `g_tk` — the checksum legacy `fcg` write-ish endpoints require, hashed
    /// from whichever music credential the jar holds.
    var gtk: Int {
        let key = cookies["qqmusic_key"]
            ?? cookies["qm_keyst"]
            ?? cookies["wxskey"]
            ?? cookies["p_skey"]
            ?? cookies["skey"]
            ?? ""
        return key.isEmpty ? 5381 : Self.hash5381(key)
    }

    /// Cookie header for `u.y.qq.com` (keeps music-domain credentials first).
    var cookieHeader: String {
        Self.cookieHeaderValue(from: cookies, includeCompatibilityUIN: true)
    }

    /// Playlist endpoints misread a compatibility `uin=wxuin` as a QQ uin and
    /// answer with an empty list, so those callers pass this instead.
    var playlistCookieHeader: String {
        Self.cookieHeaderValue(from: cookies, includeCompatibilityUIN: false)
    }

    static func cookieHeaderValue(
        from cookies: [String: String],
        includeCompatibilityUIN: Bool
    ) -> String {
        let order = [
            "uin", "wxuin", "p_uin", "wxopenid",
            "qm_keyst", "qqmusic_key", "music_key", "wxskey", "wx_skey",
            "musickey", "p_skey", "skey", "pt4_token",
        ]
        var pairs: [String] = order.compactMap { key in
            guard let value = cookies[key], !value.isEmpty else { return nil }
            return "\(key)=\(value)"
        }
        if includeCompatibilityUIN,
           !Self.hasUsableAccountID(cookies["uin"]),
           let wxuin = cookies["wxuin"], !wxuin.isEmpty {
            pairs.insert("uin=\(wxuin)", at: 0)
        }
        return pairs.joined(separator: "; ")
    }

    // MARK: - Login / logout

    /// Stores a validated cookie jar and marks the session signed in.
    func importCookies(_ dict: [String: String], nickname: String?) {
        guard !dict.isEmpty else { return }
        cookies = dict
        let resolved = nickname ?? Self.fallbackNickname(dict)
        isLoggedIn = true
        self.nickname = resolved
        defaults.set(cookies, forKey: Self.cookieKey)
        defaults.set(resolved, forKey: Self.nickKey)
        NotificationCenter.default.post(name: Self.loginDidUpdateNotification, object: nil)
        Task { await fetchProfile() }
    }

    func logout() {
        cookies = [:]
        isLoggedIn = false
        nickname = ""
        defaults.removeObject(forKey: Self.cookieKey)
        defaults.removeObject(forKey: Self.nickKey)
        NotificationCenter.default.post(name: Self.loginDidUpdateNotification, object: nil)
    }

    // MARK: - Cookie intake helpers

    /// Cookie names the WebView sync is interested in; everything else on the
    /// `.qq.com` domains is noise.
    static let webCookieNames: Set<String> = [
        "uin", "wxuin", "p_uin", "wxopenid", "skey", "p_skey",
        "qqmusic_key", "qm_keyst", "music_key", "wxskey", "wx_skey",
        "musickey", "pt4_token", "pt2gguin", "pt_login_sig", "pt4_aid",
        "qmusic_s", "pgv_pvid", "pgv_info", "ptnick", "nick", "nickname",
    ]

    /// Parses a cookie header copied out of a desktop browser's devtools:
    /// `"a=b; c=d"`.
    static func parseCookieHeader(_ header: String) -> [String: String] {
        var dict: [String: String] = [:]
        for part in header.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = kv[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !value.isEmpty {
                dict[key] = value
            }
        }
        return dict
    }

    /// Returns the reason a cookie jar is *not* a usable login, or `nil` when
    /// it is. Distinguishes "never finished the login" from "logged in but QQ
    /// Music never issued its credential".
    static func loginValidationMessage(_ dict: [String: String]) -> String? {
        guard hasUsableAccountID(accountID(from: dict)) else {
            return "没有读取到 QQ 账号标识，请确认网页里的登录已经完成"
        }
        let credentialKeys = [
            "p_skey", "skey", "qqmusic_key", "qm_keyst",
            "music_key", "wxskey", "wx_skey", "musickey",
        ]
        guard credentialKeys.contains(where: { !(dict[$0] ?? "").isEmpty }) else {
            return "已读到账号，但缺少 QQ 音乐登录凭证，请在网页中重新登录后再同步"
        }
        return nil
    }

    /// Display name fallback: ptlogin's `ptnick_*` cookie first, then the bare
    /// account id.
    static func fallbackNickname(_ dict: [String: String]) -> String {
        if let key = dict.keys.first(where: { $0.hasPrefix("ptnick") }),
           let raw = dict[key], !raw.isEmpty {
            return raw.removingPercentEncoding ?? raw
        }
        if let nick = dict["nick"], !nick.isEmpty { return nick }
        let clean = normalizedUIN(accountID(from: dict))
        return clean.isEmpty ? "QQ音乐用户" : "QQ音乐用户 \(clean)"
    }

    // MARK: - Profile refresh (best effort)

    /// Asks QQ's profile homepage endpoint for the real nickname. Failure is
    /// silent — the cookie-derived fallback name keeps working.
    @MainActor
    func fetchProfile() async {
        guard isLoggedIn, !uin.isEmpty, uin != "0" else { return }
        var components = URLComponents(string: "https://c.y.qq.com/rsc/fcgi-bin/fcg_get_profile_homepage.fcg")
        components?.queryItems = [
            URLQueryItem(name: "cid", value: "205360838"),
            URLQueryItem(name: "userid", value: uin),
            URLQueryItem(name: "reqfrom", value: "1"),
            URLQueryItem(name: "g_tk", value: "5381"),
            URLQueryItem(name: "loginUin", value: uin),
            URLQueryItem(name: "hostUin", value: "0"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "inCharset", value: "utf8"),
            URLQueryItem(name: "outCharset", value: "utf-8"),
            URLQueryItem(name: "notice", value: "0"),
            URLQueryItem(name: "platform", value: "yqq.json"),
            URLQueryItem(name: "needNewCode", value: "0"),
        ]
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        // code 1000 = the profile endpoint itself is unavailable; the session
        // is still valid, so treat that as "no nickname" rather than failure.
        let code = object["code"] as? Int ?? -1
        guard code == 0 || code == 1000 else { return }
        if let nick = Self.extractNickname(from: object), !nick.isEmpty, nick != nickname {
            nickname = nick
            defaults.set(nick, forKey: Self.nickKey)
        }
    }

    private static func extractNickname(from json: [String: Any]) -> String? {
        if let data = json["data"] as? [String: Any],
           let mymusic = data["mymusic"] as? [String: Any],
           let info = mymusic["info"] as? [String: Any],
           let nick = info["nick"] as? String, !nick.isEmpty {
            return nick
        }
        var found: String?
        func walk(_ value: Any) {
            if found != nil { return }
            if let dict = value as? [String: Any] {
                if let nick = dict["nick"] as? String, !nick.isEmpty { found = nick; return }
                if let nick = dict["nickname"] as? String, !nick.isEmpty { found = nick; return }
                for (_, v) in dict { walk(v) }
            } else if let array = value as? [Any] {
                for v in array { walk(v) }
            }
        }
        walk(json)
        return found
    }

    // MARK: - Static helpers

    private static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    private static func accountID(from cookies: [String: String]) -> String {
        for key in ["uin", "wxuin", "pt2gguin"] {
            guard let value = cookies[key], hasUsableAccountID(value) else { continue }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "0"
    }

    private static func hasUsableAccountID(_ raw: String?) -> Bool {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return false }
        return value != "0" && value != "o0"
    }

    private static func normalizedUIN(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        return value.hasPrefix("o") ? String(value.dropFirst()) : value
    }

    /// The `g_tk` hash QQ's web front end uses: `e = 5381; e += (e << 5) + code`
    /// over UTF-16 units, truncated to 31 bits. JavaScript accumulates in
    /// IEEE-754 doubles without intermediate 32-bit wrapping, so the Swift
    /// port must simulate that with `Double` or long keys silently diverge.
    static func hash5381(_ t: String) -> Int {
        var e: Double = 5381
        for unit in t.utf16 {
            e = e + Double(Self.toInt32Shift(e)) + Double(unit)
        }
        return Int(Self.toInt32(e) & 0x7FFF_FFFF)
    }

    private static func toInt32Shift(_ d: Double) -> Int32 {
        Int32(bitPattern: toUInt32(d) &* 32)
    }

    private static func toInt32(_ d: Double) -> Int32 {
        Int32(bitPattern: toUInt32(d))
    }

    private static func toUInt32(_ d: Double) -> UInt32 {
        var r = d.truncatingRemainder(dividingBy: 4294967296.0)
        if r < 0 { r += 4294967296.0 }
        return UInt32(r)
    }
}
