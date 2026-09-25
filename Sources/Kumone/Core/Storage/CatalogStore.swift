import Foundation
import Combine

/// Which catalog the browse surfaces (推荐 / 搜索) are drawn from.
///
/// This is the state behind the app-wide platform switcher: the 推荐 page
/// swaps its whole content and the search page flips its catalog when it
/// changes, so it lives in one observable place rather than a `UserDefaults`
/// key each surface reads at init. Account-bound surfaces (我的 / 漫游) stay
/// NetEase-only — see `TrackPlatform.isAccountBound`.
final class CatalogStore: ObservableObject {
    static let shared = CatalogStore()

    private static let defaultsKey = "kumone.catalog.platform"
    /// The search page kept its own key before the switcher went app-wide.
    /// Migrate once so an existing preference survives the update.
    private static let legacyKey = "kumone.search.platform"

    @Published private(set) var platform: TrackPlatform

    private init() {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: Self.defaultsKey)
            .flatMap(TrackPlatform.init(rawValue:)) {
            platform = stored
        } else if let legacy = defaults.string(forKey: Self.legacyKey)
            .flatMap(TrackPlatform.init(rawValue:)) {
            platform = legacy
            defaults.set(legacy.rawValue, forKey: Self.defaultsKey)
        } else {
            platform = .netease
        }
    }

    func setPlatform(_ newPlatform: TrackPlatform) {
        guard newPlatform != platform else { return }
        platform = newPlatform
        UserDefaults.standard.set(newPlatform.rawValue, forKey: Self.defaultsKey)
    }
}
