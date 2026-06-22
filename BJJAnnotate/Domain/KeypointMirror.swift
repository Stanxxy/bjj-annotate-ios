import Foundation

/// Pure value-type L↔R keypoint mirror.
///
/// No UI dependencies, no @Observable. Operates entirely on the flat 51-element
/// COCO keypoints array (`[x, y, v, x, y, v, ...]` for 17 keypoints).
///
/// Contract: `mirror(mirror(x)) == x` — the operation is an involution.
/// Nose (index 1) is center and is never swapped.
/// Visibility flags travel with the position they were assigned to.
struct KeypointMirror {

    /// All 8 L↔R mirror pairs, expressed as 1-based keypoint indices.
    static let pairs: [(Int, Int)] = [
        (2, 3),   // left_eye   ↔ right_eye
        (4, 5),   // left_ear   ↔ right_ear
        (6, 7),   // left_shoulder ↔ right_shoulder
        (8, 9),   // left_elbow ↔ right_elbow
        (10, 11), // left_wrist ↔ right_wrist
        (12, 13), // left_hip   ↔ right_hip
        (14, 15), // left_knee  ↔ right_knee
        (16, 17), // left_ankle ↔ right_ankle
    ]

    /// Swaps all 8 L↔R pairs in the flat 51-element keypoints array.
    ///
    /// - Parameter keypoints: A 51-element array `[x1,y1,v1, x2,y2,v2, ...]`.
    ///   If the array is not exactly 51 elements the function returns it unchanged.
    /// - Returns: A new array with paired keypoints swapped.
    static func mirror(_ keypoints: [Double]) -> [Double] {
        guard keypoints.count == 51 else { return keypoints }
        var result = keypoints
        for (a, b) in pairs {
            let offA = (a - 1) * 3
            let offB = (b - 1) * 3
            // Swap all three elements (x, y, visibility) as a unit.
            let (ax, ay, av) = (result[offA], result[offA + 1], result[offA + 2])
            let (bx, by, bv) = (result[offB], result[offB + 1], result[offB + 2])
            result[offA]     = bx
            result[offA + 1] = by
            result[offA + 2] = bv
            result[offB]     = ax
            result[offB + 1] = ay
            result[offB + 2] = av
        }
        return result
    }
}
