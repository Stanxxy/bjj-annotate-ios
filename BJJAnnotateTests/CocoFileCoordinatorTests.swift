import XCTest
@testable import BJJAnnotate

/// Phase 1 CocoFileCoordinator I/O tests.
///
/// Coverage:
///   AC #23 — 100 rapid mutations collapse to 1 disk write
///   AC #24 — debounce via Task cancellation (grep test in separate file)
///   AC #26 — atomic write
///   AC #27 — willResignActive flushes synchronously
///   AC #29 — no `try?` in production CocoFileCoordinator (grep test below)
///   AC #30 — iCloud materialization gates read/write
///   AC #38 — willResignActive within 500ms of mutation flushes synchronously
@MainActor
final class CocoFileCoordinatorTests: XCTestCase {

    private var temp: TempDirectory!
    private var url: URL!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
        url = temp.url.appendingPathComponent("annotations.json")
    }

    override func tearDown() async throws {
        temp = nil
        url = nil
        try await super.tearDown()
    }

    private func makeCoordinator(
        ubiquity: UbiquityResolver = NeverUbiquitousResolver(),
        ubiquityTimeout: TimeInterval = 0.5
    ) -> CocoFileCoordinator {
        return CocoFileCoordinator(url: url, ubiquity: ubiquity, ubiquityTimeout: ubiquityTimeout)
    }

    private func makeDoc(stickyCategoryId: Int = 1) -> CocoDocument {
        let meta = BjjAnnotateMeta(
            schema_version: 1,
            athletes: [],
            image_states: [],
            settings: MetaSettings(sticky_category_id: stickyCategoryId)
        )
        return CocoDocument(
            info: nil,
            images: [CocoImage(id: 1, file_name: "f.jpg", width: 1, height: 1)],
            categories: [],
            annotations: [],
            bjj_annotate_meta: meta
        )
    }

    // MARK: - Read

    func test_read_returns_decoded_coco_from_existing_file() async throws {
        // Seed disk first.
        let coord = makeCoordinator()
        let doc = makeDoc(stickyCategoryId: 2)
        await coord.scheduleWrite(doc)
        await coord.flushNow()

        // Re-read with fresh coord.
        let coord2 = makeCoordinator()
        let decoded = try await coord2.readDocument()
        XCTAssertEqual(decoded.bjj_annotate_meta?.settings.sticky_category_id, 2)
    }

    func test_read_propagates_decode_error_via_typed_throw() async throws {
        try Data("not json".utf8).write(to: url)
        let coord = makeCoordinator()
        do {
            _ = try await coord.readDocument()
            XCTFail("Expected decode error")
        } catch CocoFileCoordinatorError.decodeFailed {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Atomic write (AC #26)

    func test_atomic_write_failure_leaves_prior_valid_annotations_json_intact() async throws {
        // Seed disk with a valid document.
        let coord = makeCoordinator()
        let original = makeDoc(stickyCategoryId: 2)
        await coord.scheduleWrite(original)
        await coord.flushNow()
        let originalBytes = try Data(contentsOf: url)

        // Now make the directory read-only so a fresh write to a temp-then-rename fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: temp.url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.url.path)
        }

        var modified = original
        modified.bjj_annotate_meta?.settings.sticky_category_id = 99
        await coord.scheduleWrite(modified)
        await coord.flushNow()

        // The original file is untouched (write to readonly tree should have failed).
        let afterBytes = try? Data(contentsOf: url)
        XCTAssertEqual(afterBytes, originalBytes,
                       "Atomic write must not corrupt the original on failure (AC #26)")
    }

    // MARK: - Debounce (AC #23)

    func test_100_mutations_within_100ms_collapse_to_one_file_write() async throws {
        // Use a longer debounce so the test rapidly enqueues without the timer firing.
        let coord = CocoFileCoordinator(url: url, ubiquity: NeverUbiquitousResolver(), debounceNanos: 500_000_000)
        for i in 0..<100 {
            var doc = makeDoc()
            doc.bjj_annotate_meta?.settings.sticky_category_id = (i % 3) + 1
            await coord.scheduleWrite(doc)
        }
        // Wait > 500ms for the debounce to fire.
        try await Task.sleep(nanoseconds: 700_000_000)

        let writeCount = await coord.diskWriteCount
        XCTAssertEqual(writeCount, 1, "100 mutations within debounce window must collapse to 1 write")
    }

    // MARK: - willResignActive synchronous flush (AC #27, AC #38)

    func test_willResignActive_flushes_pending_debounce_synchronously() async throws {
        let coord = CocoFileCoordinator(url: url, ubiquity: NeverUbiquitousResolver(), debounceNanos: 5_000_000_000)
        // Enqueue but don't await debounce.
        await coord.scheduleWrite(makeDoc(stickyCategoryId: 7))

        // Flush synchronously.
        await coord.flushNow()

        // File now exists on disk.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "flushNow must write the pending payload to disk synchronously")
        let bytes = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(CocoDocument.self, from: bytes)
        XCTAssertEqual(decoded.bjj_annotate_meta?.settings.sticky_category_id, 7)
    }

    func test_willResignActive_within_500ms_of_mutation_flushes_synchronously() async throws {
        let coord = CocoFileCoordinator(url: url, ubiquity: NeverUbiquitousResolver(), debounceNanos: 500_000_000)
        await coord.scheduleWrite(makeDoc(stickyCategoryId: 5))
        // Simulate backgrounding immediately, before debounce fires.
        await coord.flushNow()
        let bytes = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(CocoDocument.self, from: bytes)
        XCTAssertEqual(decoded.bjj_annotate_meta?.settings.sticky_category_id, 5,
                       "AC #38: backgrounding mid-debounce must flush the pending mutation")
    }

    // MARK: - Ubiquity (AC #30)

    func test_first_time_write_proceeds_when_file_does_not_exist_yet() async throws {
        // Ubiquity resolver reports not-ubiquitous (placeholder concept does not apply
        // when the file does not exist yet — first write creates it locally).
        let fake = FakeUbiquityResolver()
        fake.isUbiquitousResult = false
        let coord = CocoFileCoordinator(url: url, ubiquity: fake)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        await coord.scheduleWrite(makeDoc())
        await coord.flushNow()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}

/// AC #30 — placeholder triggers `startDownloading`, succeeds when ready / times out.
@MainActor
final class CocoFileCoordinatorUbiquityTests: XCTestCase {

    private var temp: TempDirectory!
    private var url: URL!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
        url = temp.url.appendingPathComponent("annotations.json")
    }

    override func tearDown() async throws {
        temp = nil
        url = nil
        try await super.tearDown()
    }

    private func seedDoc() -> CocoDocument {
        let meta = BjjAnnotateMeta(
            schema_version: 1,
            athletes: [],
            image_states: [],
            settings: MetaSettings(sticky_category_id: 1)
        )
        return CocoDocument(
            info: nil,
            images: [CocoImage(id: 1, file_name: "f.jpg", width: 1, height: 1)],
            categories: [],
            annotations: [],
            bjj_annotate_meta: meta
        )
    }

    func test_placeholder_triggers_startDownloading_and_succeeds_when_ready() async throws {
        // Seed an existing file so read has something to materialize.
        try JSONEncoder().encode(seedDoc()).write(to: url)
        let fake = FakeUbiquityResolver()
        fake.isUbiquitousResult = true
        fake.statusQueue = [.notDownloaded, .current]
        let coord = CocoFileCoordinator(url: url, ubiquity: fake, ubiquityTimeout: 1.0)
        _ = try await coord.readDocument()
        XCTAssertEqual(fake.startDownloadCalls.count, 1, "startDownload must fire on placeholder read")
    }

    func test_placeholder_times_out_after_10s_and_surfaces_lastError_icloudTimeout() async throws {
        try JSONEncoder().encode(seedDoc()).write(to: url)
        let fake = FakeUbiquityResolver()
        fake.isUbiquitousResult = true
        fake.statusQueue = [.notDownloaded]  // never materializes
        let coord = CocoFileCoordinator(url: url, ubiquity: fake, ubiquityTimeout: 0.05)
        do {
            _ = try await coord.readDocument()
            XCTFail("Expected materialization timeout")
        } catch CocoFileCoordinatorError.icloudMaterializationTimeout {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_first_time_write_proceeds_when_file_does_not_exist_yet() async throws {
        let fake = FakeUbiquityResolver()
        fake.isUbiquitousResult = true
        // Status would be notDownloaded forever — but write to a NON-EXISTENT file
        // must skip the materialization gate (nothing to materialize).
        fake.statusQueue = [.notDownloaded]
        let coord = CocoFileCoordinator(url: url, ubiquity: fake, ubiquityTimeout: 0.05)
        await coord.scheduleWrite(seedDoc())
        await coord.flushNow()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}

/// Production CocoFileCoordinator must not contain `try?` (AC #29).
///
/// Reads the bundled production source files (added to BJJAnnotateTests resources
/// via project.yml so the simulator sandbox can read them).
@MainActor
final class ProductionSourceGrepTests: XCTestCase {

    func test_no_try_question_mark_in_CocoFileCoordinator_or_AnnotationStore() throws {
        let files = ["CocoFileCoordinator", "AnnotationStore"]
        for name in files {
            guard let body = Self.readBundledSource(named: name) else {
                XCTFail("Could not locate bundled production source \(name).swift in test bundle")
                continue
            }
            let stripped = Self.stripComments(body)
            XCTAssertFalse(
                stripped.contains("try?"),
                "Production source must not silently swallow errors via `try?`. " +
                "Offender: \(name).swift. Use typed throws + AnnotationStore.lastError instead."
            )
        }
    }

    static func readBundledSource(named name: String) -> String? {
        let bundle = Bundle(for: ProductionSourceGrepTests.self)
        // The folder reference may flatten or preserve the subdirectory.
        let candidates: [URL?] = [
            bundle.url(forResource: name, withExtension: "swift"),
            bundle.url(forResource: name, withExtension: "swift", subdirectory: "Persistence"),
            bundle.url(forResource: name, withExtension: "swift", subdirectory: "Domain"),
        ]
        for case let url? in candidates {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        return nil
    }

    static func stripComments(_ body: String) -> String {
        body.split(separator: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//")
        }.joined(separator: "\n")
    }
}

/// AC #24: no DispatchQueue.asyncAfter in the debounce path.
@MainActor
final class DebounceImplementationGrepTests: XCTestCase {

    func test_no_DispatchQueue_asyncAfter_in_CocoFileCoordinator() throws {
        guard let body = ProductionSourceGrepTests.readBundledSource(named: "CocoFileCoordinator") else {
            return XCTFail("Could not locate bundled CocoFileCoordinator.swift in test bundle")
        }
        let stripped = ProductionSourceGrepTests.stripComments(body)
        XCTAssertFalse(stripped.contains("DispatchQueue.global"))
        XCTAssertFalse(stripped.contains(".asyncAfter("),
                       "Debounce must use Task-cancellation, not DispatchQueue.asyncAfter (AC #24).")
    }
}

/// Test-only ubiquity resolver: file is NEVER ubiquitous (skips the materialization
/// gate). Used by tests that don't care about iCloud, just the I/O contract.
struct NeverUbiquitousResolver: UbiquityResolver, Sendable {
    func isUbiquitous(at url: URL) throws -> Bool { false }
    func downloadingStatus(at url: URL) throws -> URLUbiquitousItemDownloadingStatus { .current }
    func startDownloadingAndWait(at url: URL, timeout: TimeInterval) async throws {}
}
