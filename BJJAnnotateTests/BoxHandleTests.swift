import XCTest
@testable import BJJAnnotate

/// T16 — Box selection + resize handles.
///
/// `BoxHandle` enumerates the 8 affordances (4 corners + 4 edge midpoints).
/// `BoxResize.apply(...)` computes the new rect given a handle drag delta in
/// image-pixel coordinates. `BoxResize.hitTest(...)` returns which handle (if
/// any) a tap landed on, given a touch-target radius in image pixels.
///
/// AC #18 (Designer §3.5): tap a box to select; render 4 corner + 4 edge handles;
/// drag any handle to resize; drag the body to move. No rotation. Resize keeps
/// the rect within image bounds (no negative w/h, no off-image).
final class BoxHandleTests: XCTestCase {

    // MARK: - Hit test (tap selects handle)

    func test_hitTest_corner_top_left() {
        let rect = BBox(x: 100, y: 200, w: 300, h: 400)
        let h = BoxResize.hitTest(touchPoint: CGPoint(x: 102, y: 198), rect: rect, radius: 20)
        XCTAssertEqual(h, .topLeft)
    }

    func test_hitTest_corner_bottom_right() {
        let rect = BBox(x: 100, y: 200, w: 300, h: 400)
        // Bottom-right corner is at (400, 600).
        let h = BoxResize.hitTest(touchPoint: CGPoint(x: 405, y: 595), rect: rect, radius: 20)
        XCTAssertEqual(h, .bottomRight)
    }

    func test_hitTest_edge_midpoint_top() {
        let rect = BBox(x: 100, y: 200, w: 300, h: 400)
        // Top edge midpoint at (250, 200).
        let h = BoxResize.hitTest(touchPoint: CGPoint(x: 250, y: 205), rect: rect, radius: 20)
        XCTAssertEqual(h, .topMid)
    }

    func test_hitTest_edge_midpoint_right() {
        let rect = BBox(x: 100, y: 200, w: 300, h: 400)
        // Right edge midpoint at (400, 400).
        let h = BoxResize.hitTest(touchPoint: CGPoint(x: 398, y: 402), rect: rect, radius: 20)
        XCTAssertEqual(h, .rightMid)
    }

    func test_hitTest_body_returns_nil() {
        let rect = BBox(x: 100, y: 200, w: 300, h: 400)
        // Smack in the middle.
        let h = BoxResize.hitTest(touchPoint: CGPoint(x: 250, y: 400), rect: rect, radius: 20)
        XCTAssertNil(h, "Body taps return nil so the caller can dispatch to move-rect")
    }

    func test_hitTest_outside_returns_nil() {
        let rect = BBox(x: 100, y: 200, w: 300, h: 400)
        let h = BoxResize.hitTest(touchPoint: CGPoint(x: 0, y: 0), rect: rect, radius: 20)
        XCTAssertNil(h)
    }

    // MARK: - Resize via corner handle

