import XCTest
@testable import BJJAnnotate

/// T14 — L-3 consolidation. Evaluator carry-forward from the T11–T13 review:
///
/// `ProjectListView` previously kept a legacy `@State private var lastError`
/// alert in parallel with the new VM-driven `bannerMessage`. That is two
/// sources of truth for the same concept (persistence/picker failure surface).
/// T14 collapses both into `BookmarkStore.lastError`, surfaced via
/// `ProjectListViewModel.bannerMessage`.
///
/// This test asserts the VM-level contract:
///   - `ProjectListViewModel.surfacePickerError(_:)` routes a
///     `BookmarkResolutionError` into `bookmarkStore.lastError` as a
///     `BookmarkStoreError.pickerFailed(description:)`.
///   - `bannerMessage` then renders a human description.
///   - The legacy `@State` alert path is gone from `ProjectListView`
///     (asserted by a separate grep gate test).
@MainActor
final class ProjectListPickerErrorRoutingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "test.picker.error.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func test_surfacePickerError_sets_pickerFailed_on_store_lastError() {
        let store = BookmarkStore(defaults: defaults)
        let vm = ProjectListViewModel(bookmarkStore: store)

        vm.surfacePickerError(BookmarkResolutionError.accessDenied)

        guard case .pickerFailed(let desc) = store.lastError else {
            return XCTFail("expected .pickerFailed, got \(String(describing: store.lastError))")
        }
        XCTAssertFalse(desc.isEmpty, "picker error description must not be empty")
    }

    func test_surfacePickerError_routes_into_bannerMessage() {
        let store = BookmarkStore(defaults: defaults)
        let vm = ProjectListViewModel(bookmarkStore: store)

        vm.surfacePickerError(BookmarkResolutionError.notFound)

        XCTAssertNotNil(vm.bannerMessage, "banner message must surface when picker error routes through store")
    }

    func test_dismissBanner_clears_pickerFailed_lastError() {
        let store = BookmarkStore(defaults: defaults)
        let vm = ProjectListViewModel(bookmarkStore: store)
        vm.surfacePickerError(BookmarkResolutionError.notADirectory)
        XCTAssertNotNil(store.lastError)

        vm.dismissBanner()

        XCTAssertNil(store.lastError, "dismissBanner clears even pickerFailed errors")
        XCTAssertNil(vm.bannerMessage)
    }

    func test_surfacePickerError_with_foundation_preserves_detail() {
        let store = BookmarkStore(defaults: defaults)
        let vm = ProjectListViewModel(bookmarkStore: store)

        vm.surfacePickerError(BookmarkResolutionError.foundation("kernel-23"))

        guard case .pickerFailed(let desc) = store.lastError else {
            return XCTFail("expected .pickerFailed")
        }
        XCTAssertTrue(desc.contains("kernel-23"),
                      "foundation detail must be preserved through the routing path")
    }
}

/// Grep gate that asserts `ProjectListView.swift` no longer carries a
/// legacy `@State private var lastError` (L-3 evaluator carry-forward).
final class ProjectListLegacyAlertRemovalTests: XCTestCase {

    func test_projectListView_has_no_legacy_lastError_state() throws {
        let url = try Self.locateProjectListView()
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(source.contains("@State private var lastError"),
                       "L-3 carry-forward: `@State private var lastError` must be removed from ProjectListView (route through BookmarkStore.lastError instead).")
        XCTAssertFalse(source.contains(".alert(\"Couldn't open folder\""),
                       "L-3 carry-forward: legacy picker-error alert must be removed from ProjectListView.")
    }

    private static func locateProjectListView() throws -> URL {
        // Repo root is the ancestor named `bjj-annotate-ios` of this test file.
        var url = URL(fileURLWithPath: #file)
        while url.path != "/" && url.lastPathComponent != "bjj-annotate-ios" {
            url.deleteLastPathComponent()
        }
        let probe = url
            .appendingPathComponent("BJJAnnotate")
            .appendingPathComponent("Features")
            .appendingPathComponent("ProjectList")
            .appendingPathComponent("ProjectListView.swift")
        guard FileManager.default.fileExists(atPath: probe.path) else {
            throw XCTSkip("ProjectListView.swift not found via #file walk; grep gate skipped.")
        }
        return probe
    }
}
