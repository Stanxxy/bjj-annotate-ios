import XCTest
@testable import BJJAnnotate

/// I1 integration tests — red before implementation.
///
/// These tests verify that `AnnotatorView` correctly owns the per-project
/// `AnnotationStore` + `CocoFileCoordinator` lifecycle:
///
///   - `AnnotatorLifecycleContext.make(folderURL:imageURL:)` creates a store
///     scoped to the project folder with the imageId matching the image's
///     position in the sorted scan.
///   - On first open (no existing `annotations.json`), the store starts from
///     an empty COCO document with the BJJ category bootstrap.
///   - On subsequent open, the store reads the existing `annotations.json` and
///     filters existing annotations for the current imageId.
///   - The `imageId` is the 1-based position of the image file in the sorted
///     scan — consistent across openings of the same folder.
///
/// Tests use real temp directories (AC #28 — no FileManager mocks).
/// Symbols `AnnotatorLifecycleContext` does not yet exist — verifies red.
@MainActor
final class AnnotatorViewLifecycleTests: XCTestCase {

    // MARK: - Helpers

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("annotator-lifecycle-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func makeImage(name: String) throws -> URL {
        // 1×1 white PNG for lightweight test fixture.
        let url = tempDir.appendingPathComponent(name)
        // Minimal valid PNG (1×1 white pixel, 67 bytes).
        let png: [UInt8] = [
            0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A, // sig
            0x00,0x00,0x00,0x0D,0x49,0x48,0x44,0x52, // IHDR len+type
            0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01, // w=1 h=1
            0x08,0x02,0x00,0x00,0x00,0x90,0x77,0x53, // 8bpc RGB CRC
            0xDE,0x00,0x00,0x00,0x0C,0x49,0x44,0x41, // IDAT
            0x54,0x08,0xD7,0x63,0xF8,0xFF,0xFF,0x3F, // deflate
            0x00,0x05,0xFE,0x02,0xFE,0xDC,0xCC,0x59, // crc
            0xE7,0x00,0x00,0x00,0x00,0x49,0x45,0x4E, // IEND
            0x44,0xAE,0x42,0x60,0x82               // IEND crc
        ]
        try Data(png).write(to: url)
        return url
    }

    // MARK: - Tests

    /// I1-A: `AnnotatorLifecycleContext.make` constructs a store from an empty project.
    /// The returned store's `coco` starts empty with the BJJ category bootstrap.
    func test_make_from_empty_project_returns_empty_store_with_bootstrap_categories() async throws {
        let img = try makeImage(name: "frame_0001.png")
        let context = try await AnnotatorLifecycleContext.make(
            folderURL: tempDir,
            imageURL: img,
            ubiquity: FakeUbiquityResolver()
        )
        // Store is non-nil; coco is empty of annotations.
        XCTAssertEqual(context.store.coco.annotations.count, 0,
                       "Empty project must produce zero annotations on first open.")
        // Categories bootstrapped (gi-athlete/nogi-athlete/referee = 3).
        XCTAssertEqual(context.store.coco.categories.count, 3,
                       "Bootstrap must produce exactly 3 BJJ categories.")
        // imageId matches 1-based sorted position.
        XCTAssertEqual(context.store.imageId, 1,
                       "First (only) image must get imageId 1.")
    }

    /// I1-B: `imageId` reflects the 1-based sorted position of the image in the folder.
    func test_imageId_reflects_sorted_position_of_image_in_folder() async throws {
        let a = try makeImage(name: "frame_0003.png")
        _ = try makeImage(name: "frame_0001.png")
        _ = try makeImage(name: "frame_0002.png")
        // Sorted ascending: frame_0001 (1), frame_0002 (2), frame_0003 (3).
        let context = try await AnnotatorLifecycleContext.make(
            folderURL: tempDir,
            imageURL: a,  // frame_0003 → position 3
            ubiquity: FakeUbiquityResolver()
        )
        XCTAssertEqual(context.store.imageId, 3,
                       "frame_0003 is the 3rd sorted image; imageId must be 3.")
    }

    /// I1-C: Re-opening the same image after a write reloads the persisted annotation.
    func test_round_trip_open_mutate_reopen_returns_persisted_annotation() async throws {
        let img = try makeImage(name: "frame_0001.png")

        // First open: draw a box.
        let ctx1 = try await AnnotatorLifecycleContext.make(
            folderURL: tempDir,
            imageURL: img,
            ubiquity: FakeUbiquityResolver()
        )
        ctx1.store.upsertBox(BBoxIntent(rect: BBox(x: 10, y: 10, w: 50, h: 50)))
        // Flush immediately (bypass 500ms debounce for test determinism).
        await ctx1.coordinator.flushNow()

        // Second open: new context reads from disk.
        let ctx2 = try await AnnotatorLifecycleContext.make(
            folderURL: tempDir,
            imageURL: img,
            ubiquity: FakeUbiquityResolver()
        )
        let annotations = ctx2.store.coco.annotations.filter { $0.image_id == ctx2.store.imageId }
        XCTAssertEqual(annotations.count, 1,
                       "Round-trip: one box drawn must reload as one annotation after reopen.")
        XCTAssertEqual(annotations[0].bbox, [10.0, 10.0, 50.0, 50.0],
                       "Round-trip: bbox must survive flush + reload.")
    }

    /// I1-D: `annotations.json` is written next to the images (same folder URL).
    func test_annotations_json_written_to_project_folder() async throws {
        let img = try makeImage(name: "frame_0001.png")
        let ctx = try await AnnotatorLifecycleContext.make(
            folderURL: tempDir,
            imageURL: img,
            ubiquity: FakeUbiquityResolver()
        )
        ctx.store.upsertBox(BBoxIntent(rect: BBox(x: 0, y: 0, w: 100, h: 100)))
        await ctx.coordinator.flushNow()

        let annotationsURL = tempDir.appendingPathComponent("annotations.json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: annotationsURL.path),
            "annotations.json must be written to the project folder."
        )
    }

    /// I1-E: No `annotations.json` error on first open when file does not exist.
    func test_make_succeeds_when_annotations_json_does_not_exist() async throws {
        let img = try makeImage(name: "frame_0001.png")
        // Must not throw — first-write path (no existing file).
        let context = try await AnnotatorLifecycleContext.make(
            folderURL: tempDir,
            imageURL: img,
            ubiquity: FakeUbiquityResolver()
        )
        XCTAssertNil(context.store.lastError,
                     "First open must produce no lastError when annotations.json does not exist.")
    }
}