    func test_resize_top_left_drag_grows_rect_in_negative_direction() {
        let rect = BBox(x: 100, y: 200, w: 300, h: 400)
        let resized = BoxResize.apply(
            handle: .topLeft,
            rect: rect,
            translation: CGSize(width: -50, height: -30),
            imageSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(resized.x, 50, accuracy: 0.0001)
        XCTAssertEqual(resized.y, 170, accuracy: 0.0001)
        XCTAssertEqual(resized.w, 350, accuracy: 0.0001)
        XCTAssertEqual(resized.h, 430, accuracy: 0.0001)
    }

    func test_resize_bottom_right_drag_expands_extent() {
        let rect = BBox(x: 100, y: 200, w: 300, h: 400)
        let resized = BoxResize.apply(
            handle: .bottomRight,
            rect: rect,
            translation: CGSize(width: 50, height: 60),
            imageSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(resized.w, 350, accuracy: 0.0001)
        XCTAssertEqual(resized.h, 460, accuracy: 0.0001)
        XCTAssertEqual(resized.x, 100, accuracy: 0.0001)
        XCTAssertEqual(resized.y, 200, accuracy: 0.0001)
    }

    // MARK: - Resize via edge midpoint (constrained axis)

    func test_resize_top_mid_only_affects_y_and_h() {
        let rect = BBox(x: 100, y: 200, w: 300, h: 400)
        let resized = BoxResize.apply(
            handle: .topMid,
            rect: rect,
            translation: CGSize(width: 999, height: -50),  // x delta ignored
            imageSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(resized.x, 100, accuracy: 0.0001)
        XCTAssertEqual(resized.w, 300, accuracy: 0.0001)
        XCTAssertEqual(resized.y, 150, accuracy: 0.0001)
        XCTAssertEqual(resized.h, 450, accuracy: 0.0001)
    }

    func test_resize_right_mid_only_affects_w() {
        let rect = BBox(x: 100, y: 200, w: 300, h: 400)
        let resized = BoxResize.apply(
            handle: .rightMid,
            rect: rect,
            translation: CGSize(width: 25, height: 999),  // y delta ignored
            imageSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(resized.w, 325, accuracy: 0.0001)
        XCTAssertEqual(resized.y, 200, accuracy: 0.0001)
        XCTAssertEqual(resized.h, 400, accuracy: 0.0001)
    }

    // MARK: - Move (body drag)

    func test_move_translates_rect_without_changing_extent() {
        let rect = BBox(x: 100, y: 200, w: 300, h: 400)
        let moved = BoxResize.move(
            rect: rect,
            translation: CGSize(width: 40, height: -20),
            imageSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(moved.x, 140, accuracy: 0.0001)
        XCTAssertEqual(moved.y, 180, accuracy: 0.0001)
        XCTAssertEqual(moved.w, 300, accuracy: 0.0001)
        XCTAssertEqual(moved.h, 400, accuracy: 0.0001)
    }

    // MARK: - Clamping (AC #18 follows AC #19 constraints)

    func test_resize_clamps_negative_origin_to_zero() {
        let rect = BBox(x: 10, y: 10, w: 100, h: 100)
        let resized = BoxResize.apply(
            handle: .topLeft,
            rect: rect,
            translation: CGSize(width: -50, height: -50),  // x = -40, y = -40
            imageSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(resized.x, 0, accuracy: 0.0001)
        XCTAssertEqual(resized.y, 0, accuracy: 0.0001)
        XCTAssertEqual(resized.w, 110, accuracy: 0.0001)
        XCTAssertEqual(resized.h, 110, accuracy: 0.0001)
    }

    func test_resize_clamps_extent_to_image_bounds() {
        let rect = BBox(x: 1800, y: 1000, w: 100, h: 50)
        let resized = BoxResize.apply(
            handle: .bottomRight,
            rect: rect,
            translation: CGSize(width: 999, height: 999),
            imageSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(resized.x + resized.w, 1920, accuracy: 0.0001)
        XCTAssertEqual(resized.y + resized.h, 1080, accuracy: 0.0001)
    }

    func test_resize_never_inverts_extent_to_negative() {
        let rect = BBox(x: 100, y: 200, w: 300, h: 400)
        // Drag bottom-right WAY to the upper-left past the top-left corner.
        let resized = BoxResize.apply(
            handle: .bottomRight,
            rect: rect,
            translation: CGSize(width: -9999, height: -9999),
            imageSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertGreaterThanOrEqual(resized.w, 0, "resize never produces negative width")
        XCTAssertGreaterThanOrEqual(resized.h, 0, "resize never produces negative height")
    }

    func test_move_clamps_so_rect_stays_in_image() {
        let rect = BBox(x: 100, y: 200, w: 300, h: 400)
        let moved = BoxResize.move(
            rect: rect,
            translation: CGSize(width: 9999, height: 9999),
            imageSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(moved.x + moved.w, 1920, accuracy: 0.0001)
        XCTAssertEqual(moved.y + moved.h, 1080, accuracy: 0.0001)
    }
}
