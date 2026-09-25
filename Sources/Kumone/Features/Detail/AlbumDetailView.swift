import SwiftUI

struct AlbumDetailView: View {
    let albumID: Int
    /// Which catalog this album lives in. Defaulted so every existing call
    /// site keeps compiling and keeps meaning NetEase.
    var platform: TrackPlatform = .netease
    /// QQ addresses albums by a string `albummid`; the numeric id above can't
    /// carry it.
    var qqAlbumMid: String?

    @State private var album: AlbumDetail?
    @State private var tracks: [Track] = []
    @State private var otherAlbums: [AlbumSummary] = []
    @State private var isSubscribed = false
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showFullDescription = false

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(albumID: Int, platform: TrackPlatform = .netease, qqAlbumMid: String? = nil) {
        self.albumID = albumID
        self.platform = platform
        self.qqAlbumMid = qqAlbumMid
    }

    /// Identifies *this* album for `.task`, which for QQ is the mid — two QQ
    /// albums could otherwise share a numeric id of 0.
    private var loadIdentity: String {
        qqAlbumMid ?? "n\(albumID)"
    }

    /// The "place" this queue came from, for Recently Played.
    ///
    /// `nil` for QQ: reloading a place is a NetEase endpoint keyed by NetEase's
    /// own numbering, so a QQ id would rebuild the queue as some unrelated
    /// album. Omitting the context keeps a QQ queue out of that list rather
    /// than offering a reload that plays the wrong music.
    private var playContext: PlayContext? {
        guard platform == .netease, let album else { return nil }
        return .album(id: album.id, name: album.name)
    }

