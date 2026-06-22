import XCTest
@testable import BJJAnnotate

/// Tests that the `isAthleteSelected(store:)` predicate — which gates the
/// keypoint picker inset in `AnnotatorView.canvasRegion` — returns the correct
/// value for every relevant annotation category.
///
/// The predicate is:
///   ```
///   guard let id = selectedInstanceId,
///         let ann = store.coco.annotations.first(where: { $0.id == id }) else { return false }
///   return ann.category_id != ClassCategory.ref.rawValue
///   ```
///
/// These tests reproduce that logic against a real `AnnotationStore` using
/// `SilentScheduler` (no disk I/O), matching the fixture pattern from
/// `AnnotationStoreTests`.
@MainActor
final class IsAthleteSelectedGateTests: XCTestCase {

    // MARK: - Fixtures

    private static let imageId = 1

    private func makeStore() -> AnnotationStore {
        let meta = BjjAnnotateMeta(
            schema_version: 1,
            athletes: [],
            image_states: [],
            settings: MetaSettings(sticky_category_id: 1)
        )
        let doc = CocoDocument(
            info: nil,
            images: [CocoImage(id: Self.imageId, file_name: "frame.jpg", width: 1920, height: 1080)],
            categories: [
                CocoCategory(id: 1, name: "gi-athlete", supercategory: "person", keypoints: [], skeleton: []),
                CocoCategory(id: 2, name: "nogi-athlete", supercategory: "person", keypoints: [], skeleton: []),
                CocoCategory(id: 3, name: "referee", supercategory: "person", keypoints: nil, skeleton: nil),
            ],
            annotations: [],
            bjj_annotate_meta: meta
        )
        return AnnotationStore(initial: doc, imageId: Self.imageId, scheduler: SilentScheduler())
    }

    /// Mirrors `AnnotatorView.isAthleteSelected(store:)` so the tests exercise
    /// the exact same condition without coupling to private view state.
    private func isAthleteSelected(store: AnnotationStore, selectedInstanceId: Int?) -> Bool {
        guard let id = selectedInstanceId,
              let ann = store.coco.annotations.first(where: { $0.id == id }) else {
            return false
        }
        return ann.category_id != ClassCategory.ref.rawValue
    }

    // MARK: - No selection

    func test_noSelection_returnsFalse() {
        let store = makeStore()
        XCTAssertFalse(isAthleteSelected(store: store, selectedInstanceId: nil),
                       "With no instance selected the picker inset must not appear.")
    }

    // MARK: - Athlete categories (gi and nogi)

    func test_giAthlete_returnsTrue() {
        let store = makeStore()
        // Default sticky category is gi (id=1); upsertBox creates a gi-athlete annotation.
        let id = store.upsertBox(BBoxIntent(rect: BBox(x: 10, y: 10, w: 100, h: 100)))
        XCTAssertTrue(isAthleteSelected(store: store, selectedInstanceId: id),
                      "A gi-athlete annotation must enable the keypoint picker inset.")
    }

    func test_nogiAthlete_returnsTrue() {
        let store = makeStore()
        let id = store.upsertBox(BBoxIntent(rect: BBox(x: 10, y: 10, w: 100, h: 100)))
        store.setClass(instanceId: id, category: .nogi)
        XCTAssertTrue(isAthleteSelected(store: store, selectedInstanceId: id),
                      "A nogi-athlete annotation must enable the keypoint picker inset.")
    }

    // MARK: - Referee category

    func test_referee_returnsFalse() {
        let store = makeStore()
        let id = store.upsertBox(BBoxIntent(rect: BBox(x: 10, y: 10, w: 100, h: 100)))
        store.setClass(instanceId: id, category: .ref)
        XCTAssertFalse(isAthleteSelected(store: store, selectedInstanceId: id),
                       "A referee annotation must NOT enable the keypoint picker inset.")
    }

    // MARK: - Stale / unknown id

    func test_unknownInstanceId_returnsFalse() {
        let store = makeStore()
        _ = store.upsertBox(BBoxIntent(rect: BBox(x: 10, y: 10, w: 100, h: 100)))
        XCTAssertFalse(isAthleteSelected(store: store, selectedInstanceId: 9999),
                       "An id that does not exist in the store must return false.")
    }
}
