import XCTest
@testable import BJJAnnotate

/// Tests for `KeypointMirror` — the pure L↔R swap helper.
///
/// Evaluator gate items covered here:
/// - Mirror is an involution: `mirror(mirror(x)) == x`
/// - Nose (index 1) is unchanged by mirror
/// - Visibility flags travel with the position (not the semantic label)
/// - Wrong-length arrays are returned unchanged
final class KeypointMirrorTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a 51-element flat keypoints array with distinct values so we can
    /// verify the exact swap positions. Each keypoint slot is (index*10, index*10+1, vis).
    private func makeDistinctArray(vis: Double = 2.0) -> [Double] {
        var arr = Array(repeating: 0.0, count: 51)
        for i in 1...17 {
            let off = (i - 1) * 3
            arr[off]     = Double(i * 10)       // x = 10, 20, …, 170
            arr[off + 1] = Double(i * 10 + 1)   // y = 11, 21, …, 171
            arr[off + 2] = vis                  // visibility
        }
        return arr
    }

    // MARK: - Involution

    func test_mirror_is_involution() {
        let original = makeDistinctArray()
        let doubled = KeypointMirror.mirror(KeypointMirror.mirror(original))
        XCTAssertEqual(doubled, original, "mirror(mirror(x)) must equal x")
    }

    func test_mirror_involution_with_mixed_visibility() {
        var arr = makeDistinctArray()
        // Mix visibility values across indices.
        for i in 0..<17 {
            arr[i * 3 + 2] = Double(i % 3) // 0, 1, 2, 0, 1, 2, …
        }
        let doubled = KeypointMirror.mirror(KeypointMirror.mirror(arr))
        XCTAssertEqual(doubled, arr, "mirror(mirror(x)) must equal x for mixed visibility")
    }

    // MARK: - Nose unchanged

    func test_nose_index_1_is_unchanged_by_mirror() {
        let original = makeDistinctArray()
        let mirrored = KeypointMirror.mirror(original)
        // Nose is at offset 0.
        XCTAssertEqual(mirrored[0], original[0], "nose x unchanged")
        XCTAssertEqual(mirrored[1], original[1], "nose y unchanged")
        XCTAssertEqual(mirrored[2], original[2], "nose visibility unchanged")
    }

    // MARK: - Pair swaps

    func test_mirror_swaps_left_eye_and_right_eye() {
        let original = makeDistinctArray()
        let mirrored = KeypointMirror.mirror(original)
        // left_eye=2 (offset 3) ↔ right_eye=3 (offset 6)
        XCTAssertEqual(mirrored[3], original[6], "left_eye.x ← right_eye.x")
        XCTAssertEqual(mirrored[4], original[7], "left_eye.y ← right_eye.y")
        XCTAssertEqual(mirrored[5], original[8], "left_eye.vis ← right_eye.vis")
        XCTAssertEqual(mirrored[6], original[3], "right_eye.x ← left_eye.x")
        XCTAssertEqual(mirrored[7], original[4], "right_eye.y ← left_eye.y")
        XCTAssertEqual(mirrored[8], original[5], "right_eye.vis ← left_eye.vis")
    }

    func test_mirror_swaps_left_shoulder_and_right_shoulder() {
        let original = makeDistinctArray()
        let mirrored = KeypointMirror.mirror(original)
        // left_shoulder=6 (offset 15) ↔ right_shoulder=7 (offset 18)
        let offL = (6 - 1) * 3
        let offR = (7 - 1) * 3
        XCTAssertEqual(mirrored[offL],     original[offR],     "left_shoulder.x ← right_shoulder.x")
        XCTAssertEqual(mirrored[offL + 1], original[offR + 1], "left_shoulder.y ← right_shoulder.y")
        XCTAssertEqual(mirrored[offL + 2], original[offR + 2], "left_shoulder.vis ← right_shoulder.vis")
        XCTAssertEqual(mirrored[offR],     original[offL],     "right_shoulder.x ← left_shoulder.x")
    }

    func test_mirror_swaps_all_8_pairs() {
        let original = makeDistinctArray()
        let mirrored = KeypointMirror.mirror(original)
        for (a, b) in KeypointMirror.pairs {
            let offA = (a - 1) * 3
            let offB = (b - 1) * 3
            XCTAssertEqual(mirrored[offA],     original[offB],     "pair(\(a),\(b)) x-swap")
            XCTAssertEqual(mirrored[offA + 1], original[offB + 1], "pair(\(a),\(b)) y-swap")
            XCTAssertEqual(mirrored[offA + 2], original[offB + 2], "pair(\(a),\(b)) vis-swap")
            XCTAssertEqual(mirrored[offB],     original[offA],     "pair(\(a),\(b)) reverse x-swap")
        }
    }

    // MARK: - Visibility travels with position

    func test_visibility_travels_with_position() {
        var arr = Array(repeating: 0.0, count: 51)
        // Place only left_eye (index 2) with visibility=occluded(1).
        let leftEyeOff = (2 - 1) * 3
        arr[leftEyeOff]     = 100.0
        arr[leftEyeOff + 1] = 200.0
        arr[leftEyeOff + 2] = 1.0 // occluded

        let mirrored = KeypointMirror.mirror(arr)

        // After mirror: right_eye slot (index 3, offset 6) should carry the occluded visibility.
        let rightEyeOff = (3 - 1) * 3
        XCTAssertEqual(mirrored[rightEyeOff],     100.0, "x moved to right_eye")
        XCTAssertEqual(mirrored[rightEyeOff + 1], 200.0, "y moved to right_eye")
        XCTAssertEqual(mirrored[rightEyeOff + 2], 1.0,   "occluded visibility travels with position")

        // Original left_eye slot should now have the zeros that were in right_eye.
        XCTAssertEqual(mirrored[leftEyeOff + 2], 0.0, "left_eye slot now has notLabeled")
    }

    // MARK: - Wrong length passthrough

    func test_mirror_returns_unchanged_when_not_51_elements() {
        let short = Array(repeating: 1.0, count: 50)
        XCTAssertEqual(KeypointMirror.mirror(short), short, "short array passthrough")

        let empty: [Double] = []
        XCTAssertEqual(KeypointMirror.mirror(empty), empty, "empty array passthrough")

        let long = Array(repeating: 1.0, count: 52)
        XCTAssertEqual(KeypointMirror.mirror(long), long, "long array passthrough")
    }

    // MARK: - Pairs constant sanity

    func test_pairs_constant_has_8_entries() {
        XCTAssertEqual(KeypointMirror.pairs.count, 8)
    }

    func test_pairs_are_all_distinct_1_based_indices() {
        var seen = Set<Int>()
        for (a, b) in KeypointMirror.pairs {
            XCTAssertFalse(seen.contains(a), "index \(a) appears in multiple pairs")
            XCTAssertFalse(seen.contains(b), "index \(b) appears in multiple pairs")
            XCTAssertGreaterThanOrEqual(a, 1)
            XCTAssertLessThanOrEqual(a, 17)
            XCTAssertGreaterThanOrEqual(b, 1)
            XCTAssertLessThanOrEqual(b, 17)
            seen.insert(a)
            seen.insert(b)
        }
    }

    func test_index_1_nose_not_in_any_pair() {
        for (a, b) in KeypointMirror.pairs {
            XCTAssertNotEqual(a, 1, "nose must not be in any mirror pair")
            XCTAssertNotEqual(b, 1, "nose must not be in any mirror pair")
        }
    }
}
