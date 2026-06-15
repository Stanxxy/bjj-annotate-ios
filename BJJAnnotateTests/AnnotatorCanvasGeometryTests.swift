import XCTest
@testable import BJJAnnotate

/// T14 — AnnotatorCanvasView geometry contract.
///
/// AC #22 (Designer §3.2): the canvas supports
///   - Pinch zoom in the closed range `[1.0, 8.0]`
///   - Two-finger pan when zoomed in (no-op at 1.0×)
///   - Double-tap to fit (returns to 1.0× and zero offset)
///
/// Gesture wiring lives in SwiftUI; the math (clamping, fit reset, image-to-view
/// transform) is extracted into `CanvasTransform` so it can be unit-tested
/// without spinning a `UIWindow`.
///
/// The gesture-driven XCUITest landing in T24 covers the SwiftUI surface.
final class AnnotatorCanvasGeometryTests: XCTestCase {

    // MARK: - Zoom clamping (AC #22)

    func test_zoom_clamps_at_lower_bound_1x() {
        var t = CanvasTransform()
        t.apply(pinch: 0.5)
        XCTAssertEqual(t.zoom, 1.0, accuracy: 0.0001, "Pinch < 1.0 clamps to 1.0×")
    }

    func test_zoom_clamps_at_upper_bound_8x() {
        var t = CanvasTransform()
        t.apply(pinch: 12.0)
        XCTAssertEqual(t.zoom, 8.0, accuracy: 0.0001, "Pinch > 8.0 clamps to 8.0×")
    }

    func test_zoom_accepts_inrange_values() {
        var t = CanvasTransform()
        t.apply(pinch: 2.5)
        XCTAssertEqual(t.zoom, 2.5, accuracy: 0.0001)
    }

    func test_pinch_composition_multiplies_from_committed_base() {
        var t = CanvasTransform()
        t.apply(pinch: 2.0)
        t.commitZoom()
        t.apply(pinch: 1.5)  // 2.0 base * 1.5 = 3.0
        XCTAssertEqual(t.zoom, 3.0, accuracy: 0.0001,
                       "Pinch composes from the committed zoom, not from 1.0×")
    }

    // MARK: - Pan (AC #22)

    func test_pan_is_noop_at_1x_zoom() {
        var t = CanvasTransform()
        t.apply(panTranslation: CGSize(width: 200, height: 200), viewSize: CGSize(width: 400, height: 400), imageSize: CGSize(width: 400, height: 400))
        XCTAssertEqual(t.offset, .zero,
                       "At 1.0× zoom the image fills the viewport — pan has no effect")
    }

    func test_pan_translates_when_zoomed_in() {
        var t = CanvasTransform()
        t.apply(pinch: 2.0)
        t.commitZoom()
        t.apply(panTranslation: CGSize(width: 50, height: 30),
                viewSize: CGSize(width: 400, height: 400),
                imageSize: CGSize(width: 400, height: 400))
        XCTAssertEqual(t.offset.width, 50, accuracy: 0.0001)
        XCTAssertEqual(t.offset.height, 30, accuracy: 0.0001)
    }

    func test_pan_clamps_within_zoomed_bounds() {
        var t = CanvasTransform()
        t.apply(pinch: 2.0)
        t.commitZoom()
        // At 2.0× zoom on a 400×400 view of a 400×400 image, the half-overhang on
        // each side is (2.0 - 1) * 400 / 2 = 200pt. A pan of 9999 must clamp to 200.
        t.apply(panTranslation: CGSize(width: 9999, height: 9999),
                viewSize: CGSize(width: 400, height: 400),
                imageSize: CGSize(width: 400, height: 400))
        XCTAssertEqual(t.offset.width, 200, accuracy: 0.0001,
                       "Pan clamps to the visible image bounds at the current zoom")
        XCTAssertEqual(t.offset.height, 200, accuracy: 0.0001)
    }

    // MARK: - Double-tap to fit (AC #22)

    func test_doubleTapToFit_resets_zoom_to_1x_and_offset_to_zero() {
        var t = CanvasTransform()
        t.apply(pinch: 4.0)
        t.commitZoom()
        t.apply(panTranslation: CGSize(width: 50, height: 50),
                viewSize: CGSize(width: 400, height: 400),
                imageSize: CGSize(width: 400, height: 400))

        t.doubleTapToFit()

        XCTAssertEqual(t.zoom, 1.0, accuracy: 0.0001)
        XCTAssertEqual(t.offset, .zero)
    }

    // MARK: - Image-to-view coordinate conversion (used by T15 drag-stage)

    func test_view_to_image_at_1x_is_identity_minus_letterbox() {
        // 800×400 image rendered inside 400×400 view: scale 0.5, vertical letterbox 100pt.
        let t = CanvasTransform()
        let p = t.viewToImage(viewPoint: CGPoint(x: 200, y: 200),
                              viewSize: CGSize(width: 400, height: 400),
                              imageSize: CGSize(width: 800, height: 400))
        // The image is 0.5x rendered into the view; view center maps to image center.
        XCTAssertEqual(p.x, 400, accuracy: 0.5)
        XCTAssertEqual(p.y, 200, accuracy: 0.5)
    }
}
