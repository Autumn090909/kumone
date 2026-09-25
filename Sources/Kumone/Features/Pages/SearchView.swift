import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case all = "综合"
        case songs = "单曲"
        case artists = "歌手"
        case albums = "专辑"
        case playlists = "歌单"

        var id: String { rawValue }
    }

    /// QQ's catalog is only wired up for song search so far. Offering its other
    /// tabs would mean tabs that always come back empty, so the set is narrowed
    /// per platform instead of pretending all five work everywhere.
    static func tabs(for platform: TrackPlatform) -> [Tab] {
        switch platform {
        case .netease: return Tab.allCases
        case .qq: return [.songs]
        }
    }

    private static let platformDefaultsKey = "kumone.search.platform"

    var query: String
    @Published var platform: TrackPlatform
    @Published var tab: Tab = .all
    @Published var songs: [Track] = []
    @Published var artists: [ArtistSummary] = []
    @Published var albums: [AlbumSummary] = []
    @Published var playlists: [PlaylistSummary] = []
    @Published var isLoading = false
    @Published var loadedTabs: Set<Tab> = []

    init(query: String) {
        self.query = query
        // Which catalog you search is a preference rather than a per-search
        // choice, so it survives relaunch.
        let stored = UserDefaults.standard.string(forKey: Self.platformDefaultsKey)
        let restored = stored.flatMap(TrackPlatform.init(rawValue:)) ?? .netease
        self.platform = restored
        self.tab = Self.tabs(for: restored).first ?? .songs
    }

    func setPlatform(_ newPlatform: TrackPlatform) {
        guard newPlatform != platform else { return }
        platform = newPlatform
        UserDefaults.standard.set(newPlatform.rawValue, forKey: Self.platformDefaultsKey)
        // Results belong to the catalog that produced them, so switching starts
        // over rather than mixing QQ songs into a NetEase list.
        resetResults()
        let available = Self.tabs(for: newPlatform)
        if !available.contains(tab) { tab = available.first ?? .songs }
    }

    func setQuery(_ newQuery: String) {
        guard newQuery != query else { return }
        query = newQuery
        resetResults()
    }

    private func resetResults() {
        loadedTabs.removeAll()
        songs = []
        artists = []
        albums = []
        playlists = []
    }

    func load(tab: Tab) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !loadedTabs.contains(tab) else { return }
        isLoading = true
        defer { isLoading = false }
        loadedTabs.insert(tab)

        switch platform {
        case .qq:
            // Song search is the only QQ call wired up; the other tabs are not
            // offered (see `tabs(for:)`), so this is unreachable rather than
            // silently dropped.
            guard tab == .songs else { return }
            songs = (try? await QQMusicAPI.searchSongs(trimmed, limit: 100)) ?? songs
        case .netease:
            await loadNetease(tab: tab, keyword: trimmed)
        }
    }

    private func loadNetease(tab: Tab, keyword trimmed: String) async {
        switch tab {
        case .all:
            async let songsTask = try? NeteaseAPI.search(trimmed, type: .songs, limit: 12)
            async let artistsTask = try? NeteaseAPI.search(trimmed, type: .artists, limit: 10)
            async let albumsTask = try? NeteaseAPI.search(trimmed, type: .albums, limit: 10)
            async let playlistsTask = try? NeteaseAPI.search(trimmed, type: .playlists, limit: 10)
            songs = (await songsTask)?.songs ?? []
            artists = (await artistsTask)?.artists ?? []
            albums = (await albumsTask)?.albums ?? []
            playlists = (await playlistsTask)?.playlists ?? []
        case .songs:
            songs = (try? await NeteaseAPI.search(trimmed, type: .songs, limit: 100))?.songs ?? songs
        case .artists:
            artists = (try? await NeteaseAPI.search(trimmed, type: .artists, limit: 50))?.artists ?? artists
        case .albums:
            albums = (try? await NeteaseAPI.search(trimmed, type: .albums, limit: 50))?.albums ?? albums
        case .playlists:
            playlists = (try? await NeteaseAPI.search(trimmed, type: .playlists, limit: 50))?.playlists ?? playlists
        }
    }
}

struct SearchView: View {
    @StateObject private var model: SearchViewModel
    @State private var searchText: String = ""
    @EnvironmentObject private var player: PlayerService

