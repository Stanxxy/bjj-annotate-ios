import XCTest
@testable import BJJAnnotate

/// M2 + M3 — forbidden fallback safety tests.
///
/// M2: On decode failure, `AnnotatorLifecycleContext.make()` must NOT return a
/// writable bootstrap store pointed at the LIVE `annotations.json`. The
/// existing code hands back a bootstrap `AnnotationStore` with `lastError` set,
/// but the bootstrap store's `scheduler` is the SAME `CocoWriteSchedulingAdapter`
/// pointing at the live file — so the first mutation + `persist()` clobbers the
/// un-decodable real annotations. Fix: the returned store must refuse writes
/// (read-only) when a decode failure occurred, surfacing `lastError` only.
///
/// M3: `AnnotatorLifecycleContext.imageId(for:in:)` returns `1` on scan failure
/// and on not-found. Both are forbidden fallback returns (CLAUDE.md). Fix: throw
/// (or surface a typed error); never default to `1`.
///
/// All tests use real temp dirs (AC #28 — no FileManager mocks).
@MainActor
final class LifecycleContextSafetyTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifecycle-safety-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeImage(name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        // Minimal valid PNG (1×1 white, 67 bytes).
        let png: [UInt8] = [
            0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,
            0x00,0x00,0x00,0x0D,0x49,0x48,0x44,0x52,
            0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01,
            0x08,0x02,0x00,0x00,0x00,0x90,0x77,0x53,
            0xDE,0x00,0x00,0x00,0x0C,0x49,0x44,0x41,
            0x54,0x08,0xD7,0x63,0xF8,0xFF,0xFF,0x3F,
            0x00,0x05,0xFE,0x02,0xFE,0xDC,0xCC,0x59,
            0xE7,0x00,0x00,0x00,0x00,0x49,0x45,0x4E,
            0x44,0xAE,0x42,0x60,0x82
        ]
        try Data(png).write(to: url)
        return url
    }

    // MARK: - M2 tests

    /// M2-A: On decode failure, `make()` must set `store.lastError` to `.decodeFailed`.
    func test_make_sets_lastError_decodeFailed_on_corrupt_annotations() async throws {
        let img = try makeImage(name: "frame_0001.png")
        // Write corrupt JSON to annotations.json.
        let annotationsURL = tempDir.appendingPathComponent("annotations.json")
        try Data("THIS IS NOT JSON".utf8).write(to: annotationsURL)

        let context = try await AnnotatorLifecycleContext.make(
            folderURL: tempDir,
            imageURL: img,
            ubiquity: FakeUbiquityResolver()
        )

        // Must set lastError.
        XCTAssertNotNil(context.store.lastError,
                        "M2: decode failure must set store.lastError.")
        guard let err = context.store.lastError else { return }
        switch err {
        case .decodeFailed, .readFailed:
            break  // Either is acceptable — corrupt JSON may manifest as either.
        default:
            XCTFail("M2: decode failure lastError should be .decodeFailed or .readFailed, got \(err)")
        }
    }

    /// M2-B: On decode failure, the returned store must NOT clobber the original
    /// corrupt `annotations.json` on a subsequent mutation. The original corrupt file
    /// must remain intact (bytes unchanged) after a box is drawn.
    func test_make_on_decode_failure_does_NOT_overwrite_corrupt_annotations_on_mutation() async throws {
        let img = try makeImage(name: "frame_0001.png")
        let annotationsURL = tempDir.appendingPathComponent("annotations.json")
        let corruptBytes = Data("CORRUPT".utf8)
        try corruptBytes.write(to: annotationsURL)

        let context = try await AnnotatorLifecycleContext.make(
            folderURL: tempDir,
            imageURL: img,
            ubiquity: FakeUbiquityResolver()
        )

        // Attempt a mutation.
        context.store.upsertBox(BBoxIntent(rect: BBox(x: 10, y: 10, w: 50, h: 50)))
        // Force-flush so any pending write would have completed.
        await context.coordinator.flushNow()

        // The original corrupt bytes must still be on disk (write was blocked).
        let onDisk = try Data(contentsOf: annotationsURL)
        XCTAssertEqual(
            onDisk, corruptBytes,
            "M2: corrupt annotations.json must NOT be overwritten by bootstrap write after decode failure. Data on disk was modified: \(String(data: onDisk, encoding: .utf8) ?? "<binary>")"
        )
    }

    /// M2-C: On decode failure, the store must be in a read-only state that refuses
    /// scheduling writes. Concretely: `diskWriteCount` on the coordinator must remain 0
    /// after a mutation on the decode-failed store.
    func test_make_on_decode_failure_store_does_not_schedule_writes() async throws {
        let img = try makeImage(name: "frame_0001.png")
        let annotationsURL = tempDir.appendingPathComponent("annotations.json")
        try Data("NOT-JSON".utf8).write(to: annotationsURL)

        let context = try await AnnotatorLifecycleContext.make(
            folderURL: tempDir,
            imageURL: img,
            ubiquity: FakeUbiquityResolver()
        )

        let writesBefore = await context.coordinator.diskWriteCount
        context.store.upsertBox(BBoxIntent(rect: BBox(x: 1, y: 1, w: 20, h: 20)))
        await context.coordinator.flushNow()
        let writesAfter = await context.coordinator.diskWriteCount

        XCTAssertEqual(
            writesBefore, writesAfter,
            "M2: decode-failed store must not trigger any disk writes (before: \(writesBefore), after: \(writesAfter))."
        )
    }

    // MARK: - M3 tests

    /// M3-A: `imageId(for:in:)` must throw when the folder scan fails (e.g. non-existent folder).
    /// The prior code swallows the scan error and returns `1`, cross-contaminating annotations.
    func test_imageId_throws_on_scan_failure() {
        let nonExistentFolder = tempDir.appendingPathComponent("does-not-exist", isDirectory: true)
        let imageURL = nonExistentFolder.appendingPathComponent("frame_0001.png")

        XCTAssertThrowsError(
            try AnnotatorLifecycleContext.imageId(
                for: imageURL,
                in: nonExistentFolder,
                ubiquity: FakeUbiquityResolver()
            ),
            "M3: imageId(for:in:) must throw on scan failure, not return 1."
        )
    }

    /// M3-B: `imageId(for:in:)` must throw when the image is not found in the folder scan.
    /// The prior code returned `1` in the not-found path, mapping to a different image's id.
    func test_imageId_throws_when_image_not_found_in_folder() throws {
        // Create a valid folder with one image, but ask for a DIFFERENT imageURL.
        let knownImage = try makeImage(name: "frame_0001.png")
        _ = knownImage  // exists in folder
        let unknownImage = tempDir.appendingPathComponent("totally_absent.png")

        XCTAssertThrowsError(
            try AnnotatorLifecycleContext.imageId(
                for: unknownImage,
                in: tempDir,
                ubiquity: FakeUbiquityResolver()
            ),
            "M3: imageId(for:in:) must throw when image not found in folder, not return 1."
        )
    }

    /// M3-C: `make()` must propagate the imageId error as a thrown error (or a lastError),
    /// rather than silently scoping the store to imageId 1 (which cross-contaminates another image).
    func test_make_propagates_error_when_imageURL_not_in_folder() async throws {
        _ = try makeImage(name: "frame_0001.png")  // known image in folder
        let unknownImage = tempDir.appendingPathComponent("ghost.png")  // not in folder

        do {
            let _ = try await AnnotatorLifecycleContext.make(
                folderURL: tempDir,
                imageURL: unknownImage,
                ubiquity: FakeUbiquityResolver()
            )
            XCTFail("M3: make() must throw or surface error when imageURL not found in folder.")
        } catch {
            // Expected: make() throws when imageId cannot be determined.
            XCTAssertNotNil(error, "M3: a real error must propagate, not a silent default.")
        }
    }
}
