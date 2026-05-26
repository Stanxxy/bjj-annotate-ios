import XCTest
@testable import BJJAnnotate

@MainActor
final class ProjectListViewModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: BookmarkStore!
    private var temp: TempDirectory!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "test.vm.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
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

    func test_refresh_emits_ok_row_with_resolved_display_name() throws {
        let bookmark = try temp.url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let id = store.save(bookmark: bookmark)
        let vm = ProjectListViewModel(bookmarkStore: store)

        vm.refresh()

        XCTAssertEqual(vm.rows.count, 1)
        XCTAssertEqual(vm.rows.first?.id, id)
        if case .ok(let name, _) = vm.rows.first?.state {
            XCTAssertEqual(name, temp.url.lastPathComponent,
                           "display name is the live folder name, never cached")
        } else {
            XCTFail("expected .ok state, got \(String(describing: vm.rows.first?.state))")
        }
    }

    func test_refresh_emits_missing_row_when_folder_deleted() throws {
        let bookmark = try temp.url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let id = store.save(bookmark: bookmark)
        try FileManager.default.removeItem(at: temp.url)

        let vm = ProjectListViewModel(bookmarkStore: store)
        vm.refresh()

        XCTAssertEqual(vm.rows.count, 1)
        XCTAssertEqual(vm.rows.first?.id, id)
        XCTAssertEqual(vm.rows.first?.state, .missing)
    }

    func test_refresh_reflects_folder_rename_in_files_app() throws {
        let bookmark = try temp.url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        _ = store.save(bookmark: bookmark)

        let newName = "renamed-\(UUID().uuidString)"
        let newURL = try temp.rename(to: newName)
        defer { try? FileManager.default.removeItem(at: newURL) }

        let vm = ProjectListViewModel(bookmarkStore: store)
        vm.refresh()

        if case .ok(let name, _) = vm.rows.first?.state {
            XCTAssertEqual(name, newName,
                           "ProjectListViewModel must re-derive display name after rename (PM Marker D)")
        } else {
            XCTFail("expected .ok after rename")
        }
    }
}