    init(query: String) {
        _model = StateObject(wrappedValue: SearchViewModel(query: query))
        _searchText = State(initialValue: query)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    platformPicker
                        .padding(.horizontal, Theme.Layout.contentInset)
                        .padding(.top, 12)

                    // A single tab is not a choice, so the control is hidden
                    // rather than shown holding one option.
                    if availableTabs.count > 1 {
                        Picker("", selection: $model.tab) {
                            ForEach(availableTabs) { tab in
                                Text(LocalizedStringKey(tab.rawValue)).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .padding(.horizontal, Theme.Layout.contentInset)
                    }

                    if model.isLoading && currentEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        tabContent
                    }
                } else {
                    emptySearchPrompt
                }
                PlayerClearanceSpacer()
            }
        }
        #if os(iOS)
        // iPad enters SearchView from the sidebar, where the desktop window
        // toolbar search field is unavailable. On macOS, MainWindow owns the
        // only search field and navigates here with its submitted query.
        .searchable(text: $searchText, prompt: "搜索歌曲、歌手、专辑、歌单")
        .onSubmit(of: .search) {
            model.setQuery(searchText)
            Task { await model.load(tab: model.tab) }
        }
        .onChange(of: searchText) { newValue in
            model.setQuery(newValue)
            Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if searchText == newValue {
                    await model.load(tab: model.tab)
                }
            }
        }
        #endif
        .navigationTitle(searchText.isEmpty ? "搜索" : String(localized: "搜索：\(searchText)"))
        .task(id: model.tab) {
            await model.load(tab: model.tab)
        }
        // Switching platform usually keeps the same tab, so `task(id:)` above
        // would not fire; the model has already dropped its results by then.
        .onChange(of: model.platform) { _ in
            Task { await model.load(tab: model.tab) }
        }
    }

    private var availableTabs: [SearchViewModel.Tab] {
        SearchViewModel.tabs(for: model.platform)
    }

    private var platformPicker: some View {
        Picker("", selection: Binding<TrackPlatform>(
            get: { model.platform },
            set: { model.setPlatform($0) }
        )) {
            ForEach(TrackPlatform.allCases, id: \.self) { platform in
                Text(platform.displayName).tag(platform)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var emptySearchPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.top, 60)
            Text("探索海量华语流行与经典音乐")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("输入歌曲名称、歌手名或歌单关键字开始搜索")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }

    private var currentEmpty: Bool {
        switch model.tab {
        case .all: return model.songs.isEmpty && model.artists.isEmpty
        case .songs: return model.songs.isEmpty
        case .artists: return model.artists.isEmpty
        case .albums: return model.albums.isEmpty
        case .playlists: return model.playlists.isEmpty
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch model.tab {
        case .all:
            if !model.songs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "单曲") {
                        model.tab = .songs
                    }
                    .padding(.horizontal, Theme.Layout.contentInset)
                    TrackListView(tracks: Array(model.songs.prefix(6)))
                        .padding(.horizontal, Theme.Layout.contentInset - 10)
                }
            }
            if !model.artists.isEmpty {
                Shelf(title: "歌手", seeAll: { model.tab = .artists }) {
                    artistCards(model.artists.prefix(8))
                }
            }
            if !model.albums.isEmpty {
                Shelf(title: "专辑", seeAll: { model.tab = .albums }) {
                    albumCards(model.albums.prefix(8))
                }
            }
            if !model.playlists.isEmpty {
                Shelf(title: "歌单", seeAll: { model.tab = .playlists }) {
                    playlistCards(model.playlists.prefix(8))
                }
            }
            if currentEmpty, !model.isLoading {
                EmptyStateView(icon: "magnifyingglass", title: "没有找到相关结果")
                    .frame(minHeight: 300)
            }
        case .songs:
            TrackListView(tracks: model.songs)
                .padding(.horizontal, Theme.Layout.contentInset - 10)
        case .artists:
            CardGrid(minWidth: 140) {
                artistCards(model.artists)
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        case .albums:
            CardGrid {
                albumCards(model.albums)
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        case .playlists:
            CardGrid {
                playlistCards(model.playlists)
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        }
    }

    private func artistCards(_ items: some Collection<ArtistSummary>) -> some View {
        ForEach(Array(items)) { artist in
            NavigationLink {
                ArtistDetailView(artistID: artist.id)
            } label: {
                VStack(spacing: 10) {
                    CachedAsyncImage(url: artist.picUrl?.resizedImageURL(256))
                        .frame(width: 128, height: 128)
                        .clipShape(Circle())
                    Text(artist.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .frame(width: 140)
            }
            .buttonStyle(.plain)
        }
    }

    private func albumCards(_ items: some Collection<AlbumSummary>) -> some View {
        ForEach(Array(items)) { album in
            NavigationLink {
                AlbumDetailView(albumID: album.id)
            } label: {
                CoverCardBody(
                    coverURL: album.picUrl?.resizedImageURL(384),
                    title: album.name,
                    subtitle: album.artistName
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func playlistCards(_ items: some Collection<PlaylistSummary>) -> some View {
        ForEach(Array(items)) { playlist in
            NavigationLink {
                PlaylistDetailView(playlistID: playlist.id)
            } label: {
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
