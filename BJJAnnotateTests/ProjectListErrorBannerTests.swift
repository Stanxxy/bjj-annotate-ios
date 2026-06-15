import XCTest
@testable import BJJAnnotate

/// T12 — `lastError` banner wiring on `ProjectListView` (Phase 0 deferral cleanup).
///
/// Phase 0 surfaced `BookmarkStore.lastError` as the persistence-fault publish
/// point (Findings #4 / #5). Phase 1 wires the consumer: the project list view
/// renders a non-blocking banner when `bookmarkStore.lastError != nil` and
/// invokes `clearLastError()` when the user dismisses.
///
/// View testing is gated by xcodebuild; this file asserts the view-model-level
/// contract — that `ProjectListViewModel` exposes a renderable banner message
/// derived from the underlying `BookmarkStoreError` AND a dismiss action that
/// clears the store. The XCUI test that lives alongside T13 covers visual
/// rendering.
@MainActor
final class ProjectListErrorBannerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "test.banner.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func test_bannerMessage_is_nil_when_no_lastError() {
        let store = BookmarkStore(defaults: defaults)
        let vm = ProjectListViewModel(bookmarkStore: store)
        XCTAssertNil(vm.bannerMessage,
                     "Happy path: no banner when store.lastError is nil")
    }

    func test_bannerMessage_is_decode_description_when_decode_failure_surfaces() {
        // Seed a corrupt blob; loadAll publishes .decodeFailed.
        defaults.set(Data("garbage".utf8), forKey: "bjj.annotate.bookmarks.v1")
        let store = BookmarkStore(defaults: defaults)
        let vm = ProjectListViewModel(bookmarkStore: store)
        _ = store.all() // triggers decodeFailed publish

        XCTAssertNotNil(vm.bannerMessage, "Banner message must surface for decode failure")
        // Should not echo any locked PM copy; just a human description (no em-dashes asserted).
    }

    func test_dismissBanner_clears_store_lastError() {
        defaults.set(Data("garbage".utf8), forKey: "bjj.annotate.bookmarks.v1")
        let store = BookmarkStore(defaults: defaults)
        let vm = ProjectListViewModel(bookmarkStore: store)
        _ = store.all()
        XCTAssertNotNil(store.lastError)

        vm.dismissBanner()

        XCTAssertNil(store.lastError, "dismissBanner must call clearLastError")
        XCTAssertNil(vm.bannerMessage, "bannerMessage follows store.lastError")
    }
}
