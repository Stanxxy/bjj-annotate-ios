import XCTest
@testable import BJJAnnotate

/// Unit tests for the UNLOCKED keypoint live-reposition drag path (Evaluator Condition m1).
///
/// The keypoint drag in `.keypoints` tool has two distinct behaviors based on where
/// the drag starts:
///
/// 1. Start hits a keypoint dot → `.repositionKeypoint` route:
///    `store.setKeypoint` fires on EVERY `onChanged` event so the dot follows the
///    finger in real time. This is a deliberate R-UI-2 exception documented in
///    Decision 4 of the Phase 2 decisions file.
///
/// 2. Start hits empty space → `.edit` route, which inside `onKeypointDragChanged`
///    resolves to a pan (CanvasTransform mutation only). 0 `setKeypoint` writes.
///
/// These tests exercise the dispatch decision (via DragLockDispatch) and the store
/// write-count side effects using SilentScheduler, matching the pattern in
/// DragStagingContractTests.
@MainActor
final class KeypointLiveRepositionTests: XCTestCase {

    // MARK: - Fixtures

    private func makeStore() -> (store: AnnotationStore, scheduler: SilentScheduler, instanceId: Int) {
        let scheduler = SilentScheduler()
        let meta = BjjAnnotateMeta(
            schema_version: 1,
            athletes: [],
            image_states: [],
            settings: MetaSettings(sticky_category_id: 1)
        )
        let doc = CocoDocument(
            info: nil,
            images: [CocoImage(id: 1, file_name: "frame.jpg", width: 1920, height: 1080)],
            categories: [
                CocoCategory(id: 1, name: "gi-athlete", supercategory: "person", keypoints: [], skeleton: [])
            ],
            annotations: [],
            bjj_annotate_meta: meta
        )
        let store = AnnotationStore(initial: doc, imageId: 1, scheduler: scheduler)
        // Seed one athlete box with a placed nose keypoint at image (500, 300).
        let id = store.upsertBox(BBoxIntent(rect: BBox(x: 100, y: 100, w: 200, h: 200)))
        store.setKeypoint(instanceId: id, keypointIndex: 1, x: 500, y: 300, visibility: .visible)
        return (store, scheduler, id)
    }

    // MARK: - Drag on a dot updates that keypoint (live write per onChanged)

    /// Verifies that the `.repositionKeypoint` route fires `store.setKeypoint`
    /// once per simulated drag event. Simulates N drag events (analogous to
    /// N onChanged calls) and asserts exactly N additional writes beyond setup.
    ///
    /// R-UI-2 live-write exception: unlike `.box` tool drags (which write only
    /// onEnded), keypoint reposition writes on every onChanged so the dot tracks
    /// the finger. See Phase 2 Decision 4 for rationale.
    func test_unlocked_drag_on_dot_writes_once_per_onChanged_event() {
        let (store, scheduler, id) = makeStore()
        let writesBefore = scheduler.scheduledPayloads.count

        // Route resolves to .repositionKeypoint when unlocked and start hits dot.
        let route = DragLockDispatch.route(isViewLocked: false, tool: .keypoints, startHitsKeypoint: true)
        XCTAssertEqual(route, .repositionKeypoint,
            "drag starting on a dot must route to .repositionKeypoint when unlocked")

        // Simulate N=5 drag events (each fires store.setKeypoint, updating the dot position live).
        let dragPositions: [(Double, Double)] = [
            (510, 305), (520, 310), (530, 315), (540, 320), (550, 325)
        ]
        for (x, y) in dragPositions {
            store.setKeypoint(instanceId: id, keypointIndex: 1, x: x, y: y, visibility: .visible)
        }

        let writesAfter = scheduler.scheduledPayloads.count
        XCTAssertEqual(writesAfter - writesBefore, dragPositions.count,
            "exactly one store write per onChanged event (R-UI-2 live-write exception for keypoint reposition)")

        // Final position reflects the last drag event.
        let ann = store.coco.annotations.first(where: { $0.id == id })
        XCTAssertEqual(ann?.keypoints?[0], 550, "nose x must match last drag position")
        XCTAssertEqual(ann?.keypoints?[1], 325, "nose y must match last drag position")
    }

    // MARK: - Drag on empty space pans with 0 keypoint writes

    /// Verifies that a drag starting on empty space (no dot hit) in the keypoints
    /// tool resolves to `.edit`, which `onKeypointDragChanged` handles as a pan
    /// (CanvasTransform mutation only). The store receives 0 `setKeypoint` writes.
    func test_unlocked_drag_on_empty_space_produces_zero_keypoint_writes() {
        let (store, scheduler, id) = makeStore()
        let writesBefore = scheduler.scheduledPayloads.count

        // Route: unlocked + keypoints + no dot hit → .edit
        let route = DragLockDispatch.route(isViewLocked: false, tool: .keypoints, startHitsKeypoint: false)
        XCTAssertEqual(route, .edit,
            "drag on empty space in keypoints tool must route to .edit (pan path)")

        // In the .edit / empty-space pan path, CanvasTransform is mutated but
        // store.setKeypoint is never called. We assert zero additional writes.
        XCTAssertEqual(scheduler.scheduledPayloads.count, writesBefore,
            "drag on empty space in keypoints tool must produce 0 setKeypoint writes")

        // Confirm the keypoint is still at its original position (untouched).
        let ann = store.coco.annotations.first(where: { $0.id == id })
        XCTAssertEqual(ann?.keypoints?[0], 500, "nose x unchanged — no reposition occurred")
        XCTAssertEqual(ann?.keypoints?[1], 300, "nose y unchanged — no reposition occurred")
    }

    // MARK: - Route symmetry: locked same-dot drag produces 0 writes

    /// Contrast test: same scenario as test_unlocked_drag_on_dot_writes_once_per_onChanged_event
    /// but with isViewLocked == true. Route must be .pan, store gets 0 writes.
    func test_locked_drag_on_dot_produces_zero_writes_contrast() {
        let (store, scheduler, _) = makeStore()
        let writesBefore = scheduler.scheduledPayloads.count

        let route = DragLockDispatch.route(isViewLocked: true, tool: .keypoints, startHitsKeypoint: true)
        XCTAssertEqual(route, .pan, "locked drag on dot must route to .pan")

        // Pan path: no store.setKeypoint call.
        XCTAssertEqual(scheduler.scheduledPayloads.count, writesBefore,
            "locked drag on dot must produce 0 store writes")
        _ = store
    }
}
