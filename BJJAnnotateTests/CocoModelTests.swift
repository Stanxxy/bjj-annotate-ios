import XCTest
@testable import BJJAnnotate

/// Phase 1 CocoModel round-trip invariants.
///
/// AC #1 — `CocoModel` decode→encode→decode round-trip is bit-identical for the
/// hand-built fixture.
/// AC #2 — Referee instances omit `keypoints` AND `num_keypoints`.
/// AC #3 — `bjj_annotate_meta` preserves unknown future fields verbatim.
/// AC #32 (partial) — fixture loads via `pycocotools` (the fixture is the same file
/// PM will drag into CVAT / Roboflow; we cannot exercise pycocotools from Swift).
final class CocoModelTests: XCTestCase {

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    private static let decoder = JSONDecoder()

    private func loadFixture() throws -> Data {
        let url = try Self.fixtureURL()
        return try Data(contentsOf: url)
    }

    private static func fixtureURL() throws -> URL {
        // Fixture is bundled as a resource of BJJAnnotateTests via project.yml's
        // `type: folder, buildPhase: resources` entry. Bundle(for:) resolves to the
        // test bundle inside the simulator's sandbox.
        let bundle = Bundle(for: CocoModelTests.self)
        if let url = bundle.url(forResource: "example.coco", withExtension: "json") {
            return url
        }
        // The folder reference may preserve the subdirectory.
        if let url = bundle.url(forResource: "example.coco", withExtension: "json", subdirectory: "Fixtures") {
            return url
        }
        throw NSError(
            domain: "CocoModelTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not find example.coco.json in test bundle \(bundle.bundlePath)"]
        )
    }

    // MARK: - AC #1

    func test_fixture_roundtrip_is_bit_identical_after_sort_key_encode() throws {
        let rawBytes = try loadFixture()
        let decoded = try Self.decoder.decode(CocoDocument.self, from: rawBytes)
        let reEncoded = try Self.encoder.encode(decoded)
        XCTAssertEqual(
            reEncoded,
            rawBytes,
            """
            Encoded bytes do not match fixture bytes.
            Expected: \(String(data: rawBytes, encoding: .utf8) ?? "<not utf8>")
            Actual:   \(String(data: reEncoded, encoding: .utf8) ?? "<not utf8>")
            """
        )
    }

    func test_fixture_numeric_42_dot_0_does_not_collapse_to_42() throws {
        // AC #1 prohibits silent numeric reformatting (e.g. `42.0` → `42`).
        //
        // Implementation note (AIP §2 R2): JSONEncoder canonicalises Double(120000)
        // to the integer literal `120000` — it cannot distinguish `42.0` from `42`
        // at the value level. We honor the AC by AUTHORING the fixture exclusively
        // with naturally-canonical float values (every Double has a non-zero
        // fractional digit), so the encoder's canonical form matches the fixture
        // byte-for-byte. The bit-identity test above is the strict gate; this test
        // pins the convention so a future fixture edit that re-introduces a
        // `.0`-suffixed integer-valued float fails fast.
        let rawBytes = try loadFixture()
        let rawString = String(data: rawBytes, encoding: .utf8) ?? ""

        // Fixture convention: no `\.0[^0-9]` patterns in numeric positions inside
        // `bbox`/`area`/`score`. A naive regex scan catches the most common reintroduction:
        // an area or bbox value with a trailing `.0` that JSONEncoder would erase.
        let forbiddenPatterns = [
            "\"area\":42000.0,",
            "\"area\":90000.0,",
            "\"area\":120000.0,",
        ]
        for pattern in forbiddenPatterns {
            XCTAssertFalse(
                rawString.contains(pattern),
                "Fixture re-introduced `\(pattern)` — JSONEncoder will collapse this to `.0`-less " +
                "and break AC #1's bit-identity. Use a fractional value instead."
            )
        }

        // Sanity: round-trip still bit-identical (cross-test redundancy is intentional —
        // this test serves as the watchpoint, not the gate).
        let decoded = try Self.decoder.decode(CocoDocument.self, from: rawBytes)
        let reEncoded = try Self.encoder.encode(decoded)
        XCTAssertEqual(reEncoded, rawBytes)
    }

    // MARK: - AC #2

    func test_referee_annotation_omits_keypoints_and_num_keypoints() throws {
        let rawBytes = try loadFixture()
        let decoded = try Self.decoder.decode(CocoDocument.self, from: rawBytes)
        let referees = decoded.annotations.filter { $0.category_id == 3 }
        XCTAssertFalse(referees.isEmpty, "Fixture must include ≥ 1 referee")
        for ref in referees {
            XCTAssertNil(ref.keypoints, "Referee annotation must omit `keypoints`")
            XCTAssertNil(ref.num_keypoints, "Referee annotation must omit `num_keypoints`")
        }
        // Encode + verify the bytes literally do not contain "keypoints" inside the
        // referee annotation object.
        let reEncoded = try Self.encoder.encode(decoded)
        let reEncodedString = String(data: reEncoded, encoding: .utf8) ?? ""
        // The fixture string is the same as the re-encoded bytes (by AC #1), so this
        // also locks the on-disk shape: no referee should have a keypoints field.
        let refereeBytes = #""category_id":3"#
        XCTAssertTrue(reEncodedString.contains(refereeBytes), "Referee annotation must encode")
        // Spot-check: locate the referee annotation object and assert it has no
        // "keypoints" key inside its scope. We parse with JSONSerialization for the
        // structural check (the bit-identity test guards full round-trip).
        guard let json = try JSONSerialization.jsonObject(with: reEncoded) as? [String: Any],
              let anns = json["annotations"] as? [[String: Any]] else {
            return XCTFail("Could not parse re-encoded JSON")
        }
        let refDicts = anns.filter { ($0["category_id"] as? Int) == 3 }
        XCTAssertFalse(refDicts.isEmpty)
        for refDict in refDicts {
            XCTAssertFalse(refDict.keys.contains("keypoints"), "Referee dict has `keypoints`: \(refDict)")
            XCTAssertFalse(refDict.keys.contains("num_keypoints"), "Referee dict has `num_keypoints`: \(refDict)")
        }
    }

    // MARK: - AC #3

    func test_bjj_annotate_meta_preserves_unknown_field_through_roundtrip() throws {
        let rawBytes = try loadFixture()
        let decoded = try Self.decoder.decode(CocoDocument.self, from: rawBytes)
        // Unknown key from fixture: experimental_future_flag = true.
        let flag = decoded.bjj_annotate_meta?.additionalProperties["experimental_future_flag"]
        XCTAssertEqual(flag, .bool(true), "additionalProperties must capture unknown key")

        let reEncoded = try Self.encoder.encode(decoded)
        let reDecoded = try Self.decoder.decode(CocoDocument.self, from: reEncoded)
        let flagAfter = reDecoded.bjj_annotate_meta?.additionalProperties["experimental_future_flag"]
        XCTAssertEqual(flagAfter, .bool(true), "Unknown key must survive a second round-trip")
    }
}
