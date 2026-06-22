import XCTest
@testable import BJJAnnotate

/// AIP §1 + §6.2 — every test uses an isolated `UserDefaults` suite and real on-disk URLs.
/// NO `FileManager` mocks (evaluator gate). NO `UserDefaults.standard` (test isolation).
@MainActor
final class BookmarkStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: BookmarkStore!
    private var temp: TempDirectory!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "test.bookmarks.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        XCTAssertNotNil(defaults, "Could not allocate test UserDefaults suite")
        defaults.removePersistentDomain(forName: suiteName)
        store = BookmarkStore(defaults: defaults, storageKey: "bjj.annotate.bookmarks.v1")
        temp = try TempDirectory()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        temp = nil
        super.tearDown()
    }

    // MARK: - Save / load

    func test_saves_and_loads_bookmark_with_uuid_id() throws {
        let bookmark = try temp.url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let id = store.save(bookmark: bookmark)

        XCTAssertFalse(id.isEmpty, "save should return a non-empty id")
        XCTAssertNotNil(UUID(uuidString: id), "save should return a UUID string id")
        let all = store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, id)
        XCTAssertEqual(all.first?.bookmark, bookmark)
    }

    func test_save_same_bookmark_data_dedupes_and_bumps_lastOpenedAt() throws {
        let bookmark = try temp.url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let firstDate = Date(timeIntervalSince1970: 1_000)
        let secondDate = Date(timeIntervalSince1970: 2_000)

        let firstID = store.save(bookmark: bookmark, openedAt: firstDate)
        let secondID = store.save(bookmark: bookmark, openedAt: secondDate)

        XCTAssertEqual(firstID, secondID, "re-saving same bookmark data should preserve id")
        XCTAssertEqual(store.all().count, 1, "no duplicate row on re-save of same bytes")
        XCTAssertEqual(store.all().first?.lastOpenedAt, secondDate)
    }

    // MARK: - MRU (AC #5)

    func test_all_returns_MRU_order() throws {
        let bookmark1 = try temp.url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let sub = try temp.makeSubdirectory(named: "second")
        let bookmark2 = try sub.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let sub2 = try temp.makeSubdirectory(named: "third")
        let bookmark3 = try sub2.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)

        let id1 = store.save(bookmark: bookmark1, openedAt: Date(timeIntervalSince1970: 1_000))
        let id2 = store.save(bookmark: bookmark2, openedAt: Date(timeIntervalSince1970: 3_000))
        let id3 = store.save(bookmark: bookmark3, openedAt: Date(timeIntervalSince1970: 2_000))

        XCTAssertEqual(store.all().map(\.id), [id2, id3, id1])
    }

    // MARK: - Replace (AC #6 relocate)

    func test_replace_swaps_bookmark_data_preserving_id_and_MRU_position() throws {
        let original = try temp.url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let id = store.save(bookmark: original, openedAt: Date(timeIntervalSince1970: 5_000))

        let newSub = try temp.makeSubdirectory(named: "relocated")
        let newBookmark = try newSub.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)

        store.replace(id: id, bookmark: newBookmark, openedAt: Date(timeIntervalSince1970: 5_000))

        let all = store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, id, "id is preserved across re-pick")
        XCTAssertEqual(all.first?.bookmark, newBookmark, "bookmark data is swapped")
    }

    // MARK: - Touch / remove

    func test_touch_bumps_lastOpenedAt() throws {
        let bookmark = try temp.url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let id = store.save(bookmark: bookmark, openedAt: Date(timeIntervalSince1970: 1_000))

        let later = Date(timeIntervalSince1970: 9_000)
        store.touch(id: id, openedAt: later)

        XCTAssertEqual(store.all().first?.lastOpenedAt, later)
    }

    func test_remove_deletes_by_id() throws {
        let bookmark = try temp.url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let id = store.save(bookmark: bookmark)

        store.remove(id: id)

        XCTAssertEqual(store.all().count, 0)
    }

    // MARK: - Resolution (AC #6, PM Marker D, AC #9)

    func test_resolve_returns_url_with_current_lastPathComponent_after_rename() throws {
        let originalName = temp.url.lastPathComponent
        let bookmark = try temp.url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let id = store.save(bookmark: bookmark)

        let newName = "renamed-\(UUID().uuidString)"
        let renamedURL = try temp.rename(to: newName)
        // Replace temp's URL pointer so deinit cleans the new location.
        defer {
            try? FileManager.default.removeItem(at: renamedURL)
        }

        let resolved = try store.resolve(id: id)

        XCTAssertEqual(resolved.lastPathComponent, newName,
                       "resolved bookmark must reflect new folder name; was \(originalName), now \(newName)")
    }

    func test_resolve_missing_folder_throws_notFound() throws {
        let bookmark = try temp.url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let id = store.save(bookmark: bookmark)
        try FileManager.default.removeItem(at: temp.url)

        XCTAssertThrowsError(try store.resolve(id: id)) { error in
            guard case BookmarkResolutionError.notFound = error else {
                XCTFail("expected .notFound, got \(error)")
                return
            }
        }
    }

    func test_resolve_unknown_id_throws_unknownId() {
        XCTAssertThrowsError(try store.resolve(id: "not-a-real-id")) { error in
            guard case BookmarkResolutionError.unknownId = error else {
                XCTFail("expected .unknownId, got \(error)")
                return
            }
        }
    }
}
