import SwiftUI
#if canImport(WebKit)
import WebKit
#endif

/// QQ Music login.
///
/// Two doors, both ending in `QQMusicAuth.importCookies`:
/// - **网页登录** (iOS): an in-app WebView opens `y.qq.com`; the user taps the
///   page's own 登录 button and completes QQ's login there. The login cookies
///   land in the WebView's cookie store and the 同步 button harvests them.
/// - **粘贴 Cookie** (everywhere): the desktop escape hatch — copy the Cookie
///   request header out of a browser's devtools and paste it here.
struct QQLoginSheet: View {
    @State private var message = ""
    @State private var syncing = false
    @EnvironmentObject private var account: ToastCenter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("登录 QQ 音乐")
                    .font(.title3.weight(.semibold))
                Text("用于显示你的 QQ 歌单；网易云的账号功能不受影响")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 24)

            #if canImport(UIKit)
            webLoginSection
            Divider()
                .padding(.horizontal, 24)
            #endif

            cookieSection

            Button("取消") {
                dismiss()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .padding(.bottom, 20)
        }
        .frame(width: 360)
    }

    #if canImport(UIKit)
    // MARK: - Web login (iOS)

    @State private var pageLoaded = false

    private var webLoginSection: some View {
        VStack(spacing: 10) {
            Text("① 在下方网页右上角点「登录」，完成 QQ 扫码")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("② 回到这里点「同步登录状态」")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            ZStack {
                QQLoginWebView(onLoaded: { pageLoaded = true })
                    .frame(height: 380)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
                    }

                if !pageLoaded {
                    ProgressView("正在加载 QQ 音乐…")
                        .padding(40)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }

            Button {
                syncFromWebView()
            } label: {
                HStack(spacing: 6) {
                    if syncing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(syncing ? "正在读取登录状态…" : "同步登录状态")
                }
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Theme.accent, in: Capsule())
                .foregroundStyle(.white)
            }
            .buttonStyle(.pressable)
            .disabled(syncing)
        }
        .padding(.horizontal, 24)
    }

    private func syncFromWebView() {
        syncing = true
        message = ""
        readWebViewCookies { dict in
            syncing = false
            if let issue = QQMusicAuth.loginValidationMessage(dict) {
                message = issue
                return
            }
            finishLogin(with: dict)
        }
    }

    /// Harvests the login cookies out of the shared WebView cookie store,
    /// falling back to every `.qq.com` cookie when the shortlist is not enough
    /// (WeChat logins use dynamic cookie names).
    private func readWebViewCookies(_ completion: @escaping ([String: String]) -> Void) {
        let wanted = QQMusicAuth.webCookieNames
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            var dict: [String: String] = [:]
            for cookie in cookies where wanted.contains(cookie.name) || cookie.name.hasPrefix("ptnick") {
                dict[cookie.name] = cookie.value
            }
            if QQMusicAuth.loginValidationMessage(dict) != nil {
                for cookie in cookies where cookie.domain.lowercased().hasSuffix("qq.com") {
                    dict[cookie.name] = cookie.value
                }
            }
            DispatchQueue.main.async { completion(dict) }
        }
    }
    #endif

    // MARK: - Paste-cookie fallback (all platforms)

    @State private var cookieText = ""

    private var cookieSection: some View {
        VStack(spacing: 8) {
            #if canImport(UIKit)
            Text("或用电脑登录 y.qq.com 后，把 Cookie 粘贴到下面")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            #else
            Text("电脑浏览器打开 y.qq.com 并登录，按 F12 → 网络 → 刷新，点任意请求，复制请求头里整段 Cookie 粘贴到下面")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            #endif

            TextField("qqmusic_key=…; uin=…; p_skey=…", text: $cookieText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 24)

            Button {
                importPastedCookie()
            } label: {
                Label("导入 Cookie", systemImage: "arrow.down.doc")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Theme.accent.opacity(0.15), in: Capsule())
            }
            .buttonStyle(.pressable)
            .padding(.horizontal, 24)

            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(message.hasPrefix("✓") ? Color.green : Color.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .padding(.bottom, 8)
    }

    private func importPastedCookie() {
        let dict = QQMusicAuth.parseCookieHeader(cookieText)
        guard QQMusicAuth.loginValidationMessage(dict) == nil else {
            message = "Cookie 不完整或登录态无效，请确认已完整复制"
            return
        }
        finishLogin(with: dict)
    }

    private func finishLogin(with dict: [String: String]) {
        QQMusicAuth.shared.importCookies(dict, nickname: nil)
        message = "✓ QQ 音乐登录成功"
        account.show("QQ 音乐登录成功")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            dismiss()
        }
    }
}

#if canImport(UIKit)
/// The web side of web login: QQ Music's own site inside a plain WebView, so
/// QQ's login page, QR code and risk control all behave exactly as in Safari.
private struct QQLoginWebView: UIViewRepresentable {
    let onLoaded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoaded: onLoaded)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // A desktop Safari agent keeps y.qq.com on its full layout instead of
        // bouncing to a mobile interstitial.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        webView.navigationDelegate = context.coordinator
        if let url = URL(string: "https://y.qq.com/") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onLoaded: () -> Void

        init(onLoaded: @escaping () -> Void) {
            self.onLoaded = onLoaded
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async { self.onLoaded() }
        }
    }
}
#endif
