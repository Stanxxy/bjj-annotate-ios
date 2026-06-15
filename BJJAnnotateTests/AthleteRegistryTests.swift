import XCTest
@testable import BJJAnnotate

/// PM AC #6 + Marker B — athlete-ids are monotonically allocated as
/// `max(existing_ids) + 1`, NEVER reused, capped at 8.
final class AthleteRegistryTests: XCTestCase {

    func test_eight_sequential_allocate_calls_return_athlete_1_through_8() {
        var athletes: [Athlete] = []
        for n in 1...8 {
            guard let next = AthleteRegistry.allocate(in: athletes) else {
                return XCTFail("allocate returned nil on call #\(n)")
            }
            XCTAssertEqual(next.id, "athlete-\(n)")
            athletes.append(next)
        }
        XCTAssertEqual(athletes.map(\.id), (1...8).map { "athlete-\($0)" })
    }

    func test_palette_color_assigned_in_order() {
        var athletes: [Athlete] = []
        let expectedHexes = ["#3B82F6", "#F59E0B", "#10B981", "#EF4444",
                             "#8B5CF6", "#EC4899", "#14B8A6", "#F97316"]
        for i in 0..<8 {
            guard let next = AthleteRegistry.allocate(in: athletes) else {
                return XCTFail("allocate returned nil on slot #\(i + 1)")
            }
            XCTAssertEqual(next.color_hex, expectedHexes[i])
            athletes.append(next)
        }
    }

    func test_allocate_after_delete_returns_max_plus_one_not_lowest_gap() {
        // Marker B: athlete-ids never reused. Allocate 1..3, drop 2, next should be 4.
        var athletes: [Athlete] = []
        athletes.append(AthleteRegistry.allocate(in: athletes)!)    // 1
        athletes.append(AthleteRegistry.allocate(in: athletes)!)    // 2
        athletes.append(AthleteRegistry.allocate(in: athletes)!)    // 3
        // Drop athlete-2 (the gap).
        athletes.removeAll { $0.id == "athlete-2" }
        guard let next = AthleteRegistry.allocate(in: athletes) else {
            return XCTFail("allocate returned nil; expected athlete-4")
        }
        XCTAssertEqual(next.id, "athlete-4", "must allocate max+1, NOT fill the lowest gap")
    }

    func test_allocate_on_full_project_returns_nil() {
        var athletes: [Athlete] = []
        for _ in 1...8 {
            athletes.append(AthleteRegistry.allocate(in: athletes)!)
        }
        XCTAssertNil(
            AthleteRegistry.allocate(in: athletes),
            "9th allocation must return nil so caller can render 'Project full' row"
        )
    }

    func test_allocate_after_all_removed_still_returns_max_plus_one() {
        // Marker B taken to the extreme: even with zero current athletes, if the max
        // ever-allocated was 8, the next would exceed 8 → nil. But callers reset the
        // counter only by passing an empty list (=> first allocation returns athlete-1).
        // We document the boundary: registry is stateless across the `in` parameter;
        // callers retain history. Phase 1 callers always pass the live athletes array.
        let next = AthleteRegistry.allocate(in: [])
        XCTAssertEqual(next?.id, "athlete-1")
    }
}
