import XCTest
@testable import BJJAnnotate

/// AC #34 — conflict detection emits sidecar with ISO8601 timestamp.
/// AC #36 — athlete dictionaries never merged across versions.
///
/// Phase 1 cannot easily reproduce a TRUE NSFileVersion conflict from a unit
/// test (it requires two iCloud writers). We exercise the SIDECAR EMISSION
/// path directly by injecting a synthesised conflict descriptor.
final class CocoFileCoordinatorConflictTests: XCTestCase {

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

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private func makeDoc(athletes: [Athlete], stickyCategoryId: Int) -> CocoDocument {
        let meta = BjjAnnotateMeta(
            schema_version: 1,
            athletes: athletes,
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

    func test_NSFileVersion_unresolved_emits_sidecar_with_ISO8601_timestamp() throws {
        // Synthesise a conflict scenario: pretend there is a loser document we wish
        // to preserve at modification time T. Emit the sidecar via the static helper
        // and assert filename pattern + bytes.
        let winner = makeDoc(athletes: [Athlete(id: "athlete-1", display_name: "athlete-1", color_hex: "#3B82F6")],
                             stickyCategoryId: 1)
        let loser = makeDoc(athletes: [Athlete(id: "athlete-1", display_name: "athlete-1", color_hex: "#EF4444"),
                                       Athlete(id: "athlete-2", display_name: "athlete-2", color_hex: "#F59E0B")],
                            stickyCategoryId: 2)
        let modificationDate = Date(timeIntervalSince1970: 1_800_000_000)

        // Seed the winner on disk.
        let bytes = try Self.encoder.encode(winner)
        try bytes.write(to: url)

        // Emit sidecar.
        let event = try ConflictSidecar.emit(
            directory: temp.url,
            losersBytes: try Self.encoder.encode(loser),
            loserModificationDate: modificationDate,
            winnerURL: url,
            differingAnnotationIds: [42, 43]
        )

        // Sidecar name pattern: annotations.conflict-<ISO8601>.json
        XCTAssertTrue(
            event.sidecarURL.lastPathComponent.hasPrefix("annotations.conflict-"),
            "Sidecar filename must start with 'annotations.conflict-' (saw: \(event.sidecarURL.lastPathComponent))"
        )
        XCTAssertTrue(event.sidecarURL.lastPathComponent.hasSuffix(".json"))
        XCTAssertTrue(
            event.sidecarURL.lastPathComponent.contains("2027"),
            "ISO8601 component must include the year for timestamp \(modificationDate)"
        )

        // Sidecar bytes match loser verbatim (AC #34 + AC #36 — no merge, no
        // transformation; the loser is preserved exactly so the user can inspect).
        let sidecarBytes = try Data(contentsOf: event.sidecarURL)
        XCTAssertEqual(sidecarBytes, try Self.encoder.encode(loser))

        XCTAssertEqual(event.winnerURL, url)
        XCTAssertEqual(event.differingAnnotationIds, [42, 43])
    }

    func test_conflict_never_merges_athlete_dictionaries() throws {
        // Setup: winner has 1 athlete (blue), loser has 2 athletes with the same id
        // but different color. The winner is the "live" coco; the loser becomes the
        // sidecar bytes. Asserts: (a) the on-disk winner file is unchanged; (b) the
        // sidecar bytes contain the loser's athlete dictionary VERBATIM (NOT merged
        // with winner's). This is the AC #36 contract.
        let winner = makeDoc(athletes: [Athlete(id: "athlete-1", display_name: "athlete-1", color_hex: "#3B82F6")],
                             stickyCategoryId: 1)
        let loser = makeDoc(athletes: [Athlete(id: "athlete-1", display_name: "athlete-1", color_hex: "#EF4444"),
                                       Athlete(id: "athlete-2", display_name: "athlete-2", color_hex: "#F59E0B")],
                            stickyCategoryId: 2)

        // Seed disk with winner.
        let winnerBytes = try Self.encoder.encode(winner)
        try winnerBytes.write(to: url)

        // Emit conflict.
        let event = try ConflictSidecar.emit(
            directory: temp.url,
            losersBytes: try Self.encoder.encode(loser),
            loserModificationDate: Date(),
            winnerURL: url,
            differingAnnotationIds: []
        )

        // Winner on disk is unchanged.
        XCTAssertEqual(try Data(contentsOf: url), winnerBytes)

        // Sidecar contains loser, NOT merged.
        let sidecarDecoded = try JSONDecoder().decode(CocoDocument.self, from: Data(contentsOf: event.sidecarURL))
        XCTAssertEqual(sidecarDecoded.bjj_annotate_meta?.athletes.count, 2,
                       "Loser's two-athlete dictionary preserved verbatim")
        XCTAssertEqual(sidecarDecoded.bjj_annotate_meta?.athletes.first?.color_hex, "#EF4444",
                       "Loser's color preserved (NOT merged with winner's #3B82F6)")
    }
}
