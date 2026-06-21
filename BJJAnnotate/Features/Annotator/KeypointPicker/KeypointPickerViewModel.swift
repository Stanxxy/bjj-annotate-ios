import Foundation
import Observation

/// View-model for the keypoint picker. Tracks the active keypoint index and
/// auto-advances to the next unplaced point after each tap.
///
/// Active-point advance logic (spec):
/// - After placing a keypoint, advance to the next unplaced point within the
///   same group (Head / Arms / Legs). If all points in the current group are
///   placed, stay on the last point of that group.
/// - Groups: Head = 1–5, Arms = 6–11, Legs = 12–17.
@Observable
final class KeypointPickerViewModel {

    /// Currently-active keypoint index (1-based, 1 = nose … 17 = right_ankle).
    var activeKeypointIndex: Int = 1

    // MARK: - Keypoint group membership

    private static func group(for index: Int) -> ClosedRange<Int> {
        switch index {
        case 1...5:  return 1...5
        case 6...11: return 6...11
        default:     return 12...17
        }
    }

    // MARK: - Auto-advance

    /// Advances `activeKeypointIndex` to the next unplaced point in the current group.
    ///
    /// "Placed" means `KPVisibility.rawValue > 0` at the corresponding offset in
    /// the flat keypoints array of `instanceId`.
    ///
    /// - Parameters:
    ///   - annotations: The full annotation list for the current image.
    ///   - instanceId: The athlete instance whose keypoints drive the advance.
    ///     If nil, no advance is performed.
    func advance(in annotations: [CocoAnnotation], for instanceId: Int?) {
        guard let instanceId else { return }
        guard let ann = annotations.first(where: { $0.id == instanceId }) else { return }
        let kps = ann.keypoints ?? []

        let group = Self.group(for: activeKeypointIndex)

        // Scan forward from the current index + 1 to the end of the group.
        for candidate in (activeKeypointIndex + 1)...group.upperBound {
            if candidate > 17 { break }
            if !isPlaced(index: candidate, in: kps) {
                activeKeypointIndex = candidate
                return
            }
        }
        // If all remaining points in the group are placed, stay on the last.
        activeKeypointIndex = group.upperBound
    }

    // MARK: - Helpers

    /// Returns `true` when the keypoint at the given 1-based index has a
    /// visibility value > 0 in the flat array (i.e. it has been placed).
    func isPlaced(index: Int, in keypoints: [Double]) -> Bool {
        guard keypoints.count == 51 else { return false }
        let offset = (index - 1) * 3
        return keypoints[offset + 2] > 0
    }
}
