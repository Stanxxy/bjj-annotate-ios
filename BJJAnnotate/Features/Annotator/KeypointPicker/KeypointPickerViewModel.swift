import Foundation

/// View-model for the keypoint picker. Tracks the active keypoint index and
/// auto-advances to the next unplaced point after each tap.
///
/// Active-point advance logic (spec):
/// - Scan forward from current+1 within the group for the next unplaced point.
/// - If current is at the group end, wrap and scan from the group start (catches
///   skipped rows in out-of-order placement per US-3).
/// - If the entire group is placed, stay on the last point of that group.
///   (Cross-group advance is NOT performed — the picker stays within the active
///   group until the user explicitly selects a different group row.)
/// - Groups: Head = 1–5, Arms = 6–11, Legs = 12–17.
final class KeypointPickerViewModel: ObservableObject {

    /// Currently-active keypoint index (1-based, 1 = nose … 17 = right_ankle).
    @Published var activeKeypointIndex: Int = 1

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

        // Phase 1: scan forward within the group from current+1.
        // Guard required: if active is already at upperBound, (active+1)...upperBound
        // would be an invalid range (lowerBound > upperBound) and crash.
        let scanStart = activeKeypointIndex + 1
        if scanStart <= group.upperBound {
            for candidate in scanStart...group.upperBound where !isPlaced(index: candidate, in: kps) {
                activeKeypointIndex = candidate
                return
            }
        }

        // Phase 2: wrap-around scan from the group start to catch skipped rows
        // (handles out-of-order placement per US-3: skip row 4, place row 5 →
        // next active is row 4, not row 6).
        for candidate in group.lowerBound...group.upperBound where !isPlaced(index: candidate, in: kps) {
            activeKeypointIndex = candidate
            return
        }

        // Current group fully placed — stay on the last point of current group.
        // Cross-group advance is intentionally omitted: the picker stays within
        // the active group until the user taps a different group row.
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
