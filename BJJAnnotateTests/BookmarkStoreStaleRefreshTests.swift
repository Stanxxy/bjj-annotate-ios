import XCTest
@testable import BJJAnnotate

/// Finding #7 (AIP §7 R9) — `BookmarkStore.resolve(id:)` MUST re-mint and re-save the
/// bookmark when `URL(resolvingBookmarkData:bookmarkDataIsStale:)` reports a stale flag.
/// iOS doesn't make staleness easy to provoke from inside a unit test, so we inject a
/// `BookmarkResolver` test double via the protocol seam exposed by the store.
@MainActor
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

    // MARK: - RENAME topology (BUG A regression guard)

    /// iCloud folder RENAME: the resolver reports `isStale=true` and the URL it first resolves
    /// to has an ORIGINAL path that no longer exists on disk, BUT the folder is recoverable —
    /// re-minting + re-resolving yields the NEW (existing) path. Pre-fix, `resolve(id:)` ran the
    /// `fileExists` check against the stale ORIGINAL path *before* the re-mint, so it wrongly
    /// threw `.notFound`. Post-fix it must RECOVER: re-mint, re-persist, and surface the NEW name.
    func test_resolve_recovers_on_rename_stale_when_remint_yields_existing_path() throws {
        // A real, on-disk "new" location (the post-rename folder) that EXISTS.
        let newURL = try temp.makeSubdirectory(named: "renamed-folder")
        // A stale "original" path that does NOT exist on disk.
        let stalePath = temp.url.appendingPathComponent("old-name-\(UUID().uuidString)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stalePath.path),
                       "precondition: the stale original path must not exist")

        let originalBookmark = Data("original-stale-bookmark".utf8)
        let refreshedBookmark = Data("refreshed-bookmark-\(UUID().uuidString)".utf8)

        // First resolve (of the original bookmark) → stale + the gone original path. The store
        // re-mints a bookmark for that resolved URL; re-resolving the freshly-minted blob then
        // returns the existing NEW url (the rename recovery the production bug was missing).
        let resolver = SequencedBookmarkResolver(
            resolutions: [
                originalBookmark: .success((url: stalePath, isStale: true)),
                refreshedBookmark: .success((url: newURL, isStale: false)),
            ],
            mintedBytesForURL: [stalePath: refreshedBookmark]
        )

        let store = BookmarkStore(defaults: defaults, resolver: resolver)
        let id = store.save(bookmark: originalBookmark)

        // Act — must NOT throw.
        let resolvedURL = try store.resolve(id: id)

        // Recovered to the NEW, existing URL...
        XCTAssertEqual(resolvedURL, newURL, "rename must recover to the current (existing) URL")
        XCTAssertEqual(resolvedURL.lastPathComponent, "renamed-folder",
                       "display name must reflect the NEW folder name after rename")

        // ...and the refreshed bookmark was persisted (AC #9).
        let storedAfter = store.all().first(where: { $0.id == id })
        XCTAssertEqual(storedAfter?.bookmark, refreshedBookmark,
                       "rename recovery must re-persist the freshly minted bookmark")
    }

    // MARK: - TRASH topology (AC #6 guard — must STILL throw .notFound)

    /// Folder genuinely moved to Trash: resolver reports `isStale=true` but neither the original
    /// nor the re-resolved path exists. Re-mint cannot rescue it → `.notFound` so the row shows
    /// "Folder not found — tap to relocate" (AC #6). This guards against the rename fix
    /// over-recovering and masking a genuinely-gone folder.
    func test_resolve_throws_notFound_when_folder_trashed_even_if_stale() throws {
        let gonePath = temp.url.appendingPathComponent("trashed-\(UUID().uuidString)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gonePath.path),
                       "precondition: trashed path must not exist")

        let originalBookmark = Data("trashed-original-bookmark".utf8)
        let refreshedBookmark = Data("trashed-refreshed-\(UUID().uuidString)".utf8)
        // The re-mint succeeds, but re-resolving the refreshed blob STILL yields the gone path
        // (the folder is genuinely in Trash). The downstream existence gate must throw .notFound.
        let resolver = SequencedBookmarkResolver(
            resolutions: [
                originalBookmark: .success((url: gonePath, isStale: true)),
                refreshedBookmark: .success((url: gonePath, isStale: false)),
            ],
            mintedBytesForURL: [gonePath: refreshedBookmark]
        )

        let store = BookmarkStore(defaults: defaults, resolver: resolver)
        let id = store.save(bookmark: originalBookmark)

        XCTAssertThrowsError(try store.resolve(id: id)) { error in
            guard case BookmarkResolutionError.notFound = error else {
                XCTFail("expected .notFound for a trashed folder, got \(error)")
                return
            }
        }
    }

    /// AC #6 guard, harsher variant: on a genuinely-trashed folder the production re-mint can
    /// THROW (you can't mint a bookmark for a deleted path). The store must NOT crash on that
    /// (no `assertionFailure`) and must still end in `.notFound`. Pre-fix this path was never
    /// reached because the existence gate ran first; the BUG A reorder now reaches re-mint on
    /// trash, so this proves the reorder didn't introduce an AC #6 crash/regression.
    func test_resolve_throws_notFound_when_trashed_and_remint_fails() throws {
        let gonePath = temp.url.appendingPathComponent("trashed-mintfail-\(UUID().uuidString)", isDirectory: true)
        let originalBookmark = Data("trashed-mintfail-original".utf8)
        // resolve → stale + gone path; mint for that path is UNMAPPED → throws (models the OS
        // failing to mint a bookmark for a deleted folder).
        let resolver = SequencedBookmarkResolver(
            resolutions: [originalBookmark: .success((url: gonePath, isStale: true))],
            mintedBytesForURL: [:]
        )

        let store = BookmarkStore(defaults: defaults, resolver: resolver)
        let id = store.save(bookmark: originalBookmark)

        XCTAssertThrowsError(try store.resolve(id: id)) { error in
            guard case BookmarkResolutionError.notFound = error else {
                XCTFail("expected .notFound when trashed and re-mint fails, got \(error)")
                return
            }
        }
        // The refresh failure was surfaced for the UI, not swallowed.
        XCTAssertNotNil(store.lastError, "a failed re-mint must surface via lastError, not be swallowed")
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

/// Resolver double for the rename/trash topologies. Unlike `FakeBookmarkResolver`, it serves a
/// DIFFERENT resolution per exact bookmark-bytes key and a DIFFERENT minted blob per URL, so the
/// re-mint round can resolve to a path distinct from the first resolve. No catch-all fallback:
/// an unmapped key throws, which keeps the fake honest about exactly what the store asks for.
final class SequencedBookmarkResolver: BookmarkResolving {
    enum Outcome {
        case success((url: URL, isStale: Bool))
        case failure(Error)
    }

    private let resolutions: [Data: Outcome]
    private let mintedBytesForURL: [URL: Data]
    private(set) var resolveCalls: [Data] = []
    private(set) var mintCalls: [URL] = []

    init(resolutions: [Data: Outcome], mintedBytesForURL: [URL: Data]) {
        self.resolutions = resolutions
        self.mintedBytesForURL = mintedBytesForURL
    }

    struct UnmappedResolveKey: Error {}
    struct UnmappedMintURL: Error { let url: URL }

    func resolve(data: Data) throws -> (url: URL, isStale: Bool) {
        resolveCalls.append(data)
        guard let outcome = resolutions[data] else { throw UnmappedResolveKey() }
        switch outcome {
        case .success(let result): return result
        case .failure(let err): throw err
        }
    }

    func mintBookmark(for url: URL) throws -> Data {
        mintCalls.append(url)
        guard let bytes = mintedBytesForURL[url] else { throw UnmappedMintURL(url: url) }
        return bytes
    }
}
