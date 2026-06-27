import XCTest
import Combine
@testable import BJJAnnotate

/// Tests for `AnnotationStore` Phase 2 keypoint mutations:
/// `setKeypoint`, `cycleKeypointVisibility`, `mirrorKeypoints`.
///
/// Uses `SilentScheduler` (no disk I/O). All tests follow the same pattern
/// as `AnnotationStoreTests`: real domain structs, no mocks of the store.
@MainActor
final class AnnotationStoreKeypointTests: XCTestCase {

    // MARK: - Fixtures

    private static let imageId = 1

    private func makeStore(categoryId: Int = 1) -> (store: AnnotationStore, instanceId: Int) {
        let meta = BjjAnnotateMeta(
            schema_version: 1,
            athletes: [],
            image_states: [],
            settings: MetaSettings(sticky_category_id: categoryId)
        )
        let doc = CocoDocument(
            info: nil,
            images: [CocoImage(id: Self.imageId, file_name: "frame.jpg", width: 1920, height: 1080)],
            categories: Self.categories(),
            annotations: [],
            bjj_annotate_meta: meta
        )
        let store = AnnotationStore(initial: doc, imageId: Self.imageId, scheduler: SilentScheduler())
        let id = store.upsertBox(BBoxIntent(rect: BBox(x: 100, y: 100, w: 200, h: 200)))
        // Switch category if needed.
        if categoryId != 1 {
            if categoryId == 3 {
                store.setClass(instanceId: id, category: .ref)
            } else if categoryId == 2 {
                store.setClass(instanceId: id, category: .nogi)
            }
        }
        return (store, id)
    }

    private static func categories() -> [CocoCategory] {
        [
            CocoCategory(id: 1, name: "gi-athlete", supercategory: "person", keypoints: [], skeleton: []),
            CocoCategory(id: 2, name: "nogi-athlete", supercategory: "person", keypoints: [], skeleton: []),
            CocoCategory(id: 3, name: "referee", supercategory: "person", keypoints: nil, skeleton: nil),
        ]
    }

    // MARK: - setKeypoint — basic placement

    func test_setKeypoint_places_keypoint_in_flat_array() {
        let (store, id) = makeStore()
        store.setKeypoint(instanceId: id, keypointIndex: 1, x: 100.0, y: 200.0, visibility: .visible)

        let ann = store.coco.annotations.first(where: { $0.id == id })
        let kps = ann?.keypoints
        XCTAssertNotNil(kps)
        XCTAssertEqual(kps?.count, 51, "keypoints array must be 51 elements")
        XCTAssertEqual(kps?[0], 100.0, "nose x")
        XCTAssertEqual(kps?[1], 200.0, "nose y")
        XCTAssertEqual(kps?[2], Double(KPVisibility.visible.rawValue), "nose visibility")
    }

    func test_setKeypoint_for_index_17_sets_last_triplet() {
        let (store, id) = makeStore()
        store.setKeypoint(instanceId: id, keypointIndex: 17, x: 50.0, y: 75.0, visibility: .occluded)

        let ann = store.coco.annotations.first(where: { $0.id == id })
        let kps = ann?.keypoints
        XCTAssertEqual(kps?.count, 51)
        XCTAssertEqual(kps?[48], 50.0,  "right_ankle x")
        XCTAssertEqual(kps?[49], 75.0,  "right_ankle y")
        XCTAssertEqual(kps?[50], Double(KPVisibility.occluded.rawValue), "right_ankle visibility")
    }

    func test_setKeypoint_updates_num_keypoints() {
        let (store, id) = makeStore()
        store.setKeypoint(instanceId: id, keypointIndex: 1, x: 10, y: 20, visibility: .visible)
        store.setKeypoint(instanceId: id, keypointIndex: 2, x: 30, y: 40, visibility: .occluded)

        let ann = store.coco.annotations.first(where: { $0.id == id })
        XCTAssertEqual(ann?.num_keypoints, 2, "both placed points count")
    }

    func test_setKeypoint_notLabeled_does_not_increment_num_keypoints() {
        let (store, id) = makeStore()
        store.setKeypoint(instanceId: id, keypointIndex: 1, x: 10, y: 20, visibility: .notLabeled)

        let ann = store.coco.annotations.first(where: { $0.id == id })
        XCTAssertEqual(ann?.num_keypoints, 0, "notLabeled not counted")
    }

    // MARK: - setKeypoint — referee guard

