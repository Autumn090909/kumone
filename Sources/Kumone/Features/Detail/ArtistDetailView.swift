import SwiftUI

struct ArtistDetailView: View {
    let artistID: Int
    /// Which catalog to read from. Defaulted so every existing call site keeps
    /// compiling and keeps meaning NetEase.
    var platform: TrackPlatform = .netease
    /// QQ addresses an artist by `singerMID`, which the numeric id above cannot
    /// express. The name rides along because it is the only search key QQ's
    /// surviving endpoints accept — see `QQMusicAPI.artistSongs`.
    var qqArtistMid: String?
    var qqArtistName: String?

    @State private var artist: ArtistSummary?
    @State private var hotSongs: [Track] = []
    @State private var albums: [AlbumSummary] = []
    @State private var epsAndSingles: [AlbumSummary] = []
    @State private var similar: [ArtistSummary] = []
    @State private var isFollowed = false
    @State private var isLoading = true
    @State private var errorMessage: String?

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isCompact: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone || horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    /// The "place" this queue came from, for Recently Played.
    ///
    /// `nil` for QQ: reloading a place is a NetEase endpoint keyed by NetEase's
    /// own numbering, so a QQ id would rebuild the queue with some unrelated
    /// artist's songs. Omitting the context keeps a QQ queue out of that list
    /// rather than offering a reload that plays the wrong music.
    private var playContext: PlayContext? {
        guard platform == .netease, let artist else { return nil }
        return .artist(id: artist.id, name: artist.name)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: isCompact ? 16 : 26) {
                if let artist {
                    if isCompact {
                        compactHeader(artist)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                    } else {
                        regularHeader(artist)
                            .padding(.horizontal, Theme.Layout.contentInset)
                            .padding(.top, 16)
                    }

                    if !hotSongs.isEmpty {
                        SectionHeader(title: "热门单曲")
                            .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)

                        TrackListView(
                            tracks: hotSongs,
                            style: .compact,
                            source: .artist(artistID),
                            context: playContext
                        )
                        .padding(.horizontal, isCompact ? 6 : Theme.Layout.contentInset - 10)
                    }

                    if !albums.isEmpty {
                        SectionHeader(title: "专辑")
                            .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                                ForEach(albums) { album in
                                    albumCard(album)
                                }
                                Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                            }
                        }
                    }

                    if !epsAndSingles.isEmpty {
                        SectionHeader(title: "EP 与单曲")
                            .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                                ForEach(epsAndSingles) { album in
                                    albumCard(album)
                                }
                                Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                            }
                        }
                    }

                    if !similar.isEmpty {
                        SectionHeader(title: "相似歌手")
                            .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                                ForEach(similar) { sim in
                                    NavigationLink(value: Destination.artist(sim.id)) {
                                        VStack(spacing: 8) {
                                            CachedAsyncImage(url: sim.picUrl?.resizedImageURL(256))
                                                .frame(width: isCompact ? 80 : 100, height: isCompact ? 80 : 100)
                                                .clipShape(Circle())
                                            Text(sim.name)
                                                .font(.system(size: 12, weight: .medium))
                                                .lineLimit(1)
                                        }
                                        .frame(width: isCompact ? 80 : 100)
                                    }
                                    .buttonStyle(.interactiveCard)
                                }
                                Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                            }
                        }
                    }
                } else if isLoading {
                    loadingHeader
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) {
                        Task { await load() }
                    }
                    .frame(minHeight: 400)
                }

                PlayerClearanceSpacer()
            }
        }
        #if os(macOS)
        .navigationTitle(artist?.name ?? String(localized: "歌手"))
        #else
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: artistID) {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        switch platform {
        case .netease: await loadNetease()
        case .qq: await loadQQ()
        }
    }

    private func loadNetease() async {
        do {
            let response = try await NeteaseAPI.artist(id: artistID)
            artist = response.artist
            hotSongs = response.hotSongs
            isFollowed = response.artist.followed
            isLoading = false

            if let result = try? await NeteaseAPI.artistAlbums(id: artistID, limit: 60) {
                albums = result.hotAlbums.filter { $0.size > 1 }
                epsAndSingles = result.hotAlbums.filter { $0.size <= 1 }
            }
            if account.isLoggedIn {
                similar = (try? await NeteaseAPI.similarArtists(id: artistID)) ?? []
            }
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    /// QQ keeps no working artist endpoint: the old `fcg_v8_singer_track_cp`
    /// answers HTTP 404, `fcg_v8_singer_album` answers `code 400`, and every
    /// `musicu` module name tried came back `code 500003` with no data. So the
    /// page is assembled from what does work — song search filtered to this
    /// artist's mid, album search filtered the same way, and a `smartbox`
    /// lookup for the portrait.
    ///
    /// That makes this page's song list "this artist's songs that came back for
    /// their name", **not** a complete discography. The header says so, because
    /// a user comparing it against QQ's own app would otherwise read the
    /// difference as a bug.
    private func loadQQ() async {
        guard let name = qqArtistName ?? artist?.name else {
            isLoading = false
            errorMessage = QQMusicAPI.QQError.missingIdentifier.localizedDescription
            return
        }
        let mid = qqArtistMid ?? artist?.mid

        async let lookupTask = try? QQMusicAPI.searchArtists(name, limit: 20)
        async let songsTask = try? QQMusicAPI.artistSongs(singerMid: mid ?? "", keyword: name)
        async let albumsTask = try? QQMusicAPI.searchAlbums(name, limit: 30)

        let lookup = (await lookupTask) ?? []
        // Prefer the entry whose mid matches; fall back to what the caller
        // passed in, so a suggestion endpoint that returns nothing still leaves
        // a renderable header instead of a blank page.
        artist = lookup.first { mid == nil || $0.mid == mid }
            ?? QQMusicAPI.artistSummary(mid: mid, name: name)

        hotSongs = (await songsTask) ?? []

        // Album search matches on name, so homonyms' albums come back too; the
        // artist name is what separates them.
        let found = (await albumsTask) ?? []
        let mine = found.filter { mid == nil || $0.artistName.contains(name) }
        // QQ's album search reports no track count, so "album vs EP/single"
        // cannot be decided here — everything goes in one strip rather than
        // being misfiled as singles.
        albums = mine
        epsAndSingles = []
        isLoading = false
    }

    // MARK: - Compact Header

    private func compactHeader(_ artist: ArtistSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                CachedAsyncImage(url: artist.picUrl?.resizedImageURL(384))
                    .frame(width: 100, height: 100)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)

                VStack(alignment: .leading, spacing: 5) {
                    Text(artist.name)
                        .font(.system(size: 18, weight: .bold))
                        .lineLimit(2)
                    if !artist.alias.isEmpty {
                        Text(artist.alias.joined(separator: " / "))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(statsLine(artist))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if platform == .qq {
                        Text("歌曲来自搜索结果，非该歌手的全部作品")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            // Compact Action Bar
            HStack(spacing: 10) {
                Button {
                    player.play(tracks: hotSongs, source: .artist(artist.id),
                                context: playContext)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("播放热门")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Theme.accentGradient, in: Capsule())
                    .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
                }
                .buttonStyle(.pressable)

                // Following an artist is a NetEase-account relationship; QQ has
                // no equivalent to offer while logged out.
                if platform == .netease && account.isLoggedIn {
                    Button {
                        toggleFollow()
                    } label: {
                        Image(systemName: isFollowed ? "checkmark" : "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isFollowed ? Theme.accent : .primary)
                            .frame(width: 38, height: 38)
                            .background(.primary.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
    }

    // MARK: - Regular Header

    private func regularHeader(_ artist: ArtistSummary) -> some View {
        HStack(alignment: .center, spacing: 28) {
            CachedAsyncImage(url: artist.picUrl?.resizedImageURL(512))
                .frame(width: 180, height: 180)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)

            VStack(alignment: .leading, spacing: 8) {
                Text("歌手")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(artist.name)
                    .font(.largeTitle.weight(.bold))
                if !artist.alias.isEmpty {
                    Text(artist.alias.joined(separator: " / "))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Text(statsLine(artist))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                if platform == .qq {
                    Text("歌曲来自搜索结果，非该歌手的全部作品")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 6)

                HStack(spacing: 10) {
                    Button {
                        player.play(tracks: hotSongs, source: .artist(artist.id),
                                context: playContext)
                    } label: {
                        Label("播放热门", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(Theme.accentGradient, in: Capsule())
                            .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
                    }
                    .buttonStyle(.pressable)

                    if platform == .netease && account.isLoggedIn {
                        Button {
                            toggleFollow()
                        } label: {
                            Label(isFollowed ? String(localized: "已关注") : String(localized: "关注"),
                                  systemImage: isFollowed ? "checkmark" : "plus")
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.primary.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func albumCard(_ album: AlbumSummary) -> some View {
        // No mid means nothing safe to open — falling back to the NetEase route
        // would look up a QQ id against the wrong catalog.
        if let destination = albumDestination(album) {
            NavigationLink(value: destination) {
                CoverCardBody(
                    coverURL: album.picUrl?.resizedImageURL(384),
                    title: album.name,
                    subtitle: album.publishYear
                )
            }
            .buttonStyle(.interactiveCard)
        } else {
            CoverCardBody(
                coverURL: album.picUrl?.resizedImageURL(384),
                title: album.name,
                subtitle: album.publishYear
            )
        }
    }

    /// QQ's lookup carries no song/album totals, so quoting the model's counts
    /// would print a confident "0 首歌曲 · 0 张专辑" next to a full track list.
    /// For QQ the numbers come from what actually loaded.
    private func statsLine(_ artist: ArtistSummary) -> String {
        if platform == .qq {
            return "\(hotSongs.count) 首歌曲 · \(albums.count + epsAndSingles.count) 张专辑"
        }
        return "\(artist.musicSize) 首歌曲 · \(artist.albumSize) 张专辑"
    }

    /// QQ artists are addressed by their string `singerMID`; NetEase ones by a
    /// numeric id. `nil` means the row has nowhere useful to go.
    private func artistDestination(_ artist: ArtistSummary) -> Destination? {
        if platform == .qq {
            guard let mid = artist.mid else { return nil }
            return .qqArtist(mid: mid, name: artist.name)
        }
        return .artist(artist.id)
    }

    private func albumDestination(_ album: AlbumSummary) -> Destination? {
        if platform == .qq {
            guard let mid = album.mid else { return nil }
            return .qqAlbum(mid)
        }
        return .album(album.id)
    }

    private func toggleFollow() {
        Task {
            do {
                try await NeteaseAPI.subscribeArtist(id: artistID, subscribe: !isFollowed)
                isFollowed.toggle()
                ToastCenter.shared.show(isFollowed ? String(localized: "已关注歌手") : String(localized: "已取消关注"))
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private var loadingHeader: some View {
        HStack(alignment: .center, spacing: isCompact ? 14 : 24) {
            SkeletonView(cornerRadius: isCompact ? 50 : 90)
                .clipShape(Circle())
                .frame(width: isCompact ? 100 : 180, height: isCompact ? 100 : 180)

            VStack(alignment: .leading, spacing: 10) {
                SkeletonView(cornerRadius: 4).frame(maxWidth: isCompact ? 150 : 180, minHeight: 14, maxHeight: 14)
                SkeletonView(cornerRadius: 4).frame(width: 100, height: 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)
        .padding(.top, isCompact ? 12 : 16)
    }
}
