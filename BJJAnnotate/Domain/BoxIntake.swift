import CoreGraphics
import Foundation

/// Pure-value box-tool intake helper.
///
/// The canvas converts the gesture's start + end into image-pixel coordinates
/// via `CanvasTransform.viewToImage(...)`, then hands them to `BoxIntake.intake`.
/// This helper:
///   1. Normalizes the two points into a positive-extent rect (AC #17 — drag
///      from any corner).
///   2. Clamps the rect to the image bounds (AC #19 — no off-image / negative
///      coordinates).
///   3. Applies the sub-4px gate POST-clamp (AC #20 — a drag whose clamped
///      width or height is < 4 image pixels is rejected; the canvas then
///      surfaces `LockedCopy.boxTooSmallToast`).
///
/// The view layer never builds a `BBoxIntent` directly; it always routes through
/// here. This is the second source-of-truth defense against AC #20: even if the
/// view's gesture filtering drifts (e.g. a future iPad pencil path), the gate
/// applies at the seam between view and store.
enum BoxIntake {
    /// Minimum accepted width / height in image pixels. Locked at 4 by AC #20.
    static let minimumExtent: CGFloat = 4

    /// Outcome of an intake attempt.
    enum Result: Equatable {
        /// Drag passed all gates. Caller can submit a `BBoxIntent(rect:)`.
        case commit(BBox)
        /// Drag's clamped width or height is below `minimumExtent`. UI renders
        /// `LockedCopy.boxTooSmallToast`.
        case rejectTooSmall
    }

    /// See file doc. `start` and `end` are in image-pixel coordinates already;
    /// `imageSize` is the source image's pixel size (used for clamping).
    static func intake(start: CGPoint, end: CGPoint, imageSize: CGSize) -> Result {
        // 1. Normalize positive extent.
        let minX = min(start.x, end.x)
        let maxX = max(start.x, end.x)
        let minY = min(start.y, end.y)
        let maxY = max(start.y, end.y)

        // 2. Clamp to image bounds. `max(0, ...)` for the origin and
        //    `min(imageSize.w/h, ...)` for the extent edge.
        let clampedMinX = max(0, minX)
        let clampedMinY = max(0, minY)
        let clampedMaxX = min(imageSize.width, maxX)
        let clampedMaxY = min(imageSize.height, maxY)

        let w = clampedMaxX - clampedMinX
        let h = clampedMaxY - clampedMinY

        // 3. Sub-4px gate, POST-clamp (AC #20).
        if w < minimumExtent || h < minimumExtent {
            return .rejectTooSmall
        }

        return .commit(BBox(x: Double(clampedMinX), y: Double(clampedMinY), w: Double(w), h: Double(h)))
    }
}
