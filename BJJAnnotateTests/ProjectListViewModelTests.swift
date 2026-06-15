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

    func test_refresh_emits_ok_row_with_resolved_display_name() async throws {
        let bookmark = try temp.url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let id = store.save(bookmark: bookmark)
        let vm = ProjectListViewModel(bookmarkStore: store)

        await vm.refresh()

        XCTAssertEqual(vm.rows.count, 1)
        XCTAssertEqual(vm.rows.first?.id, id)
        if case .ok(let name, _) = vm.rows.first?.state {
            XCTAssertEqual(name, temp.url.lastPathComponent,
                           "display name is the live folder name, never cached")
        } else {
            XCTFail("expected .ok state, got \(String(describing: vm.rows.first?.state))")
        }
    }

    func test_refresh_emits_missing_row_when_folder_deleted() async throws {
        let bookmark = try temp.url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let id = store.save(bookmark: bookmark)
        try FileManager.default.removeItem(at: temp.url)

        let vm = ProjectListViewModel(bookmarkStore: store)
        await vm.refresh()

        XCTAssertEqual(vm.rows.count, 1)
        XCTAssertEqual(vm.rows.first?.id, id)
        XCTAssertEqual(vm.rows.first?.state, .missing)
    }

    // BUG B: refresh() must perform its per-row bookmark resolution OFF the main thread so
    // iCloud-coordinated I/O (URL(resolvingBookmarkData:) + fileExists) no longer stalls the UI
    // ~2s. We inject a resolver that records the thread it ran on and assert it was NOT main.
    func test_refresh_resolves_off_the_main_thread() async throws {
        let recorder = ThreadRecordingResolver(url: temp.url)
        let recordingStore = BookmarkStore(defaults: defaults, resolver: recorder)
        let bookmark = try temp.url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let id = recordingStore.save(bookmark: bookmark)

        let vm = ProjectListViewModel(bookmarkStore: recordingStore)
        await vm.refresh()

        XCTAssertGreaterThan(recorder.resolveCount, 0, "resolver must have been exercised")
        XCTAssertFalse(recorder.ranOnMainThread,
                       "refresh() must resolve bookmarks off the main thread (BUG B: ~2s UI stall)")
        // State mutation still lands correctly on the main actor.
        XCTAssertEqual(vm.rows.count, 1)
        XCTAssertEqual(vm.rows.first?.id, id)
    }

    // Ordering must remain deterministic (MRU) even though resolution is concurrent/off-main.
    func test_refresh_preserves_MRU_ordering_after_offmain_resolution() async throws {
        let b1 = try temp.url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let sub2 = try temp.makeSubdirectory(named: "second")
        let b2 = try sub2.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let sub3 = try temp.makeSubdirectory(named: "third")
        let b3 = try sub3.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)

        let id1 = store.save(bookmark: b1, openedAt: Date(timeIntervalSince1970: 1_000))
        let id2 = store.save(bookmark: b2, openedAt: Date(timeIntervalSince1970: 3_000))
        let id3 = store.save(bookmark: b3, openedAt: Date(timeIntervalSince1970: 2_000))

        let vm = ProjectListViewModel(bookmarkStore: store)
        await vm.refresh()

        XCTAssertEqual(vm.rows.map(\.id), [id2, id3, id1],
                       "row order must stay MRU-stable regardless of concurrent resolution")
    }

    // Finding #7 (data-race surface): `refresh()` offloads resolution off the main actor while
    // `touchOpened()` mutates the SAME shared `BookmarkStore` on the main actor. Before the
    // Finding #3 fix, the detached task called `store.resolve(id:)` which wrote UserDefaults +
    // `lastError` off-main — a torn-state / crash hazard when interleaved with `touch()`.
    //
    // This is a REAL concurrency test: it fires `refresh()` and `touchOpened()` in OVERLAPPING
    // tasks via `async let`, and uses a deliberately slow resolver so the off-main resolution is
    // still in flight while the main-actor `touch` mutates the store. We run many overlapping
    // rounds and assert the store never crashes, never tears its row set, and converges to a
    // deterministic outcome (the touched row's MRU timestamp advanced; row count unchanged).
    func test_concurrent_refresh_and_touchOpened_no_crash_no_torn_state() async throws {
        let b1 = try temp.url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let sub2 = try temp.makeSubdirectory(named: "second")
        let b2 = try sub2.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)

        // Slow resolver: each off-main resolve sleeps briefly so it is GUARANTEED to still be
        // running when the concurrent main-actor `touch` mutates the store. Resolves both
        // bookmarks to existing dirs so both rows land in `.ok`.
        let slowResolver = SlowResolver(urlsByBytes: [b1: temp.url, b2: sub2])
        let racingStore = BookmarkStore(defaults: defaults, resolver: slowResolver)
        let id1 = racingStore.save(bookmark: b1, openedAt: Date(timeIntervalSince1970: 1_000))
        let id2 = racingStore.save(bookmark: b2, openedAt: Date(timeIntervalSince1970: 2_000))

        let vm = ProjectListViewModel(bookmarkStore: racingStore)

        // Fire MANY overlapping rounds of refresh() || touchOpened() against the shared store.
        for _ in 0..<25 {
            async let refreshTask: Void = vm.refresh()
            async let touchTask: Void = vm.touchOpened(rowID: id1)
            _ = await (refreshTask, touchTask)
        }

        // No crash reaching here. Final state must be consistent (deterministic outcome):
        // both rows still present, both .ok, MRU order driven by lastOpenedAt.
        await vm.refresh()
        XCTAssertEqual(vm.rows.count, 2, "row set must not tear under concurrent access")
        XCTAssertEqual(Set(vm.rows.map(\.id)), [id1, id2])
        for row in vm.rows {
            guard case .ok = row.state else {
                return XCTFail("expected all rows .ok after concurrent access, got \(row.state) for \(row.id)")
            }
        }

        // id1 was repeatedly touched → its lastOpenedAt advanced past id2's original timestamp,
        // so it must now sort FIRST (MRU). This proves the touch writes were applied coherently
        // (not lost / not torn) despite the overlap.
        let stored = racingStore.all()
        XCTAssertEqual(stored.first?.id, id1, "touched row must be MRU-first; touch writes were applied coherently")
        let touched = stored.first(where: { $0.id == id1 })
        XCTAssertNotNil(touched)
        XCTAssertGreaterThan(touched!.lastOpenedAt, Date(timeIntervalSince1970: 2_000),
                             "touchOpened must have advanced the MRU timestamp past the other row's")
        XCTAssertEqual(vm.rows.first?.id, id1, "VM rows must reflect the MRU-first touched row")
    }

    func test_refresh_reflects_folder_rename_in_files_app() async throws {
        let bookmark = try temp.url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        _ = store.save(bookmark: bookmark)

        let newName = "renamed-\(UUID().uuidString)"
        let newURL = try temp.rename(to: newName)
        defer { try? FileManager.default.removeItem(at: newURL) }

        let vm = ProjectListViewModel(bookmarkStore: store)
        await vm.refresh()

        if case .ok(let name, _) = vm.rows.first?.state {
            XCTAssertEqual(name, newName,
                           "ProjectListViewModel must re-derive display name after rename (PM Marker D)")
        } else {
            XCTFail("expected .ok after rename")
        }
    }
}

