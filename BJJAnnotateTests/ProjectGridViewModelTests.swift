import XCTest
@testable import BJJAnnotate

/// Finding #6 — `folderDisplayName` must NOT re-resolve the bookmark on every render via
/// a `try?`. It should be resolved once during `load()`, stored on the VM, and read as a
/// plain property. Resolution errors surface via the existing `.error(...)` state.
@MainActor
final class ProjectGridViewModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: BookmarkStore!
    private var temp: TempDirectory!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "test.gridvm.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = BookmarkStore(defaults: defaults)
        temp = try TempDirectory()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        temp = nil
        super.tearDown()
    }

    func test_displayName_defaults_to_project_before_load() {
        let vm = ProjectGridViewModel(bookmarkStore: store, bookmarkID: "unknown-id")
        XCTAssertEqual(vm.displayName, "Project")
    }

    func test_load_sets_displayName_to_folder_lastPathComponent() async throws {
        let bookmark = try temp.url.bookmarkData(
            options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil
        )
        let id = store.save(bookmark: bookmark)
        let vm = ProjectGridViewModel(bookmarkStore: store, bookmarkID: id)

        await vm.load()

        XCTAssertEqual(vm.displayName, temp.url.lastPathComponent,
                       "displayName must reflect the folder name after a successful load")
    }

    func test_load_with_missing_folder_surfaces_error_state() async throws {
        let bookmark = try temp.url.bookmarkData(
            options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil
        )
        let id = store.save(bookmark: bookmark)
        try FileManager.default.removeItem(at: temp.url)

        let vm = ProjectGridViewModel(bookmarkStore: store, bookmarkID: id)
        await vm.load()

        guard case .error = vm.state else {
            XCTFail("expected .error after folder deletion, got \(vm.state)")
            return
        }
    }
}
