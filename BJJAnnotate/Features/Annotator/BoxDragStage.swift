import CoreGraphics
import Foundation

/// Pure value-type drag-stage. Held in `@State` by `AnnotatorCanvasView` and
/// mutated in-place during a single-finger DragGesture in `.box` tool mode.
///
/// R-UI-2 contract: this state is view-local. The store is NEVER touched during
/// drag progress — only the gesture's `.onEnded` invokes
/// `BoxIntake.intake(...)` and (on success) `AnnotationStore.upsertBox(...)`.
/// See `DragStagingContractTests` for the store-side invariant.
struct BoxDragStage: Equatable {
    /// Drag-start point in IMAGE pixel coordinates (converted via
    /// `CanvasTransform.viewToImage(...)` at gesture-onChanged-first-event).
    var startImagePoint: CGPoint
    /// Live drag-end point in IMAGE pixel coordinates.
    var currentImagePoint: CGPoint

    /// Rect to render as the preview ghost while the user is still dragging.
    /// Normalizes positive extent so the preview tracks the gesture from any
    /// corner. Coordinates are in IMAGE pixels — the canvas re-transforms to
    /// view points via `CanvasTransform` when rendering the overlay.
    var previewRect: CGRect {
        let minX = min(startImagePoint.x, currentImagePoint.x)
        let minY = min(startImagePoint.y, currentImagePoint.y)
        let w = abs(startImagePoint.x - currentImagePoint.x)
        let h = abs(startImagePoint.y - currentImagePoint.y)
        return CGRect(x: minX, y: minY, width: w, height: h)
    }
}

/// Active tool. Phase 1 ships `.box` only — the keypoints slot is disabled
/// (AC #9 / `LockedCopy.keypointsDisabledTooltip`). T17 wires the chip row.
enum AnnotatorTool: Equatable {
    case box
    /// Reserved for T16 (selection / resize). Implemented as a separate gesture
    /// path on the same canvas.
    case select
    /// Phase 2; disabled in production.
    case keypoints
}
