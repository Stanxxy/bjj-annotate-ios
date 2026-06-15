import XCTest
@testable import BJJAnnotate

/// T17 — Class chip row.
///
/// AC #10: three chips — Gi / NoGi / Ref — labeled via `LockedCopy.classChipGi`,
/// `LockedCopy.classChipNoGi`, `LockedCopy.classChipRef`.
/// AC #21 + Marker D: tapping a chip updates the selected box's class AND the
/// project's `sticky_category_id`. Sticky drives the default class for the next
/// fresh `.box` draw.
/// Addendum #1: Ref → Gi/NoGi auto-binds the next free athlete-id (already
/// implemented in `AnnotationStore.setClass`).
///
/// The chip-row VIEW is wired by `ClassChipRow`. This file asserts the bridge
/// to the store: a chip tap converts to `store.setClass(instanceId:category:)`.
@MainActor
final class ClassChipRowTests: XCTestCase {

    private func makeStore(annotations: [CocoAnnotation] = []) -> (AnnotationStore, SilentScheduler) {
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
            annotations: annotations,
            bjj_annotate_meta: meta
        )
        let store = AnnotationStore(initial: doc, imageId: 1, scheduler: scheduler)
        return (store, scheduler)
    }

    func test_chip_tap_invokes_setClass_with_the_tapped_category() {
        let ann = CocoAnnotation(
            id: 1, image_id: 1, category_id: ClassCategory.gi.rawValue,
            bbox: [10, 10, 50, 50], area: 2500, iscrowd: 0, segmentation: [], score: nil,
            attributes: CocoAnnotationAttributes(athlete_id: "athlete-1", source: "user", model_version: nil),
            keypoints: [], num_keypoints: 0
        )
        let (store, scheduler) = makeStore(annotations: [ann])

        ClassChipRow.handleTap(category: .nogi, on: 1, store: store)

        XCTAssertEqual(store.coco.annotations.first?.category_id, ClassCategory.nogi.rawValue)
        XCTAssertEqual(store.coco.annotations.first?.attributes.athlete_id, "athlete-1",
                       "Marker D: athlete↔athlete reclass preserves athlete-id")
        XCTAssertEqual(scheduler.scheduledPayloads.count, 1)
    }

    func test_chip_tap_to_Ref_clears_athlete_id_and_updates_sticky() {
        let ann = CocoAnnotation(
            id: 1, image_id: 1, category_id: ClassCategory.gi.rawValue,
            bbox: [10, 10, 50, 50], area: 2500, iscrowd: 0, segmentation: [], score: nil,
            attributes: CocoAnnotationAttributes(athlete_id: "athlete-1", source: "user", model_version: nil),
            keypoints: [], num_keypoints: 0
        )
        let (store, _) = makeStore(annotations: [ann])

        ClassChipRow.handleTap(category: .ref, on: 1, store: store)

        XCTAssertEqual(store.coco.annotations.first?.category_id, ClassCategory.ref.rawValue)
        XCTAssertNil(store.coco.annotations.first?.attributes.athlete_id,
                     "Ref clears athlete-id binding")
        XCTAssertEqual(store.coco.bjj_annotate_meta?.settings.sticky_category_id, ClassCategory.ref.rawValue,
                       "AC #21: sticky updates on chip tap")
    }

    func test_chip_tap_from_Ref_to_athlete_class_auto_binds_next_id() {
        let ann = CocoAnnotation(
            id: 1, image_id: 1, category_id: ClassCategory.ref.rawValue,
            bbox: [10, 10, 50, 50], area: 2500, iscrowd: 0, segmentation: [], score: nil,
            attributes: CocoAnnotationAttributes(athlete_id: nil, source: "user", model_version: nil),
            keypoints: nil, num_keypoints: nil
        )
        let (store, _) = makeStore(annotations: [ann])

        ClassChipRow.handleTap(category: .gi, on: 1, store: store)

        XCTAssertEqual(store.coco.annotations.first?.attributes.athlete_id, "athlete-1",
                       "Addendum #1: Ref → athlete class auto-binds next free id")
    }

    func test_chip_labels_match_LockedCopy() {
        XCTAssertEqual(ClassChipRow.label(for: .gi), LockedCopy.classChipGi)
        XCTAssertEqual(ClassChipRow.label(for: .nogi), LockedCopy.classChipNoGi)
        XCTAssertEqual(ClassChipRow.label(for: .ref), LockedCopy.classChipRef)
    }
}
