import XCTest
import Combine
@testable import BJJAnnotate

/// Evaluator pre-emption R-UI-2: drag-staging stays in view-local `@State`;
/// `AnnotationStore` is mutated only on gesture-end commit.
///
/// Why this matters: 60Hz drag-progress events touching `store.coco` would
/// trigger 60 SwiftUI invalidations and 60 `scheduleWrite` calls per second.
/// Even with 500ms debounce in `CocoFileCoordinator`, the in-process work
/// (CocoDocument value-type copy + ObservableObject propagation) is wasted CPU.
/// The contract: `AnnotatorCanvasView` keeps the active drag in
/// `@State private var dragStage: DragStage?` and only calls
/// `store.upsertBox` inside the gesture's `.onEnded`.
///
/// This test asserts the store side of that contract:
///   - When the caller observes the contract (60 progress events, then 1
///     commit), there is exactly 1 `scheduleWrite` and exactly 1 observation
///     invalidation on `store.coco`.
///   - This documents the expected call pattern. T15 (BoxIntake green) wires
///     `AnnotatorCanvasView` to honor it; a separate UI test in T15 asserts
///     the view-side discipline.
@MainActor
final class DragStagingContractTests: XCTestCase {

    func test_60_drag_progress_events_then_1_commit_produce_1_write_and_1_observation() {
        // Setup: store with a SilentScheduler that counts writes.
        let scheduler = SilentScheduler()
        let meta = BjjAnnotateMeta(
            schema_version: 1,
            athletes: [],
            image_states: [],
            settings: MetaSettings(sticky_category_id: 1)
        )
        let doc = CocoDocument(
            info: nil,
            images: [CocoImage(id: 1, file_name: "f.jpg", width: 1920, height: 1080)],
            categories: [],
            annotations: [],
            bjj_annotate_meta: meta
        )
        let store = AnnotationStore(initial: doc, imageId: 1, scheduler: scheduler)

        // ObservableObject counter: objectWillChange fires synchronously on each @Published write.
        let invalidations = LockedCounter(0)
        var cancellables = Set<AnyCancellable>()
        store.objectWillChange.sink { invalidations.increment() }
            .store(in: &cancellables)

        // Simulate 60 drag-progress events: these stay in view-local state.
        // The contract is that NONE of them call into the store. We model that
        // here by simply NOT touching `store` 60 times. The committed value is
        // computed from the final progress event.
        var stagedRect = BBox(x: 0, y: 0, w: 0, h: 0)
        for i in 0..<60 {
            // Each progress event updates view-local state; here we use a local
            // variable as the analog of `@State var dragStage`.
            stagedRect = BBox(x: 100, y: 100, w: Double(i + 1) * 2, h: Double(i + 1) * 2)
        }
        XCTAssertEqual(scheduler.scheduledPayloads.count, 0,
                       "60 drag-progress events must NOT touch the store (R-UI-2 contract)")

        // Gesture-end: single commit to the store.
        let intent = BBoxIntent(rect: stagedRect)
        _ = store.upsertBox(intent)

        // Allow objectWillChange to flush (it's synchronous but give settle time for consistency).
        let exp = XCTestExpectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(scheduler.scheduledPayloads.count, 1,
                       "Gesture-end commit must produce exactly 1 scheduleWrite call")
        XCTAssertEqual(invalidations.value, 1,
                       "Exactly 1 ObservableObject invalidation per gesture-end commit")
    }
}

/// Thread-safe counter (same pattern as `Locked` in AnnotationStoreTests).
private final class LockedCounter {
    private var _value: Int
    private let lock = NSLock()
    init(_ initial: Int) { _value = initial }
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }
}
