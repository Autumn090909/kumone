import SwiftUI

/// One QQ ranking board (榜单) — the track list behind a 推荐页 board card.
///
/// The board id is all the API needs (`fcg_v8_toplist_cp.fcg?topid=`), and the
/// cover and name ride along through `Destination.qqToplist` so the header
/// needs no extra request. Playback goes through the same custom-source path
/// as every other QQ track; no NetEase-account context is attached, matching
/// the account guard (`Track.isAccountBound`).
struct QQToplistDetailView: View {
    @StateObject private var model: Model
    @EnvironmentObject private var player: PlayerService

    init(topID: Int, name: String, cover: String?) {
        _model = StateObject(wrappedValue: Model(topID: topID, name: name, cover: cover))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                switch model.state {
                case .idle, .loading:
                    VStack(spacing: 12) {
                        ForEach(0..<6, id: \.self) { _ in
                            SkeletonView(cornerRadius: Theme.Radius.standard)
                                .frame(height: 56)
                        }
                    }
                    .padding(.horizontal, Theme.Layout.contentInset)
                case .error(let message):
                    ErrorStateView(message: message) {
                        Task { await model.load() }
                    }
                    .frame(minHeight: 300)
                case .loaded:
                    if model.tracks.isEmpty {
                        EmptyStateView(icon: "music.note", title: "这个榜单暂时没有歌曲")
                            .frame(minHeight: 300)
                    } else {
                        TrackListView(tracks: model.tracks)
                            .padding(.horizontal, Theme.Layout.contentInset - 10)
                    }
                }
                PlayerClearanceSpacer()
            }
        }
        .navigationTitle(model.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await model.load() }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 14) {
            CachedAsyncImage(url: model.cover?.resizedImageURL(300))
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)

            VStack(alignment: .leading, spacing: 6) {
                Text("QQ音乐 · 榜单")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.name)
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Button {
                    player.play(tracks: model.tracks, source: .playlist(model.topID))
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.tracks.isEmpty)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Layout.contentInset)
        .padding(.top, 8)
    }

    @MainActor
    final class Model: ObservableObject {
        enum State { case idle, loading, loaded, error(String) }

        let topID: Int
        let name: String
        /// Raw URL string — `resizedImageURL` is a `String` extension.
        let cover: String?
        @Published var state: State = .idle
        @Published var tracks: [Track] = []

        init(topID: Int, name: String, cover: String?) {
            self.topID = topID
            self.name = name
            self.cover = cover
        }

        func load() async {
            state = .loading
            do {
                tracks = try await QQMusicAPI.toplistSongs(topID: topID, limit: 100)
                state = .loaded
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }
}