    private var isCompact: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone || horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: isCompact ? 16 : 20) {
                if let album {
                    if isCompact {
                        compactHeader(album)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                    } else {
                        regularHeader(album)
                            .padding(.horizontal, Theme.Layout.contentInset)
                            .padding(.top, 16)
                    }

                    TrackListView(
                        tracks: tracks,
                        source: .album(album.id),
                        context: playContext
                    )
                    .padding(.horizontal, isCompact ? 6 : Theme.Layout.contentInset - 10)

                    if !otherAlbums.isEmpty {
                        SectionHeader(title: "该歌手的其他专辑")
                            .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)
                            .padding(.top, 12)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                                ForEach(otherAlbums) { item in
                                    if let destination = albumDestination(item) {
                                        NavigationLink(value: destination) {
                                            CoverCardBody(
                                                coverURL: item.picUrl?.resizedImageURL(384),
                                                title: item.name,
                                                subtitle: Formatters.date(fromMS: item.publishTime)
                                            )
                                        }
                                        .buttonStyle(.interactiveCard)
                                    }
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
        .navigationTitle(album?.name ?? String(localized: "专辑"))
        #else
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: loadIdentity) {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            switch platform {
            case .netease:
                let response = try await NeteaseAPI.album(id: albumID)
                album = response.album
                tracks = response.songs
                isLoading = false
                if let dynamic = try? await NeteaseAPI.albumDynamic(id: albumID) {
                    isSubscribed = dynamic.isSub ?? false
                }
                if let artistID = response.album.artist?.id,
                   let albums = try? await NeteaseAPI.artistAlbums(id: artistID, limit: 12) {
                    otherAlbums = albums.hotAlbums.filter { $0.id != albumID }
                }
            case .qq:
                guard let qqAlbumMid else { throw QQMusicAPI.QQError.missingIdentifier }
                let response = try await QQMusicAPI.albumDetail(mid: qqAlbumMid)
                album = response.album
                tracks = response.songs
                isLoading = false
                // No "other albums by this artist" shelf for QQ: it is fed by
                // the artist-albums endpoint, and QQ's artist endpoints no
                // longer answer (see `QQMusicAPI.artistSongs`). An empty list
                // simply hides the section instead of showing a wrong one.
            }
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Compact Header

    private func compactHeader(_ album: AlbumDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                CachedAsyncImage(url: album.picUrl?.resizedImageURL(384))
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text(album.name)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(3)

                    if let artist = album.artist {
                        artistLink(artist) {
                            Text(artist.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.accent)
                                .lineLimit(1)
                        }
                    }

                    Text("\(tracks.count) 首 · \(Formatters.date(fromMS: album.publishTime))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if let description = album.description, !description.isEmpty {
                Button {
                    showFullDescription = true
                } label: {
                    HStack(spacing: 4) {
                        Text(description.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showFullDescription) {
                    NavigationStack {
                        ScrollView {
                            Text(description)
                                .font(.system(size: 14))
                                .padding(20)
                        }
                        .navigationTitle("专辑简介")
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                Button("完成") { showFullDescription = false }
                            }
                        }
                    }
                }
            }

            // Compact Action Bar
            HStack(spacing: 10) {
                Button {
                    player.play(tracks: tracks, source: .album(album.id),
                                context: playContext)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("播放全部 (\(tracks.count))")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Theme.accentGradient, in: Capsule())
                    .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
                }
                .buttonStyle(.pressable)

                // Subscribing an album is a NetEase-account relationship, and a
                // QQ album has no equivalent to offer while logged out.
                if platform == .netease && account.isLoggedIn {
                    Button {
                        toggleSubscribe()
                    } label: {
                        Image(systemName: isSubscribed ? "checkmark" : "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isSubscribed ? Theme.accent : .primary)
                            .frame(width: 38, height: 38)
                            .background(.primary.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
    }

    // MARK: - Regular Header

    private func regularHeader(_ album: AlbumDetail) -> some View {
        HStack(alignment: .bottom, spacing: 24) {
            CachedAsyncImage(url: album.picUrl?.resizedImageURL(512))
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)

            VStack(alignment: .leading, spacing: 8) {
                Text(album.subType?.isEmpty == false ? album.subType! : String(localized: "专辑"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(album.name)
                    .font(.title.weight(.bold))
                    .lineLimit(2)

                if let artist = album.artist {
                    artistLink(artist) {
                        Text(artist.name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.accent)
                    }
                }

                Text("\(tracks.count) 首 · \(totalDuration) · \(Formatters.date(fromMS: album.publishTime))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)

                if let description = album.description, !description.isEmpty {
                    Button {
                        showFullDescription = true
                    } label: {
                        Text(description.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showFullDescription, arrowEdge: .bottom) {
                        ScrollView {
                            Text(description)
                                .font(.system(size: 13))
                                .padding(16)
                                .frame(width: 380, alignment: .leading)
                        }
                        .frame(maxHeight: 400)
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 10) {
                    Button {
                        player.play(tracks: tracks, source: .album(album.id),
                                context: playContext)
                    } label: {
                        Label("播放", systemImage: "play.fill")
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
                            toggleSubscribe()
                        } label: {
                            Label(isSubscribed ? String(localized: "已收藏") : String(localized: "收藏"),
                                  systemImage: isSubscribed ? "checkmark" : "plus")
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
        .frame(height: 210)
    }

    private var totalDuration: String {
        let totalMS = tracks.reduce(into: 0) { $0 += $1.durationMS }
        return Formatters.longDuration(TimeInterval(totalMS) / 1000)
    }

    /// QQ artists are addressed by their string `singerMID`, NetEase ones by a
    /// numeric id, so the link target depends on which catalog is showing.
    /// `nil` means "nothing to push" — the row renders as plain text instead of
    /// opening a page that could not load.
    private func artistDestination(_ artist: ArtistSummary) -> Destination? {
        if platform == .qq {
            guard let mid = artist.mid else { return nil }
            return .qqArtist(mid: mid, name: artist.name)
        }
        return .artist(artist.id)
    }

    private func albumDestination(_ item: AlbumSummary) -> Destination? {
        if platform == .qq {
            guard let mid = item.mid else { return nil }
            return .qqAlbum(mid)
        }
        return .album(item.id)
    }

    @ViewBuilder
    private func artistLink<Label: View>(
        _ artist: ArtistSummary,
        @ViewBuilder label: () -> Label
    ) -> some View {
        if let destination = artistDestination(artist) {
            NavigationLink(value: destination, label: label)
                .buttonStyle(.plain)
        } else {
            label()
        }
    }

    private func toggleSubscribe() {
        Task {
            do {
                try await NeteaseAPI.subscribeAlbum(id: albumID, subscribe: !isSubscribed)
                isSubscribed.toggle()
                ToastCenter.shared.show(isSubscribed ? String(localized: "已收藏专辑") : String(localized: "已取消收藏"))
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private var loadingHeader: some View {
        HStack(alignment: .top, spacing: isCompact ? 14 : 24) {
            SkeletonView(cornerRadius: isCompact ? Theme.Radius.standard : Theme.Radius.large)
                .frame(width: isCompact ? 120 : 200, height: isCompact ? 120 : 200)

            VStack(alignment: .leading, spacing: 10) {
                SkeletonView(cornerRadius: 4).frame(width: 80, height: 14)
                SkeletonView(cornerRadius: 4).frame(maxWidth: isCompact ? 160 : 200, minHeight: 14, maxHeight: 14)
                SkeletonView(cornerRadius: 4).frame(width: 120, height: 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)
        .padding(.top, isCompact ? 12 : 16)
    }
}
