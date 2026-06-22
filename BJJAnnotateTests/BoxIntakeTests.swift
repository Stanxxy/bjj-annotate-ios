import XCTest
@testable import BJJAnnotate

/// T15 — Box-tool drag pipeline.
///
/// `BoxIntake` is the pure value-type that the canvas calls on gesture-end to
/// turn a drag start + drag end (in image-pixel coordinates) into either a
/// committed `BBox` or a rejection (sub-4px). The view layer is responsible for
/// converting view-local drag coordinates to image coordinates via
/// `CanvasTransform.viewToImage(...)` first.
///
/// AC #15 (Designer §3.3): Box tool draws a rectangle on the image.
/// AC #16 (Designer §3.3 + §3.4): a successful drag spawns one new instance.
/// AC #17: drag from any corner is supported (negative-direction normalized).
/// AC #19: rectangle clamped to image bounds — no negative w/h, no off-image
///         coordinates.
/// AC #20: drags whose normalized w OR h is < 4 image pixels are REJECTED and
///         the locked toast string is rendered (`LockedCopy.boxTooSmallToast`).
/// AC #25: drag-stage is held in `@State`, not the store — see
///         `DragStagingContractTests` for the store-side invariant. This file
///         covers the pure intake logic.
final class BoxIntakeTests: XCTestCase {

    // MARK: - Successful intake (AC #15, #16, #17, #19)

    func test_intake_lt_to_rb_drag_returns_normalized_bbox() throws {
        let result = BoxIntake.intake(
            start: CGPoint(x: 100, y: 200),
            end: CGPoint(x: 300, y: 400),
            imageSize: CGSize(width: 1920, height: 1080)
        )
        guard case .commit(let box) = result else {
            return XCTFail("expected commit, got \(result)")
        }
        XCTAssertEqual(box.x, 100, accuracy: 0.0001)
        XCTAssertEqual(box.y, 200, accuracy: 0.0001)
        XCTAssertEqual(box.w, 200, accuracy: 0.0001)
        XCTAssertEqual(box.h, 200, accuracy: 0.0001)
    }

    func test_intake_rb_to_lt_drag_is_normalized_to_positive_extent() throws {
        // Drag from bottom-right to top-left — w/h must come out positive.
        let result = BoxIntake.intake(
            start: CGPoint(x: 300, y: 400),
            end: CGPoint(x: 100, y: 200),
            imageSize: CGSize(width: 1920, height: 1080)
        )
        guard case .commit(let box) = result else { return XCTFail("expected commit") }
        XCTAssertEqual(box.x, 100, accuracy: 0.0001)
        XCTAssertEqual(box.y, 200, accuracy: 0.0001)
        XCTAssertEqual(box.w, 200, accuracy: 0.0001)
        XCTAssertEqual(box.h, 200, accuracy: 0.0001)
    }

    func test_intake_rt_to_lb_drag_is_normalized() throws {
        let result = BoxIntake.intake(
            start: CGPoint(x: 300, y: 100),
            end: CGPoint(x: 100, y: 400),
            imageSize: CGSize(width: 1920, height: 1080)
        )
        guard case .commit(let box) = result else { return XCTFail("expected commit") }
        XCTAssertEqual(box.x, 100, accuracy: 0.0001)
        XCTAssertEqual(box.y, 100, accuracy: 0.0001)
        XCTAssertEqual(box.w, 200, accuracy: 0.0001)
        XCTAssertEqual(box.h, 300, accuracy: 0.0001)
    }

    // MARK: - Image-bounds clamp (AC #19)

    func test_intake_clamps_negative_coordinates_to_zero() throws {
        let result = BoxIntake.intake(
            start: CGPoint(x: -50, y: -100),
            end: CGPoint(x: 200, y: 300),
            imageSize: CGSize(width: 1920, height: 1080)
        )
        guard case .commit(let box) = result else { return XCTFail("expected commit") }
        XCTAssertEqual(box.x, 0, accuracy: 0.0001)
        XCTAssertEqual(box.y, 0, accuracy: 0.0001)
        XCTAssertEqual(box.w, 200, accuracy: 0.0001)
        XCTAssertEqual(box.h, 300, accuracy: 0.0001)
    }

    func test_intake_clamps_overflow_coordinates_to_image_extent() throws {
        let result = BoxIntake.intake(
            start: CGPoint(x: 1800, y: 1000),
            end: CGPoint(x: 9999, y: 9999),
            imageSize: CGSize(width: 1920, height: 1080)
        )
        guard case .commit(let box) = result else { return XCTFail("expected commit") }
        XCTAssertEqual(box.x, 1800, accuracy: 0.0001)
        XCTAssertEqual(box.y, 1000, accuracy: 0.0001)
        XCTAssertEqual(box.x + box.w, 1920, accuracy: 0.0001,
                       "Right edge clamps to image width")
        XCTAssertEqual(box.y + box.h, 1080, accuracy: 0.0001,
                       "Bottom edge clamps to image height")
    }

    // MARK: - Sub-4px gate (AC #20)

    func test_intake_rejects_drag_with_w_below_4px() {
        let result = BoxIntake.intake(
            start: CGPoint(x: 100, y: 100),
            end: CGPoint(x: 103, y: 200),     // w = 3
            imageSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(result, .rejectTooSmall,
                       "AC #20: drags with w < 4 must reject")
    }

    func test_intake_rejects_drag_with_h_below_4px() {
        let result = BoxIntake.intake(
            start: CGPoint(x: 100, y: 100),
            end: CGPoint(x: 200, y: 103),     // h = 3
            imageSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(result, .rejectTooSmall)
    }

    func test_intake_accepts_drag_at_exactly_4px() {
        let result = BoxIntake.intake(
            start: CGPoint(x: 100, y: 100),
            end: CGPoint(x: 104, y: 104),     // w = h = 4
            imageSize: CGSize(width: 1920, height: 1080)
        )
        guard case .commit = result else {
            return XCTFail("AC #20 boundary: 4px must accept")
        }
    }

    func test_intake_rejects_zero_extent_tap() {
        // Tap with no drag at all — gestures occasionally fire onEnded with
        // start == end. AC #20 rejection wins.
        let result = BoxIntake.intake(
            start: CGPoint(x: 100, y: 100),
            end: CGPoint(x: 100, y: 100),
            imageSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(result, .rejectTooSmall)
    }

    // MARK: - 4px gate is post-clamp (defensive)

    /// If a drag crosses the image edge — say from (1, 100) to (1918, 200) on a
    /// 1920-wide image — the unclamped width is 1917, the clamped width is 1917
    /// (still in bounds). The gate is applied AFTER clamping so an off-image
    /// drag that produces a sub-4px clamped extent still rejects.
    func test_intake_4px_gate_applies_post_clamp() {
        // Drag from (1918, 100) to (1921, 200): unclamped w = 3, clamped x =
        // 1918, clamped end x = 1920 (the image extent), clamped w = 2 → reject.
        let result = BoxIntake.intake(
            start: CGPoint(x: 1918, y: 100),
            end: CGPoint(x: 1921, y: 200),
            imageSize: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(result, .rejectTooSmall,
                       "Post-clamp w < 4 still rejects")
    }
}
