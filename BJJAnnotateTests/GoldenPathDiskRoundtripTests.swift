import XCTest
@testable import BJJAnnotate

/// I4 — Golden-path REAL disk roundtrip (the deferred assertion from T24).
///
/// The T24 XCUITest verifies navigation end-to-end but deferred the final
/// assertion that the box survives a force-quit + relaunch from DISK. This unit
/// test closes that gap via a two-phase approach:
///
///   Phase A: open project, draw box + assign class + add athlete, flush to disk.
///   Phase B: reconstruct the context from the same folder URL (simulates relaunch),
///            assert the box is present with correct geometry, class, and athlete-id.
///
/// This is a legitimate unit-level substitute for XCUITest force-quit because the
/// persistence layer (`CocoFileCoordinator` + `AnnotatorLifecycleContext`) is the
/// subject under test, not the navigation stack. The XCUITest (T24) verifies that
/// the NAVIGATION stack wires to the correct `folderURL`; this test verifies that
/// the PERSISTENCE layer survives a context teardown + rebuild — which is equivalent
/// to process death + relaunch at the persistence layer.
///
/// AC #31 (round-trip after 10 mutations) — also covered here.
///
/// `AnnotatorLifecycleContext` does not yet exist — verifies red.
@MainActor
final class GoldenPathDiskRoundtripTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("golden-path-disk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func makeImage(name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        // 1×1 white JPEG (minimal valid JPEG, 267 bytes).
        let jpeg: [UInt8] = [
            0xFF,0xD8,0xFF,0xE0,0x00,0x10,0x4A,0x46,0x49,0x46,0x00,0x01,
            0x01,0x00,0x00,0x01,0x00,0x01,0x00,0x00,0xFF,0xDB,0x00,0x43,
            0x00,0x08,0x06,0x06,0x07,0x06,0x05,0x08,0x07,0x07,0x07,0x09,
            0x09,0x08,0x0A,0x0C,0x14,0x0D,0x0C,0x0B,0x0B,0x0C,0x19,0x12,
            0x13,0x0F,0x14,0x1D,0x1A,0x1F,0x1E,0x1D,0x1A,0x1C,0x1C,0x20,
            0x24,0x2E,0x27,0x20,0x22,0x2C,0x23,0x1C,0x1C,0x28,0x37,0x29,
            0x2C,0x30,0x31,0x34,0x34,0x34,0x1F,0x27,0x39,0x3D,0x38,0x32,
            0x3C,0x2E,0x33,0x34,0x32,0xFF,0xC0,0x00,0x0B,0x08,0x00,0x01,
            0x00,0x01,0x01,0x01,0x11,0x00,0xFF,0xC4,0x00,0x1F,0x00,0x00,
            0x01,0x05,0x01,0x01,0x01,0x01,0x01,0x01,0x00,0x00,0x00,0x00,
            0x00,0x00,0x00,0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,
            0x09,0x0A,0x0B,0xFF,0xC4,0x00,0xB5,0x10,0x00,0x02,0x01,0x03,
            0x03,0x02,0x04,0x03,0x05,0x05,0x04,0x04,0x00,0x00,0x01,0x7D,
            0x01,0x02,0x03,0x00,0x04,0x11,0x05,0x12,0x21,0x31,0x41,0x06,
            0x13,0x51,0x61,0x07,0x22,0x71,0x14,0x32,0x81,0x91,0xA1,0x08,
            0x23,0x42,0xB1,0xC1,0x15,0x52,0xD1,0xF0,0x24,0x33,0x62,0x72,
            0x82,0x09,0x0A,0x16,0x17,0x18,0x19,0x1A,0x25,0x26,0x27,0x28,
            0x29,0x2A,0x34,0x35,0x36,0x37,0x38,0x39,0x3A,0x43,0x44,0x45,
            0x46,0x47,0x48,0x49,0x4A,0x53,0x54,0x55,0x56,0x57,0x58,0x59,
            0x5A,0x63,0x64,0x65,0x66,0x67,0x68,0x69,0x6A,0x73,0x74,0x75,
            0x76,0x77,0x78,0x79,0x7A,0x83,0x84,0x85,0x86,0x87,0x88,0x89,
            0x8A,0x93,0x94,0x95,0x96,0x97,0x98,0x99,0x9A,0xA2,0xA3,0xA4,
            0xFF,0xDA,0x00,0x08,0x01,0x01,0x00,0x00,0x3F,0x00,0xFB,0xF1,
            0xFF,0xD9
        ]
        try Data(jpeg).write(to: url)
        return url
    }

    // MARK: - Tests

    /// I4-A: draw box + set class + add athlete → flush → reopen → box present with
    ///        correct geometry, class, and athlete-id.
    func test_box_class_athlete_survive_context_teardown_and_rebuild() async throws {
        let img = try makeImage(name: "frame_0001.jpg")

        // Phase A: draw.
        let ctx1 = try await AnnotatorLifecycleContext.make(
            folderURL: tempDir,
            imageURL: img,
            ubiquity: FakeUbiquityResolver()
        )
        let instanceId = ctx1.store.upsertBox(BBoxIntent(rect: BBox(x: 100, y: 200, w: 300, h: 150)))
        ctx1.store.setClass(instanceId: instanceId, category: .nogi)
        // setClass from gi (auto-assigned at create) to nogi; athlete-id preserved.
        // Allocate a second athlete and bind it.
        _ = ctx1.store.allocateAndBindAthlete(toInstanceId: instanceId)

        // Flush to disk.
        await ctx1.coordinator.flushNow()

        // Assert file exists.
        let annotationsURL = tempDir.appendingPathComponent("annotations.json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: annotationsURL.path),
            "Phase A: annotations.json must exist after flush."
        )

        // Phase B: rebuild.
        let ctx2 = try await AnnotatorLifecycleContext.make(
            folderURL: tempDir,
            imageURL: img,
            ubiquity: FakeUbiquityResolver()
        )
        let reloaded = ctx2.store.coco.annotations.filter { $0.image_id == ctx2.store.imageId }
        XCTAssertEqual(reloaded.count, 1, "Phase B: exactly one annotation must reload.")
        let ann = try XCTUnwrap(reloaded.first)
        XCTAssertEqual(ann.bbox, [100.0, 200.0, 300.0, 150.0], "Geometry must survive roundtrip.")
        XCTAssertEqual(ann.category_id, ClassCategory.nogi.rawValue, "Class must survive roundtrip.")
        XCTAssertNotNil(ann.attributes.athlete_id, "Athlete-id must survive roundtrip.")
    }

    /// I4-B: 10 mutations then round-trip (AC #31 proxy via unit layer).
    func test_10_mutations_round_trip_all_survive() async throws {
        let img = try makeImage(name: "frame_0001.jpg")
        let ctx1 = try await AnnotatorLifecycleContext.make(
            folderURL: tempDir,
            imageURL: img,
            ubiquity: FakeUbiquityResolver()
        )

        // Draw 5 boxes.
        var ids: [Int] = []
        for i in 0..<5 {
            let id = ctx1.store.upsertBox(BBoxIntent(rect: BBox(
                x: Double(i * 20), y: Double(i * 10), w: 50, h: 50
            )))
            ids.append(id)
        }
        // Change class on 2 boxes.
        ctx1.store.setClass(instanceId: ids[0], category: .nogi)
        ctx1.store.setClass(instanceId: ids[1], category: .ref)
        // Add 2 athletes.
        _ = ctx1.store.allocateAndBindAthlete(toInstanceId: ids[2])
        _ = ctx1.store.allocateAndBindAthlete(toInstanceId: ids[3])
        // Delete 1 box.
        ctx1.store.deleteInstance(instanceId: ids[4])

        // Flush.
        await ctx1.coordinator.flushNow()

        // Reopen.
        let ctx2 = try await AnnotatorLifecycleContext.make(
            folderURL: tempDir,
            imageURL: img,
            ubiquity: FakeUbiquityResolver()
        )
        let reloaded = ctx2.store.coco.annotations.filter { $0.image_id == ctx2.store.imageId }
        XCTAssertEqual(reloaded.count, 4,
                       "10 mutations including 1 delete must leave 4 annotations on disk.")
        // ids[0] is nogi.
        let nogi = reloaded.first { $0.id == ids[0] }
        XCTAssertEqual(nogi?.category_id, ClassCategory.nogi.rawValue,
                       "Category must survive for nogi box.")
        // ids[1] is ref (no athlete).
        let ref = reloaded.first { $0.id == ids[1] }
        XCTAssertEqual(ref?.category_id, ClassCategory.ref.rawValue)
        XCTAssertNil(ref?.attributes.athlete_id, "Referee must have no athlete-id after roundtrip.")
        // ids[4] must be gone.
        XCTAssertNil(reloaded.first { $0.id == ids[4] },
                     "Deleted box must not survive roundtrip.")
    }
}
