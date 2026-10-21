import SwiftUI

/// QQ 音乐账号区块：未登录时是一行「登录 QQ 音乐」，登录后是该账号的歌单。
///
/// 为什么单独成一个文件：Kumone 的 iPhone 和 iPad 主界面是**两套**——
/// `IOSMainWindow` 里 `idiom == .pad` 走 `MainWindow` + `SidebarView`，
/// iPhone 才走标签栏 + `IOSLibraryView`。这段逻辑原先只写在 `IOSLibraryView` 里，
/// 于是 **iPad 上既没有 QQ 登录入口，也看不到自己的 QQ 歌单**。
///
/// 另外，`HomeView` 里那个平台切换是挂在 `.toolbar` 上的，而 iPad 上
/// `.toolbar` 的条目不渲染 —— `SidebarView` 的注释早就记录过同一现象
/// （搜索/设置因此被挪进侧边栏 footer，#59/#67）。所以 iPad 的平台切换
/// 也一并放进了侧边栏，见 `SidebarView` 的「音乐平台」段。
struct QQMusicAccountSection: View {
    /// 侧边栏的行高与字号比 iPhone 的 List 紧一档。
    var compact: Bool = false

    @Environment(\.openDestination) private var openDestination
    @StateObject private var qqAuth = QQMusicAuth.shared
    @State private var qqPlaylists: [PlaylistSummary] = []
    @State private var showQQLogin = false

    private var rowSpacing: CGFloat { compact ? 8 : 10 }
    private var coverSide: CGFloat { compact ? 22 : 32 }

    var body: some View {
        Group {
            if qqAuth.isLoggedIn {
                signedInSection
            } else {
                signInSection
            }
        }
        .sheet(isPresented: $showQQLogin) {
            QQLoginSheet()
                .environmentObject(ToastCenter.shared)
        }
        .task(id: qqAuth.isLoggedIn) {
            await reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: QQMusicAuth.loginDidUpdateNotification)) { _ in
            Task { await reload() }
        }
    }

    private func reload() async {
        guard qqAuth.isLoggedIn else {
            qqPlaylists = []
            return
        }
        qqPlaylists = await QQMusicAPI.userPlaylists()
    }

    // MARK: - 未登录

    private var signInSection: some View {
        Section("QQ音乐") {
            Button {
                showQQLogin = true
            } label: {
                HStack(spacing: compact ? 9 : 12) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: compact ? 17 : 24))
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("登录 QQ 音乐")
                            .font(.system(size: compact ? 13 : 14, weight: .medium))
                            .foregroundStyle(.primary)
                        Text(compact
                             ? String(localized: "显示我的 QQ 歌单")
                             : String(localized: "显示你的 QQ 歌单，不影响网易云登录"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(compact ? 1 : 2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, compact ? 2 : 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 已登录

    private var signedInSection: some View {
        Section {
            if qqPlaylists.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取 QQ 歌单…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            } else {
                // 侧边栏和标签页都不在各自的 NavigationStack 根上，所以统一走
                // `openDestination`（由 MainWindow / IOSMainWindow 注入），
                // 比自己拼 NavigationLink 更稳。
                ForEach(qqPlaylists) { playlist in
                    Button {
                        guard let dissID = playlist.mid, !dissID.isEmpty else { return }
                        openDestination(.qqPlaylist(dissID))
                    } label: {
                        HStack(spacing: rowSpacing) {
                            CachedAsyncImage(
                                url: playlist.coverURL?.resizedImageURL(80),
                                animated: false
                            )
                            .frame(width: coverSide, height: coverSide)
                            .clipShape(RoundedRectangle(
                                cornerRadius: compact ? 5 : 6,
                                style: .continuous
                            ))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(playlist.name)
                                    .font(.system(size: compact ? 12.5 : 14))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text("QQ音乐 · \(playlist.trackCount) 首")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            HStack {
                Text("QQ音乐 · \(qqAuth.nickname)")
                Spacer(minLength: 0)
                Button("退出") {
                    qqAuth.logout()
                    qqPlaylists = []
                }
                .font(.system(size: 12))
                .buttonStyle(.plain)
            }
        }
    }
}
