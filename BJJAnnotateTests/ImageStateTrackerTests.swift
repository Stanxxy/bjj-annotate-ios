import XCTest
@testable import BJJAnnotate

/// `ImageStateTracker` owns the per-image meta fields (`visited_at`, `flagged`).
/// Phase 1 surface: flag toggle on `AnnotatorView` top-bar trailing icon (PM
/// Addendum Designer Resolutions §2).
@MainActor
final class ImageStateTrackerTests: XCTestCase {

    private func makeStore() -> AnnotationStore {
        let meta = BjjAnnotateMeta(
            schema_version: 1,
            athletes: [],
            image_states: [],
            settings: MetaSettings(sticky_category_id: 1)
        )
        let doc = CocoDocument(
            info: nil,
            images: [CocoImage(id: 1, file_name: "frame.jpg", width: 1, height: 1)],
            categories: [],
            annotations: [],
            bjj_annotate_meta: meta
        )
        return AnnotationStore(initial: doc, imageId: 1, scheduler: SilentScheduler())
    }

    func test_markVisited_creates_image_state_with_iso8601_timestamp() {
        let store = makeStore()
        let tracker = ImageStateTracker(store: store)
        XCTAssertTrue(store.coco.bjj_annotate_meta?.image_states.isEmpty ?? true)
        tracker.markVisited()
        let state = store.coco.bjj_annotate_meta?.image_states.first { $0.image_id == 1 }
        XCTAssertNotNil(state)
        XCTAssertFalse(state?.flagged ?? true)
        XCTAssertFalse(state?.visited_at.isEmpty ?? true)
        // ISO8601 sanity: contains 'T' and ends with 'Z'.
        XCTAssertTrue(state?.visited_at.contains("T") ?? false)
        XCTAssertTrue(state?.visited_at.hasSuffix("Z") ?? false)
    }

    func test_flag_toggle_persists_via_image_state_entry() {
        let store = makeStore()
        let tracker = ImageStateTracker(store: store)
        tracker.markVisited()
        XCTAssertEqual(store.coco.bjj_annotate_meta?.image_states.first?.flagged, false)

        tracker.setFlagged(true)
        XCTAssertEqual(store.coco.bjj_annotate_meta?.image_states.first?.flagged, true)

        tracker.setFlagged(false)
        XCTAssertEqual(store.coco.bjj_annotate_meta?.image_states.first?.flagged, false)
    }

    func test_setFlagged_without_prior_visit_creates_image_state() {
        let store = makeStore()
        let tracker = ImageStateTracker(store: store)
        tracker.setFlagged(true)
        let state = store.coco.bjj_annotate_meta?.image_states.first { $0.image_id == 1 }
        XCTAssertEqual(state?.flagged, true)
        XCTAssertFalse(state?.visited_at.isEmpty ?? true)
    }
}