    func test_setKeypoint_ignores_referee_instance() {
        let (store, id) = makeStore(categoryId: 3)

        let before = store.coco.annotations.first(where: { $0.id == id })?.keypoints
        store.setKeypoint(instanceId: id, keypointIndex: 1, x: 50, y: 50, visibility: .visible)
        let after = store.coco.annotations.first(where: { $0.id == id })?.keypoints

        XCTAssertEqual(before, after, "referee keypoints must not be modified")
    }

    // MARK: - setKeypoint — array always 51 elements

    func test_setKeypoint_resizes_empty_array_to_51() {
        let (store, id) = makeStore()
        // Immediately after upsertBox, keypoints is [] (empty).
        let before = store.coco.annotations.first(where: { $0.id == id })?.keypoints
        XCTAssertEqual(before?.count ?? -1, 0, "starts as empty array")

        store.setKeypoint(instanceId: id, keypointIndex: 5, x: 1, y: 2, visibility: .visible)
        let after = store.coco.annotations.first(where: { $0.id == id })?.keypoints
        XCTAssertEqual(after?.count, 51, "array padded to 51 after first setKeypoint")
    }

    // MARK: - setKeypoint — AC #4 single invalidation

    func test_setKeypoint_emits_exactly_one_observation_invalidation() {
        let (store, id) = makeStore()
        let count = Locked2<Int>(0)
        var cancellables = Set<AnyCancellable>()
        store.objectWillChange.sink { count.increment() }
            .store(in: &cancellables)
        store.setKeypoint(instanceId: id, keypointIndex: 3, x: 50, y: 60, visibility: .visible)
        let exp = XCTestExpectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(count.value, 1, "exactly one observation invalidation per mutation")
    }

    // MARK: - cycleKeypointVisibility

    func test_cycle_notLabeled_to_visible() {
        let (store, id) = makeStore()
        // Ensure fresh 51-element array.
        store.setKeypoint(instanceId: id, keypointIndex: 1, x: 10, y: 20, visibility: .visible)
        // Reset nose to notLabeled.
        store.setKeypoint(instanceId: id, keypointIndex: 1, x: 10, y: 20, visibility: .notLabeled)

        store.cycleKeypointVisibility(instanceId: id, keypointIndex: 1)
        let ann = store.coco.annotations.first(where: { $0.id == id })
        XCTAssertEqual(Int(ann?.keypoints?[2] ?? -1), KPVisibility.visible.rawValue)
    }

    func test_cycle_visible_to_occluded() {
        let (store, id) = makeStore()
        store.setKeypoint(instanceId: id, keypointIndex: 2, x: 30, y: 40, visibility: .visible)
        store.cycleKeypointVisibility(instanceId: id, keypointIndex: 2)

        let ann = store.coco.annotations.first(where: { $0.id == id })
        let off = (2 - 1) * 3
        XCTAssertEqual(Int(ann?.keypoints?[off + 2] ?? -1), KPVisibility.occluded.rawValue)
    }

    func test_cycle_occluded_to_notLabeled() {
        let (store, id) = makeStore()
        store.setKeypoint(instanceId: id, keypointIndex: 3, x: 50, y: 60, visibility: .occluded)
        store.cycleKeypointVisibility(instanceId: id, keypointIndex: 3)

        let ann = store.coco.annotations.first(where: { $0.id == id })
        let off = (3 - 1) * 3
        XCTAssertEqual(Int(ann?.keypoints?[off + 2] ?? -1), KPVisibility.notLabeled.rawValue)
    }

    func test_cycleKeypointVisibility_ignores_referee() {
        let (store, id) = makeStore(categoryId: 3)
        let before = store.coco.annotations.first(where: { $0.id == id })?.keypoints
        store.cycleKeypointVisibility(instanceId: id, keypointIndex: 1)
        let after = store.coco.annotations.first(where: { $0.id == id })?.keypoints
        XCTAssertEqual(before, after, "referee keypoints must not be touched")
    }

    func test_cycleKeypointVisibility_emits_exactly_one_observation_invalidation() {
        let (store, id) = makeStore()
        store.setKeypoint(instanceId: id, keypointIndex: 1, x: 10, y: 20, visibility: .visible)
        let count = Locked2<Int>(0)
        var cancellables = Set<AnyCancellable>()
        store.objectWillChange.sink { count.increment() }
            .store(in: &cancellables)
        store.cycleKeypointVisibility(instanceId: id, keypointIndex: 1)
        let exp = XCTestExpectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(count.value, 1)
    }

    // MARK: - mirrorKeypoints

