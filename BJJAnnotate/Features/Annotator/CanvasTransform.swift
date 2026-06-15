import CoreGraphics
import Foundation

/// Pure value-type transform driver for `AnnotatorCanvasView`.
///
/// Owns the zoom + pan state and the clamping math. Separated from the SwiftUI
/// view so the geometry contract (AC #22) can be unit-tested without spinning a
/// `UIWindow`. The view holds a `CanvasTransform` in `@State` and mutates it from
/// gesture callbacks.
///
/// Clamping rules:
///   - Zoom is clamped to the closed range `[1.0, 8.0]`. Below 1.0× would
///     letterbox the image (Designer §3.2: 1.0× IS the fit-to-view default).
///     Above 8.0× crosses the legibility threshold for 2pt strokes (Designer
///     §3.2).
///   - Pan offset is clamped so the image never reveals more than the available
///     viewport on either side. At 1.0× zoom the image fills the view and pan
///     is a no-op.
struct CanvasTransform: Equatable {
    /// Committed zoom level. `1.0 ... 8.0` after `apply(pinch:)`.
    var zoom: CGFloat = 1.0
    /// Committed pan offset, in view points. Clamped against the visible image
    /// bounds at the current zoom.
    var offset: CGSize = .zero

    /// Snapshot of `zoom` at the start of a pinch gesture so that
    /// `apply(pinch:)` composes magnification multiplicatively. The view sets
    /// this via `commitZoom()` between gestures.
    private var pinchBase: CGFloat = 1.0

    static let minZoom: CGFloat = 1.0
    static let maxZoom: CGFloat = 8.0

    // MARK: - Zoom

    /// Applies a pinch magnification on top of the committed `pinchBase`. The
    /// magnification value comes from `MagnificationGesture` (`1.0` = no change).
    mutating func apply(pinch magnification: CGFloat) {
        let proposed = pinchBase * magnification
        zoom = min(Self.maxZoom, max(Self.minZoom, proposed))
    }

    /// Snapshots the current `zoom` as the new `pinchBase` for subsequent
    /// pinches. Called from the gesture's `.onEnded`.
    mutating func commitZoom() {
        pinchBase = zoom
    }

    // MARK: - Pan

    /// Applies an incremental pan translation, clamped against the visible image
    /// bounds at the current zoom.
    mutating func apply(panTranslation translation: CGSize, viewSize: CGSize, imageSize: CGSize) {
        if zoom <= 1.0 {
            // At fit-to-view there is nothing to pan.
            offset = .zero
            return
        }
        // The image at the current zoom is `viewSize * zoom`; the overhang
        // beyond the viewport on each side is `(zoom - 1) * viewSize / 2`.
        let halfOverhangX = (zoom - 1) * viewSize.width / 2
        let halfOverhangY = (zoom - 1) * viewSize.height / 2
        let proposedX = panBaseOffset.width + translation.width
        let proposedY = panBaseOffset.height + translation.height
        offset = CGSize(
            width: min(halfOverhangX, max(-halfOverhangX, proposedX)),
            height: min(halfOverhangY, max(-halfOverhangY, proposedY))
        )
        // Note: imageSize is currently unused; reserved for AC #22 non-square images.
        _ = imageSize
    }

    /// Snapshots `offset` as the new pan base. Called from gesture `.onEnded`.
    mutating func commitPan() {
        panBaseOffset = offset
    }

    private var panBaseOffset: CGSize = .zero

    // MARK: - Double-tap to fit

    /// Resets zoom to 1.0× and offset to zero (AC #22 double-tap-to-fit).
    mutating func doubleTapToFit() {
        zoom = 1.0
        pinchBase = 1.0
        offset = .zero
        panBaseOffset = .zero
    }

    // MARK: - Coordinate conversion

    /// Converts a view-local point (e.g. a drag location) into image-pixel
    /// coordinates. Used by `BoxDragStage` in T15 so the staged rectangle is
    /// always stored in image pixels regardless of zoom/pan.
    ///
    /// Implementation: the image is `scaledToFit` inside the view. We compute
    /// the letterboxed image rect at 1.0×, then back out the pan and zoom.
    func viewToImage(viewPoint: CGPoint, viewSize: CGSize, imageSize: CGSize) -> CGPoint {
        // The view shows the image at scale = min(view.w/image.w, view.h/image.h) * zoom.
        // At 1.0× the image is letterboxed.
        let baseScale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let renderedScale = baseScale * zoom
        let renderedW = imageSize.width * renderedScale
        let renderedH = imageSize.height * renderedScale
        // Image origin in view coords (centered, plus pan offset).
        let originX = (viewSize.width - renderedW) / 2 + offset.width
        let originY = (viewSize.height - renderedH) / 2 + offset.height
        // Convert.
        let imageX = (viewPoint.x - originX) / renderedScale
        let imageY = (viewPoint.y - originY) / renderedScale
        return CGPoint(x: imageX, y: imageY)
    }
}
