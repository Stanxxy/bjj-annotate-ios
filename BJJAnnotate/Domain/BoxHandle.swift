import CoreGraphics
import Foundation

/// The 8 resize affordances rendered around a selected box.
/// 4 corners + 4 edge midpoints. No rotation (PM AC #18; the canvas does not
/// recognize a rotation gesture).
enum BoxHandle: CaseIterable, Equatable {
    case topLeft, topMid, topRight
    case leftMid, rightMid
    case bottomLeft, bottomMid, bottomRight
}

/// Pure-value resize math. The canvas hands `BoxResize` the active handle, the
/// box's current rect, the drag translation in IMAGE pixels, and the source
/// image's pixel size. Returns a clamped, non-inverted rect.
///
/// All inputs and outputs are image-pixel coordinates. The canvas converts
/// view-points to image-points via `CanvasTransform.viewToImage(...)` first.
enum BoxResize {
    /// Hit test: returns which handle a tap lands on, or `nil` if the tap was
    /// inside the body (caller dispatches to `move(...)`) or outside the rect.
    /// `radius` is the touch-target radius in IMAGE pixels (the caller scales
    /// by the current zoom so the on-screen target stays a constant 44pt).
    static func hitTest(touchPoint: CGPoint, rect: BBox, radius: CGFloat) -> BoxHandle? {
        let points = handlePoints(rect: rect)
        for (handle, point) in points {
            let dx = touchPoint.x - point.x
            let dy = touchPoint.y - point.y
            if dx * dx + dy * dy <= radius * radius {
                return handle
            }
        }
        // No handle hit. Body or outside?
        let bodyRect = CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h)
        if bodyRect.contains(touchPoint) {
            return nil  // body — caller dispatches to move(...)
        }
        return nil
    }

    /// Returns the [handle: point] map in image pixels.
    static func handlePoints(rect: BBox) -> [(BoxHandle, CGPoint)] {
        let minX = CGFloat(rect.x)
        let minY = CGFloat(rect.y)
        let midX = CGFloat(rect.x + rect.w / 2)
        let midY = CGFloat(rect.y + rect.h / 2)
        let maxX = CGFloat(rect.x + rect.w)
        let maxY = CGFloat(rect.y + rect.h)
        return [
            (.topLeft, CGPoint(x: minX, y: minY)),
            (.topMid, CGPoint(x: midX, y: minY)),
            (.topRight, CGPoint(x: maxX, y: minY)),
            (.leftMid, CGPoint(x: minX, y: midY)),
            (.rightMid, CGPoint(x: maxX, y: midY)),
            (.bottomLeft, CGPoint(x: minX, y: maxY)),
            (.bottomMid, CGPoint(x: midX, y: maxY)),
            (.bottomRight, CGPoint(x: maxX, y: maxY)),
        ]
    }

    /// Returns a new rect resized by `translation` relative to the dragged
    /// handle. Edge midpoint handles constrain to a single axis. The output
    /// rect is clamped to the image and never has negative extent.
    static func apply(handle: BoxHandle, rect: BBox, translation: CGSize, imageSize: CGSize) -> BBox {
        // Compute candidate corners.
        var minX = rect.x
        var minY = rect.y
        var maxX = rect.x + rect.w
        var maxY = rect.y + rect.h

        let dx = Double(translation.width)
        let dy = Double(translation.height)

        switch handle {
        case .topLeft:    minX += dx; minY += dy
        case .topMid:     minY += dy
        case .topRight:   maxX += dx; minY += dy
        case .leftMid:    minX += dx
        case .rightMid:   maxX += dx
        case .bottomLeft: minX += dx; maxY += dy
        case .bottomMid:  maxY += dy
        case .bottomRight: maxX += dx; maxY += dy
        }

        // No extent inversion: if drag pulled past the opposite edge, collapse to 0.
        if maxX < minX { swap(&minX, &maxX) }
        if maxY < minY { swap(&minY, &maxY) }

        // Clamp to image bounds.
        minX = max(0, min(imageSize.width, minX))
        minY = max(0, min(imageSize.height, minY))
        maxX = max(0, min(imageSize.width, maxX))
        maxY = max(0, min(imageSize.height, maxY))

        return BBox(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
    }

    /// Translates the entire rect by `translation`, clamping so the rect stays
    /// fully inside the image. The rect's extent is preserved.
    static func move(rect: BBox, translation: CGSize, imageSize: CGSize) -> BBox {
        var newX = rect.x + Double(translation.width)
        var newY = rect.y + Double(translation.height)
        // Clamp so newX + w <= image.w and newY + h <= image.h.
        newX = max(0, min(imageSize.width - rect.w, newX))
        newY = max(0, min(imageSize.height - rect.h, newY))
        return BBox(x: newX, y: newY, w: rect.w, h: rect.h)
    }
}