    func test_mirrorKeypoints_swaps_left_right_pairs() {
        let (store, id) = makeStore()
        // Place left_shoulder (6) and right_shoulder (7).
        store.setKeypoint(instanceId: id, keypointIndex: 6, x: 100, y: 200, visibility: .visible)
        store.setKeypoint(instanceId: id, keypointIndex: 7, x: 300, y: 400, visibility: .occluded)

        store.mirrorKeypoints(instanceId: id)

        let ann = store.coco.annotations.first(where: { $0.id == id })
        let kps = ann?.keypoints ?? []
        let offL = (6 - 1) * 3
        let offR = (7 - 1) * 3
        XCTAssertEqual(kps[offL],     300.0, "left_shoulder.x now has right_shoulder.x")
        XCTAssertEqual(kps[offL + 1], 400.0, "left_shoulder.y now has right_shoulder.y")
        XCTAssertEqual(kps[offL + 2], Double(KPVisibility.occluded.rawValue), "left_shoulder.vis from right_shoulder.vis")
        XCTAssertEqual(kps[offR],     100.0, "right_shoulder.x now has left_shoulder.x")
        XCTAssertEqual(kps[offR + 1], 200.0, "right_shoulder.y now has left_shoulder.y")
        XCTAssertEqual(kps[offR + 2], Double(KPVisibility.visible.rawValue), "right_shoulder.vis from left_shoulder.vis")
    }

    func test_mirrorKeypoints_is_involution() {
        let (store, id) = makeStore()
        for i in 1...17 {
            store.setKeypoint(instanceId: id, keypointIndex: i, x: Double(i * 7), y: Double(i * 13), visibility: .visible)
        }
        let before = store.coco.annotations.first(where: { $0.id == id })?.keypoints ?? []
        store.mirrorKeypoints(instanceId: id)
        store.mirrorKeypoints(instanceId: id)
        let after = store.coco.annotations.first(where: { $0.id == id })?.keypoints ?? []
        XCTAssertEqual(before, after, "mirror(mirror(x)) == x in the store")
    }

    func test_mirrorKeypoints_ignores_referee() {
        let (store, id) = makeStore(categoryId: 3)
        let before = store.coco.annotations.first(where: { $0.id == id })?.keypoints
        store.mirrorKeypoints(instanceId: id)
        let after = store.coco.annotations.first(where: { $0.id == id })?.keypoints
        XCTAssertEqual(before, after, "referee keypoints not touched")
    }

    func test_mirrorKeypoints_emits_exactly_one_observation_invalidation() {
        let (store, id) = makeStore()
        // Place a left/right pair so the mirror genuinely changes the array.
        store.setKeypoint(instanceId: id, keypointIndex: 6, x: 100, y: 200, visibility: .visible) // left_shoulder
        store.setKeypoint(instanceId: id, keypointIndex: 7, x: 300, y: 400, visibility: .occluded) // right_shoulder
        let count = Locked2<Int>(0)
        var cancellables = Set<AnyCancellable>()
        store.objectWillChange.sink { count.increment() }
            .store(in: &cancellables)
        store.mirrorKeypoints(instanceId: id)
        let exp = XCTestExpectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(count.value, 1)
    }

    // MARK: - KeypointPickerViewModel — advance tests

    func test_keypointPickerVM_advance_to_next_unplaced_in_head_group() {
        let (store, id) = makeStore()
        // Place nose (1); next unplaced in head group should be left_eye (2).
        store.setKeypoint(instanceId: id, keypointIndex: 1, x: 10, y: 20, visibility: .visible)
        let vm = KeypointPickerViewModel()
        vm.activeKeypointIndex = 1
        vm.advance(in: store.annotationsForCurrentImage, for: id)
        XCTAssertEqual(vm.activeKeypointIndex, 2, "should advance to left_eye")
    }

    func test_keypointPickerVM_advance_stays_at_last_when_all_placed_in_group() {
        let (store, id) = makeStore()
        // Place all head group keypoints (1–5).
        for i in 1...5 {
            store.setKeypoint(instanceId: id, keypointIndex: i, x: Double(i), y: Double(i), visibility: .visible)
        }
        let vm = KeypointPickerViewModel()
        vm.activeKeypointIndex = 3  // somewhere in head
        vm.advance(in: store.annotationsForCurrentImage, for: id)
        XCTAssertEqual(vm.activeKeypointIndex, 5, "should stay at last in head group")
    }

