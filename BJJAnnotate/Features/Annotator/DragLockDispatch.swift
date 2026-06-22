import Foundation

/// Pure dispatch helpers for the view-lock gesture routing in `AnnotatorCanvasView`.
///
/// Extracted so the lock decision logic is unit-testable without spinning a UIWindow
/// or a SwiftUI view hierarchy. `AnnotatorCanvasView` delegates to these functions
/// inside its gesture callbacks; tests drive them directly (Condition M1 from the
/// Phase 2 evaluator review).
///
/// Invariant: when `isViewLocked == true`, ALL single-finger drag events route to
/// `.pan` regardless of `tool` or hit-test result, and `keypointTapShouldProceed`
/// returns false. Pinch-zoom and double-tap-to-fit are NOT routed through here
/// (they always work regardless of lock state — handled at the gesture composition
/// level in `AnnotatorCanvasView.canvasContent`).
enum DragLockDispatch {

    /// The routing decision for a single-finger drag event.
    enum DragRoute: Equatable {
        /// Drag is a canvas pan (either locked, or empty-space in .select tool).
        case pan
        /// Drag should be processed by the active editing tool.
        case edit
        /// Drag is repositioning a keypoint dot (keypoints tool, start hit a dot).
        case repositionKeypoint
    }

    /// Returns which action the drag should take.
    ///
    /// - Parameters:
    ///   - isViewLocked: Current view-lock state.
    ///   - tool: Currently-active annotator tool.
    ///   - startHitsKeypoint: Whether the drag's start point landed within the
    ///     hit radius of a placed keypoint dot. Only meaningful when `tool == .keypoints`;
    ///     ignored for `.box` and `.select`.
    /// - Returns: `.pan` when locked (always); otherwise `.repositionKeypoint` when
    ///   the start hits a dot in keypoints mode, else `.edit`.
    static func route(
        isViewLocked: Bool,
        tool: AnnotatorTool,
        startHitsKeypoint: Bool = false
    ) -> DragRoute {
        guard !isViewLocked else { return .pan }
        switch tool {
        case .box, .select:
            return .edit
        case .keypoints:
            return startHitsKeypoint ? .repositionKeypoint : .edit
        }
    }

    /// Returns whether a keypoint tap should proceed to place/cycle a keypoint.
    ///
    /// - Parameter isViewLocked: Current view-lock state.
    /// - Returns: `false` when locked (tap is swallowed); `true` otherwise.
    static func keypointTapShouldProceed(isViewLocked: Bool) -> Bool {
        return !isViewLocked
    }
}
