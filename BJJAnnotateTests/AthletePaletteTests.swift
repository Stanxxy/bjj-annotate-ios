import XCTest
@testable import BJJAnnotate

/// PM AC #7 — `AthletePalette` is the single source of truth for the 8 athlete colors.
final class AthletePaletteTests: XCTestCase {

    func test_palette_has_exactly_8_hexes() {
        XCTAssertEqual(AthletePalette.hexes.count, 8)
    }

    func test_palette_hexes_match_designer_locked_values() {
        XCTAssertEqual(
            AthletePalette.hexes,
            ["#3B82F6", "#F59E0B", "#10B981", "#EF4444",
             "#8B5CF6", "#EC4899", "#14B8A6", "#F97316"]
        )
    }

    func test_hex_for_athlete_id_returns_palette_slot_in_order() {
        XCTAssertEqual(AthletePalette.hex(forAthleteId: "athlete-1"), "#3B82F6")
        XCTAssertEqual(AthletePalette.hex(forAthleteId: "athlete-8"), "#F97316")
    }

    func test_hex_for_athlete_id_returns_nil_for_out_of_range_or_invalid() {
        XCTAssertNil(AthletePalette.hex(forAthleteId: "athlete-9"))
        XCTAssertNil(AthletePalette.hex(forAthleteId: "athlete-0"))
        XCTAssertNil(AthletePalette.hex(forAthleteId: "garbage"))
        XCTAssertNil(AthletePalette.hex(forAthleteId: "athlete-"))
    }
}

/// Grep gate for AC #7: no palette hex appears outside `AthletePalette.swift`.
/// Walks BJJAnnotate/ and asserts the 8 hex literals don't leak into views.
final class AthletePaletteGrepTests: XCTestCase {

    func test_palette_hex_appears_only_in_AthletePalette_swift() throws {
        let root = Self.repoRoot()
        let production = root.appendingPathComponent("BJJAnnotate", isDirectory: true)
        let hexes = ["#3B82F6", "#F59E0B", "#10B981", "#EF4444",
                     "#8B5CF6", "#EC4899", "#14B8A6", "#F97316"]
        var offenders: [(file: URL, hex: String)] = []

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: production, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let url as URL in enumerator {
            let attrs = try url.resourceValues(forKeys: [.isDirectoryKey])
            if attrs.isDirectory == true { continue }
            guard url.pathExtension == "swift" else { continue }
            // Athlete palette source of truth is allowed to mention all 8.
            if url.lastPathComponent == "AthletePalette.swift" { continue }
            let body = try String(contentsOf: url, encoding: .utf8)
            for hex in hexes where body.contains(hex) {
                offenders.append((url, hex))
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "Athlete palette hexes must live ONLY in AthletePalette.swift. Offenders:\n" +
            offenders.map { "  - \($0.hex) in \($0.file.path)" }.joined(separator: "\n")
        )
    }

    private static func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #file)
        while url.path != "/" && url.lastPathComponent != "bjj-annotate-ios" {
            url.deleteLastPathComponent()
        }
        return url
    }
}
