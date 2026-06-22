import XCTest
@testable import BJJAnnotate

/// AC #33 — `store.coco` IS what's written to disk.
///
/// Evaluator LOW #2 cleanup: a focused 5-line byte-equality test that locks the
/// "single source of truth" invariant at the persistence boundary. If anyone
/// ever introduces a second encoding path, a header, a wrapper key, or a
/// re-serialization round-trip, this test fails.
///
/// Whitespace tolerance:
///   None. `CocoFileCoordinator` writes with `JSONEncoder` configured for
///   `[.sortedKeys, .withoutEscapingSlashes]` and NO `.prettyPrinted`. This test
///   constructs the same encoder and compares raw bytes verbatim. Any difference
///   in whitespace, key order, or escaping fails the assertion.
final class CocoIsDiskTruthTests: XCTestCase {

    private var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    func test_ac33_in_memory_coco_is_byte_identical_to_what_lands_on_disk() async throws {
        let url = temp.url.appendingPathComponent("annotations.json")
        let coord = CocoFileCoordinator(url: url, ubiquity: NeverUbiquitousResolver())

        // 1. Build a non-trivial document so the test would catch a header injection.
        let meta = BjjAnnotateMeta(
            schema_version: 1,
            athletes: [
                Athlete(id: "athlete-1", display_name: "athlete-1", color_hex: "#2D6CDF"),
                Athlete(id: "athlete-2", display_name: "athlete-2", color_hex: "#F2A93B"),
            ],
            image_states: [],
            settings: MetaSettings(sticky_category_id: 2)
        )
        let coco = CocoDocument(
            info: nil,
            images: [CocoImage(id: 1, file_name: "frame.jpg", width: 1920, height: 1080)],
            categories: [],
            annotations: [
                CocoAnnotation(
                    id: 1, image_id: 1, category_id: 2,
                    bbox: [10, 20, 30, 40], area: 1200, iscrowd: 0,
                    segmentation: [],
                    score: nil,
                    attributes: CocoAnnotationAttributes(athlete_id: "athlete-1", source: "user", model_version: nil),
                    keypoints: [],
                    num_keypoints: 0
                ),
            ],
            bjj_annotate_meta: meta
        )

        // 2. Persist via the coordinator (production path).
        await coord.scheduleWrite(coco)
        await coord.flushNow()

        // 3. Re-encode the same in-memory document with the production-equivalent encoder.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let expected = try encoder.encode(coco)

        // 4. Read disk bytes and assert byte-for-byte equality.
        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(
            onDisk, expected,
            "AC #33: bytes on disk must equal JSONEncoder([.sortedKeys, .withoutEscapingSlashes]).encode(coco) " +
            "with NO additional wrapper, header, or pretty-printing."
        )
    }
}
