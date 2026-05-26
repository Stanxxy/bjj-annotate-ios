import XCTest
@testable import BJJAnnotate

/// Finding #7 (AIP §7 R9) — `BookmarkStore.resolve(id:)` MUST re-mint and re-save the
/// bookmark when `URL(resolvingBookmarkData:bookmarkDataIsStale:)` reports a stale flag.
/// iOS doesn't make staleness easy to provoke from inside a unit test, so we inject a
/// `BookmarkResolver` test double via the protocol seam exposed by the store.
final class BookmarkStoreStaleRefreshTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var temp: TempDirectory!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "test.stale.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        temp = try TempDirectory()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        temp = nil
        super.tearDown()
    }

    func test_resolve_refreshes_bookmark_when_resolver_reports_stale() throws {
        // Arrange: produce an "original" bookmark blob and save it through the store.
        let originalBookmark = try temp.url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        // Stub a resolver that always reports stale=true and resolves to the real URL.
        // The "refreshed" bookmark data the stub mints is the marker we assert was written
        // back into the store.
        let refreshedBytes = Data("refreshed-bookmark-bytes-\(UUID().uuidString)".utf8)
        let resolver = FakeBookmarkResolver(
            resolveResult: .success((url: temp.url, isStale: true)),
            mintedRefreshedBytes: refreshedBytes
        )

        let store = BookmarkStore(defaults: defaults, resolver: resolver)
        let id = store.save(bookmark: originalBookmark)

        // Act
        let resolvedURL = try store.resolve(id: id)

        // Assert: returned URL matches the resolver's URL.
        XCTAssertEqual(resolvedURL, temp.url)

        // Assert: stored bookmark has been replaced with the refreshed bytes.
        let storedAfter = store.all().first(where: { $0.id == id })
        XCTAssertEqual(
            storedAfter?.bookmark,
            refreshedBytes,
            "stale resolution must overwrite the stored bookmark with the freshly-minted bytes (AC #9)"
        )
    }

    func test_resolve_does_not_overwrite_when_resolver_reports_fresh() throws {
        let originalBookmark = try temp.url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let refreshedBytes = Data("should-not-be-written".utf8)
        let resolver = FakeBookmarkResolver(
            resolveResult: .success((url: temp.url, isStale: false)),
            mintedRefreshedBytes: refreshedBytes
        )

        let store = BookmarkStore(defaults: defaults, resolver: resolver)
        let id = store.save(bookmark: originalBookmark)

        _ = try store.resolve(id: id)

        let storedAfter = store.all().first(where: { $0.id == id })
        XCTAssertEqual(
            storedAfter?.bookmark,
            originalBookmark,
            "non-stale resolution must NOT mutate the stored bookmark"
        )
    }
}

// MARK: - Test double

/// In-test resolver that returns canned outcomes. The store calls `resolve(data:)` and
/// `mintBookmark(for:)`; the fake records the inputs and serves the pre-configured outputs.
final class FakeBookmarkResolver: BookmarkResolving {
    enum Outcome {
        case success((url: URL, isStale: Bool))
        case failure(Error)
    }

    private let resolveResult: Outcome
    private let mintedRefreshedBytes: Data
    private(set) var mintCallCount = 0

    init(resolveResult: Outcome, mintedRefreshedBytes: Data) {
        self.resolveResult = resolveResult
        self.mintedRefreshedBytes = mintedRefreshedBytes
    }

    func resolve(data: Data) throws -> (url: URL, isStale: Bool) {
        switch resolveResult {
        case .success(let outcome): return outcome
        case .failure(let err): throw err
        }
    }

    func mintBookmark(for url: URL) throws -> Data {
        mintCallCount += 1
        return mintedRefreshedBytes
    }
}
