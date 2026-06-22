import XCTest
@testable import BJJAnnotate

/// T19 — Instance list.
///
/// AC #12: Instance list shows one row per annotation in the current image,
/// labeled with athlete-id or "Ref", color-coded by athlete palette.
/// AC #13: Tapping a row selects the corresponding box on the canvas.
/// AC #14 mobile-first: bottom sheet on compact, right rail on regular.
///        The size-class branch happens in the view via `Layout.AdaptiveAnchor`
///        (T19 model is layout-agnostic).
/// Empty state copy: locked `LockedCopy.instanceListEmptyState`.
@MainActor
final class InstanceListModelTests: XCTestCase {

    private func makeStore(athletes: [Athlete] = [], annotations: [CocoAnnotation] = []) -> AnnotationStore {
        let scheduler = SilentScheduler()
        let meta = BjjAnnotateMeta(
            schema_version: 1,
            athletes: athletes,
            image_states: [],
            settings: MetaSettings(sticky_category_id: 1)
        )
        let doc = CocoDocument(
            info: nil,
            images: [CocoImage(id: 1, file_name: "f.jpg", width: 1920, height: 1080)],
            categories: [],
            annotations: annotations,
            bjj_annotate_meta: meta
        )
        return AnnotationStore(initial: doc, imageId: 1, scheduler: scheduler)
    }

    func test_empty_store_has_no_rows() {
        let store = makeStore()
        let model = InstanceListModel(store: store)
        XCTAssertEqual(model.rows.count, 0)
        XCTAssertEqual(model.emptyStateCopy, LockedCopy.instanceListEmptyState)
    }

    func test_rows_render_one_per_annotation_in_order_of_id() {
        let ann1 = CocoAnnotation(
            id: 2, image_id: 1, category_id: ClassCategory.gi.rawValue,
            bbox: [0, 0, 10, 10], area: 100, iscrowd: 0, segmentation: [], score: nil,
            attributes: CocoAnnotationAttributes(athlete_id: "athlete-2", source: "user", model_version: nil),
            keypoints: [], num_keypoints: 0
        )
        let ann2 = CocoAnnotation(
            id: 1, image_id: 1, category_id: ClassCategory.ref.rawValue,
            bbox: [0, 0, 10, 10], area: 100, iscrowd: 0, segmentation: [], score: nil,
            attributes: CocoAnnotationAttributes(athlete_id: nil, source: "user", model_version: nil),
            keypoints: nil, num_keypoints: nil
        )
        let store = makeStore(annotations: [ann1, ann2])
        let model = InstanceListModel(store: store)
        XCTAssertEqual(model.rows.map(\.instanceId), [1, 2])
    }

    func test_row_label_is_athlete_id_or_Ref() {
        let ann1 = CocoAnnotation(
            id: 1, image_id: 1, category_id: ClassCategory.gi.rawValue,
            bbox: [0, 0, 10, 10], area: 100, iscrowd: 0, segmentation: [], score: nil,
            attributes: CocoAnnotationAttributes(athlete_id: "athlete-1", source: "user", model_version: nil),
            keypoints: [], num_keypoints: 0
        )
        let ann2 = CocoAnnotation(
            id: 2, image_id: 1, category_id: ClassCategory.ref.rawValue,
            bbox: [0, 0, 10, 10], area: 100, iscrowd: 0, segmentation: [], score: nil,
            attributes: CocoAnnotationAttributes(athlete_id: nil, source: "user", model_version: nil),
            keypoints: nil, num_keypoints: nil
        )
        let store = makeStore(annotations: [ann1, ann2])
        let model = InstanceListModel(store: store)
        let labels = model.rows.map(\.label)
        XCTAssertEqual(labels[0], "athlete-1")
        XCTAssertEqual(labels[1], "Ref")
    }

    func test_row_color_uses_palette_for_athletes_or_secondary_for_ref() {
        let ann1 = CocoAnnotation(
            id: 1, image_id: 1, category_id: ClassCategory.gi.rawValue,
            bbox: [0, 0, 10, 10], area: 100, iscrowd: 0, segmentation: [], score: nil,
            attributes: CocoAnnotationAttributes(athlete_id: "athlete-3", source: "user", model_version: nil),
            keypoints: [], num_keypoints: 0
        )
        let ann2 = CocoAnnotation(
            id: 2, image_id: 1, category_id: ClassCategory.ref.rawValue,
            bbox: [0, 0, 10, 10], area: 100, iscrowd: 0, segmentation: [], score: nil,
            attributes: CocoAnnotationAttributes(athlete_id: nil, source: "user", model_version: nil),
            keypoints: nil, num_keypoints: nil
        )
        let store = makeStore(annotations: [ann1, ann2])
        let model = InstanceListModel(store: store)
        // athlete-3 → palette slot 3 = "#10B981".
        XCTAssertEqual(model.rows[0].colorHex, "#10B981")
        XCTAssertNil(model.rows[1].colorHex,
                     "Ref rows must report nil color so the view picks system gray (Designer §2.4)")
    }
}
