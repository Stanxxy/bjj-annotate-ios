import SwiftUI

/// Application entry point.
///
/// AIP §6.3: when launched with `--uitest-reset` (XCUITest flag), allocate a unique
/// `UserDefaults` suite so UI tests start from a clean empty state. Real launches use
/// the standard suite.
@main
struct BJJAnnotateApp: App {
    @State private var bookmarkStore: BookmarkStore
    @State private var thumbnailCache: ThumbnailCache = ThumbnailCache()

    init() {
        let args = CommandLine.arguments
        if args.contains("--uitest-reset") {
            let suiteName = "uitest.bookmarks.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName) ?? .standard
            defaults.removePersistentDomain(forName: suiteName)
            _bookmarkStore = State(initialValue: BookmarkStore(defaults: defaults))
        } else {
            _bookmarkStore = State(initialValue: BookmarkStore())
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(bookmarkStore: bookmarkStore, thumbnailCache: thumbnailCache)
        }
    }
}
