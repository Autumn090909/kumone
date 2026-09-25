import SwiftUI

/// The 推荐 page's QQ Music form: ranking boards, a recommended-songs mix and
/// hot playlists.
///
/// QQ ships no logged-out personalised feed, so the sections are built from
/// what its public endpoints actually offer: the board overview
/// (`fcg_myqq_toplist`), a daily-rotating mix of the hot/new/surging boards
/// (`recommendedSongs`), and the homepage's server-rendered hot playlists.
/// Every card navigates into an existing QQ detail page, and playback goes
/// through the same custom-source path as search results.
struct QQHomeView: View {
    @StateObject private var model = QQHomeModel.shared

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                loadingBody
            case .error(let message):
                ErrorStateView(message: message) {
                    Task { await model.reload() }
                }
                .frame(minHeight: 400)
            case .loaded:
                loadedBody
            }
        }
        .task(id: CatalogStore.shared.platform) {
            await model.loadIfNeeded()
        }
    }

    private var loadingBody: some View {
        VStack(alignment: .leading, spacing: 32) {
            SkeletonShelf()
            SkeletonShelf()
        }
        .padding(Theme.Layout.contentInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadedBody: some View {
        LazyVStack(alignment: .leading, spacing: 34) {
            if !model.toplists.isEmpty {
                Shelf(title: "排行榜", rowHeight: Theme.Layout.coverShelfHeight) {
                    ForEach(model.toplists) { toplist in
                        NavigationLink(value: Destination.qqToplist(
                            topID: toplist.id,
                            name: toplist.name,
                            cover: toplist.coverURL?.absoluteString
                        )) {
                            toplistCard(toplist)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !model.recommended.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "推荐歌曲", action: nil)
                        .padding(.horizontal, Theme.Layout.contentInset)
                    TrackListView(tracks: Array(model.recommended.prefix(10)))
                        .padding(.horizontal, Theme.Layout.contentInset - 10)
                }
            }

            if !model.hotPlaylists.isEmpty {
                Shelf(title: "热门歌单", rowHeight: Theme.Layout.coverShelfHeight) {
                    ForEach(model.hotPlaylists) { playlist in
                        NavigationLink(value: Destination.qqPlaylist(
                            playlist.mid ?? String(playlist.id)
                        )) {
                            CoverCardBody(
                                coverURL: playlist.coverURL?.resizedImageURL(384),
                                title: playlist.name,
                                playCount: playlist.playCount
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Text("QQ音乐支持搜索、榜单与播放；喜欢、歌单收藏等账号功能仅网易云音乐提供。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Layout.contentInset)

            PlayerClearanceSpacer()
        }
        .padding(.vertical, Theme.Layout.contentInset - 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toplistCard(_ toplist: QQMusicAPI.Toplist) -> some View {
        CoverCardBody(
            coverURL: toplist.coverURL?.resizedImageURL(384),
            title: toplist.name,
            subtitle: toplist.previewSongNames.joined(separator: " / ")
        )
    }
}

/// Shared so the loaded sections survive tab switches (no skeleton flash),
/// matching `HomeViewModel.shared`.
@MainActor
final class QQHomeModel: ObservableObject {
    static let shared = QQHomeModel()

    enum State { case idle, loading, loaded, error(String) }

    @Published var state: State = .idle
    @Published var toplists: [QQMusicAPI.Toplist] = []
    @Published var recommended: [Track] = []
    @Published var hotPlaylists: [PlaylistSummary] = []

    func loadIfNeeded() async {
        if case .loaded = state { return }
        await reload()
    }

    func reload() async {
        state = .loading
        // Three independent sources; each tolerates its own failure so one
        // throttled endpoint cannot blank the whole page.
        async let toplistsTask = try? QQMusicAPI.toplists()
        async let recommendedTask = try? QQMusicAPI.recommendedSongs(limit: 30)
        async let hotPlaylistsTask = try? QQMusicAPI.hotPlaylists(limit: 12)

        toplists = await toplistsTask ?? []
        recommended = await recommendedTask ?? []
        hotPlaylists = await hotPlaylistsTask ?? []

        let empty = toplists.isEmpty && recommended.isEmpty && hotPlaylists.isEmpty
        state = empty ? .error(String(localized: "网络连接失败")) : .loaded
    }
}
