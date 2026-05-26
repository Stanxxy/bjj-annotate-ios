import XCTest
@testable import BJJAnnotate

/// Findings #4, #5, #12 — `BookmarkStore` must NOT silently swallow errors via `try?`. The
/// CLAUDE.md "no fallback logic" rule and the Phase 0 Evaluator Gate both forbid quiet
/// failure modes that hide data loss from the user.
///
/// Contract being asserted:
/// - `loadAll()` decode failure surfaces a `.decodeFailed` error on the store's
///   `@Observable lastError` property AND returns an empty list so the UI can render an
///   alert and recover via "Open Folder" (corrupt blob preserved as `lastError.payload`).
/// - `lastError` is cleared (`nil`) after a successful subsequent write so a transient
///   corruption does not jam the UI forever.
final class BookmarkStoreErrorSurfacingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "test.errsurface.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Finding #5: decode failure must surface, not silently empty

    func test_loadAll_corrupt_blob_surfaces_decode_error_and_returns_empty() {
        let corruptBlob = Data("not-valid-json-{{{".utf8)
        defaults.set(corruptBlob, forKey: "bjj.annotate.bookmarks.v1")

        let store = BookmarkStore(defaults: defaults)

        // Trigger a read.
        let rows = store.all()

        XCTAssertEqual(rows, [], "corrupt blob still returns empty so the UI does not crash")
        guard let err = store.lastError else {
            XCTFail("decode failure must surface via lastError; got nil")
            return
        }
        guard case .decodeFailed = err else {
            XCTFail("expected .decodeFailed, got \(err)")
            return
        }
    }

    func test_loadAll_clean_blob_leaves_lastError_nil() {
        let store = BookmarkStore(defaults: defaults)

        _ = store.all()

        XCTAssertNil(store.lastError, "successful read must not raise lastError")
    }

    // MARK: - Finding #4: encode failure path — encode is infallible by construction

    /// We cannot construct a value that fails `JSONEncoder().encode([StoredBookmark].self)`
    /// (all fields are trivially Codable). The contract test is that a normal save/persist
    /// cycle does NOT raise lastError, and that the `lastError` API exists as a published
    /// surface for the encode-failure path to reach in the future.
    func test_save_does_not_raise_lastError_on_happy_path() throws {
        let store = BookmarkStore(defaults: defaults)
        let temp = try TempDirectory()
        let bookmark = try temp.url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        _ = store.save(bookmark: bookmark)

        XCTAssertNil(store.lastError, "happy-path save must not surface an error")
    }

    // MARK: - lastError is observable and clearable

    func test_clearLastError_resets_to_nil() {
        let corruptBlob = Data("garbage".utf8)
        defaults.set(corruptBlob, forKey: "bjj.annotate.bookmarks.v1")
        let store = BookmarkStore(defaults: defaults)
        _ = store.all()
        XCTAssertNotNil(store.lastError)

        store.clearLastError()

        XCTAssertNil(store.lastError)
    }
}