// MARK: - Test double

/// Resolver that records whether `resolve(data:)` ran on the main thread. Resolves every
/// bookmark to a single canned (existing) URL so the row lands in `.ok`. Used to prove BUG B's
/// off-main-thread offload without a device.
final class ThreadRecordingResolver: BookmarkResolving, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private(set) var ranOnMainThread = false
    private(set) var resolveCount = 0

    init(url: URL) {
        self.url = url
    }

    func resolve(data: Data) throws -> (url: URL, isStale: Bool) {
        lock.lock()
        resolveCount += 1
        if Thread.isMainThread { ranOnMainThread = true }
        lock.unlock()
        return (url, false)
    }

    func mintBookmark(for url: URL) throws -> Data {
        Data("unused".utf8)
    }
}

/// Resolver that introduces a real (off-main) delay inside `resolve(data:)` so the concurrency
/// test's detached resolution is GUARANTEED to still be in flight while the concurrent
/// main-actor `touchOpened()` mutates the shared store. Maps each bookmark-bytes key to a canned
/// existing URL. `@unchecked Sendable` because it holds only immutable state behind a lock.
final class SlowResolver: BookmarkResolving, @unchecked Sendable {
    private let urlsByBytes: [Data: URL]
    private let lock = NSLock()
    private(set) var resolveCount = 0

    init(urlsByBytes: [Data: URL]) {
        self.urlsByBytes = urlsByBytes
    }

    struct UnmappedBytes: Error {}

    func resolve(data: Data) throws -> (url: URL, isStale: Bool) {
        lock.lock()
        resolveCount += 1
        lock.unlock()
        // Real delay on whatever (background) thread the detached task scheduled us on, so the
        // resolution genuinely overlaps the main-actor touch().
        Thread.sleep(forTimeInterval: 0.002)
        guard let url = urlsByBytes[data] else { throw UnmappedBytes() }
        return (url, false)
    }

    func mintBookmark(for url: URL) throws -> Data {
        Data("unused".utf8)
    }
}