    func test_keypointPickerVM_advance_skips_placed_points() {
        let (store, id) = makeStore()
        // Place left_eye (2) and left_ear (4).
        store.setKeypoint(instanceId: id, keypointIndex: 2, x: 10, y: 20, visibility: .visible)
        store.setKeypoint(instanceId: id, keypointIndex: 4, x: 30, y: 40, visibility: .visible)
        let vm = KeypointPickerViewModel()
        vm.activeKeypointIndex = 1  // nose
        vm.advance(in: store.annotationsForCurrentImage, for: id)
        // nose placed? No. But we called advance after placing nose — it looks for next unplaced.
        // Actually nose is NOT placed here. So advance from 1 should skip to 2? No — 2 IS placed.
        // Actually: we advanced after setting index 1 (nose) would be placed.
        // Let me re-trace: activeIndex=1, placed=[2,4]. Scan from 2: 2 is placed, 3 is unplaced → go to 3.

        // Since nose (1) is not placed either, let me place it first.
        store.setKeypoint(instanceId: id, keypointIndex: 1, x: 5, y: 5, visibility: .visible)
        let vm2 = KeypointPickerViewModel()
        vm2.activeKeypointIndex = 1
        vm2.advance(in: store.annotationsForCurrentImage, for: id)
        // Placed: 1, 2, 4. Scan from 2 (current+1=2): 2 is placed, 3 is not placed → go to 3.
        XCTAssertEqual(vm2.activeKeypointIndex, 3, "should skip 2 (placed) and advance to 3 (unplaced right_eye)")
    }

    func test_keypointPickerVM_advance_noop_when_no_instance() {
        let (store, _) = makeStore()
        let vm = KeypointPickerViewModel()
        vm.activeKeypointIndex = 1
        vm.advance(in: store.annotationsForCurrentImage, for: nil)
        XCTAssertEqual(vm.activeKeypointIndex, 1, "no-op when instance is nil")
    }

    func test_keypointPickerVM_advance_stays_in_group_boundary() {
        let (store, id) = makeStore()
        // In arms group, all placed.
        for i in 6...11 {
            store.setKeypoint(instanceId: id, keypointIndex: i, x: Double(i), y: Double(i), visibility: .visible)
        }
        let vm = KeypointPickerViewModel()
        vm.activeKeypointIndex = 6
        vm.advance(in: store.annotationsForCurrentImage, for: id)
        XCTAssertEqual(vm.activeKeypointIndex, 11, "stays at last of arms group (11)")
    }

    // MARK: - US-4-DEF-01: cycleKeypointVisibility reachable from canvas hit-test path

    /// Verifies that tapping within 8pt (view) of a placed dot triggers
    /// `cycleKeypointVisibility` rather than `setKeypoint`.
    ///
    /// This test replicates the decision logic from
    /// `AnnotatorCanvasView.onKeypointTap` without spinning a UIWindow:
    ///   1. Place a keypoint (simulates pre-existing dot).
    ///   2. Compute whether a tap at the dot's location falls within hit radius.
    ///   3. Assert the correct domain call (cycle) was made — verified by checking
    ///      the resulting visibility state, which is the same evidence the store
    ///      exposes to the canvas layer.
    func test_cycleOnHit_visible_becomes_occluded_when_tap_inside_hitRadius() {
        let (store, id) = makeStore()
        // Place nose (index 1) at image coord (200, 300) as visible.
        store.setKeypoint(instanceId: id, keypointIndex: 1, x: 200.0, y: 300.0, visibility: .visible)

        // Simulate the hit-test computation from onKeypointTap:
        //   viewSize = 390×844 (iPhone 16 portrait), imageSize = 1920×1080
        //   zoom = 1.0 (no zoom)
        let viewSize  = CGSize(width: 390, height: 844)
        let imageSize = CGSize(width: 1920, height: 1080)
        let zoom: CGFloat = 1.0
        let baseScale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let renderedScale = baseScale * zoom
        let hitRadiusImage: CGFloat = renderedScale > 0 ? 8.0 / renderedScale : 8.0

        // Tap location: exactly at the dot in image space (distance = 0 < hitRadius).
        let tapInImage = CGPoint(x: 200.0, y: 300.0)

        let ann = store.coco.annotations.first(where: { $0.id == id })!
        let kps = ann.keypoints!
        var cycled = false
        for kpDef in KeypointDefinition.all {
            let off = kpDef.cocoArrayOffset
            let v = Int(kps[off + 2])
            guard v > 0 else { continue }
            let kpX = kps[off]
            let kpY = kps[off + 1]
            let dx = tapInImage.x - CGFloat(kpX)
            let dy = tapInImage.y - CGFloat(kpY)
            if hypot(dx, dy) <= hitRadiusImage {
                store.cycleKeypointVisibility(instanceId: id, keypointIndex: kpDef.index)
                cycled = true
                break
            }
        }

        XCTAssertTrue(cycled, "hit-test must detect the dot and call cycleKeypointVisibility")
        let afterAnn = store.coco.annotations.first(where: { $0.id == id })!
        XCTAssertEqual(
            Int(afterAnn.keypoints![2]),
            KPVisibility.occluded.rawValue,
            "visible → occluded after one cycle"
        )
    }

