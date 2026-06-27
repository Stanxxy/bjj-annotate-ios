import SwiftUI
import UIKit

/// Application entry point.
///
/// AIP §6.3: when launched with `--uitest-reset` (XCUITest flag), allocate a unique
/// `UserDefaults` suite so UI tests start from a clean empty state. Real launches use
/// the standard suite.
///
/// Finding #1 / #2: additional UI-test seed flags pre-populate the store with synthesized
/// bookmarks so XCUITests can land directly on the populated state, empty-folder grid, or
/// bookmark-error row without driving the real `UIDocumentPickerViewController`.
@main
struct BJJAnnotateApp: App {
    @StateObject private var bookmarkStore: BookmarkStore
    @State private var thumbnailCache: ThumbnailCache

    init() {
        let args = CommandLine.arguments

        // Capture the device scale once on the main actor so ThumbnailCache renders at the
        // device's native @2x / @3x density (Minor #10). Falls back to 2.0 only if the
        // screen scale is somehow unavailable (defensive — should never happen on iOS).
        let deviceScale = max(UIScreen.main.scale, 1.0)

        let store: BookmarkStore
        if args.contains("--uitest-reset") {
            let suiteName = "uitest.bookmarks.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName) ?? .standard
            defaults.removePersistentDomain(forName: suiteName)
            store = BookmarkStore(defaults: defaults)
        } else {
            store = BookmarkStore()
        }

        Self.applyUITestSeeds(args: args, into: store)

        _bookmarkStore = StateObject(wrappedValue: store)
        _thumbnailCache = State(initialValue: ThumbnailCache(scale: deviceScale))
    }

    /// Applies any `--uitest-seed-*` flags to the freshly-allocated store. Each flag is a
    /// single, additive seed; tests typically pair `--uitest-reset` with one seed flag so
    /// the store starts with a known, minimal state.
    ///
    /// Findings #1 / #2: these seeds replace the need for the XCUITest to drive the real
    /// `UIDocumentPickerViewController`, which is impractical in CI.
    private static func applyUITestSeeds(args: [String], into store: BookmarkStore) {
        if args.contains("--uitest-seed-empty-folder") {
            seedEmptyFolderProject(into: store)
        }
        if args.contains("--uitest-seed-missing-bookmark") {
            seedMissingBookmarkProject(into: store)
        }
        if args.contains("--uitest-seed-annotator-ready") {
            seedAnnotatorReadyProject(into: store)
        }
    }

    /// T24 golden-path seed: creates a directory with one synthesized JPEG
    /// and saves a bookmark. The XCUITest taps the row → grid → thumbnail →
    /// annotator → draws a box → backgrounds the app → relaunches → reopens
    /// → asserts the box came back from disk.
    private static func seedAnnotatorReadyProject(into store: BookmarkStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uitest-annotator-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Synthesize a 100x100 white JPEG so the canvas has something to render.
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100))
            let img = renderer.image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            }
            if let data = img.jpegData(compressionQuality: 0.8) {
                try data.write(to: dir.appendingPathComponent("frame_0001.jpg"))
            }
            let bookmark = try dir.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            _ = store.save(bookmark: bookmark)
        } catch {
            // Silent in test seed paths.
        }
    }

    /// Creates a fresh, empty temp directory in the simulator's tmp area and saves a
    /// security-scoped bookmark to it. The XCUITest can then tap the resulting row to land
    /// on the empty-grid state and assert `LockedCopy.emptyProjectGrid` is rendered.
    private static func seedEmptyFolderProject(into store: BookmarkStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uitest-empty-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let bookmark = try dir.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            _ = store.save(bookmark: bookmark)
        } catch {
            // UI-test seeding failure is silent because the XCUITest assertions will fail
            // loudly on the resulting empty list. We deliberately do NOT use the production
            // os.Logger here (this is a test-only branch the user never reaches).
        }
    }

    /// Saves a bookmark to a directory, then deletes the directory so the bookmark
    /// resolves to `.notFound` on the next render — driving the bookmark-error row state.
    private static func seedMissingBookmarkProject(into store: BookmarkStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uitest-missing-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let bookmark = try dir.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            _ = store.save(bookmark: bookmark)
            try FileManager.default.removeItem(at: dir)
        } catch {
            // See seedEmptyFolderProject — silent by design in the test seed path.
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(bookmarkStore: bookmarkStore, thumbnailCache: thumbnailCache)
        }
    }
}