    /// Verifies that a tap OUTSIDE the hit radius does NOT trigger the cycle path,
    /// leaving the domain caller free to invoke setKeypoint instead.
    func test_cycleOnHit_miss_outside_hitRadius_does_not_cycle() {
        let (store, id) = makeStore()
        store.setKeypoint(instanceId: id, keypointIndex: 1, x: 200.0, y: 300.0, visibility: .visible)

        let viewSize  = CGSize(width: 390, height: 844)
        let imageSize = CGSize(width: 1920, height: 1080)
        let zoom: CGFloat = 1.0
        let baseScale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let renderedScale = baseScale * zoom
        let hitRadiusImage: CGFloat = renderedScale > 0 ? 8.0 / renderedScale : 8.0

        // Tap far away from the dot (distance >> hitRadiusImage).
        let farTap = CGPoint(x: 500.0, y: 600.0)

        let ann = store.coco.annotations.first(where: { $0.id == id })!
        let kps = ann.keypoints!
        var cycled = false
        for kpDef in KeypointDefinition.all {
            let off = kpDef.cocoArrayOffset
            let v = Int(kps[off + 2])
            guard v > 0 else { continue }
            let kpX = kps[off]
            let kpY = kps[off + 1]
            let dx = farTap.x - CGFloat(kpX)
            let dy = farTap.y - CGFloat(kpY)
            if hypot(dx, dy) <= hitRadiusImage {
                cycled = true
                break
            }
        }

        XCTAssertFalse(cycled, "tap far from dot must not trigger cycle — setKeypoint path runs instead")
        // Visibility unchanged from initial `.visible`.
        let afterAnn = store.coco.annotations.first(where: { $0.id == id })!
        XCTAssertEqual(
            Int(afterAnn.keypoints![2]),
            KPVisibility.visible.rawValue,
            "visibility must remain visible — no cycle occurred"
        )
    }

    /// Verifies that a tap within hit radius of a dot whose visibility is `occluded`
    /// cycles it to `notLabeled` (the third step of the cycle).
    func test_cycleOnHit_occluded_becomes_notLabeled() {
        let (store, id) = makeStore()
        store.setKeypoint(instanceId: id, keypointIndex: 5, x: 100.0, y: 150.0, visibility: .occluded)

        let viewSize  = CGSize(width: 390, height: 844)
        let imageSize = CGSize(width: 1920, height: 1080)
        let zoom: CGFloat = 2.0  // zoomed in
        let baseScale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let renderedScale = baseScale * zoom
        let hitRadiusImage: CGFloat = renderedScale > 0 ? 8.0 / renderedScale : 8.0

        // Tap exactly on the dot — distance = 0.
        let tapInImage = CGPoint(x: 100.0, y: 150.0)

        let ann = store.coco.annotations.first(where: { $0.id == id })!
        let kps = ann.keypoints!
        for kpDef in KeypointDefinition.all {
            let off = kpDef.cocoArrayOffset
            let v = Int(kps[off + 2])
            guard v > 0 else { continue }
            let kpX = kps[off]
            let kpY = kps[off + 1]
            let dx = tapInImage.x - CGFloat(kpX)
            let dy = tapInImage.y - CGFloat(kpY)
            if hypot(dx, dy) <= hitRadiusImage {
                store.cycleKeypointVisibility(instanceId: id, keypointIndex: kpDef.index)
                break
            }
        }

        let afterAnn = store.coco.annotations.first(where: { $0.id == id })!
        let off5 = (5 - 1) * 3
        XCTAssertEqual(
            Int(afterAnn.keypoints![off5 + 2]),
            KPVisibility.notLabeled.rawValue,
            "occluded → notLabeled after cycle"
        )
    }
}

/// Thread-safe counter for `objectWillChange.sink` callbacks.
private final class Locked2<T: Numeric> {
    private var _value: T
    private let lock = NSLock()
    init(_ initial: T) { _value = initial }
    var value: T {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func increment() where T == Int {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }
}
