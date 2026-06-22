import XCTest
@testable import BJJAnnotate

/// T18 — Athlete-id picker.
///
/// AC #11 (Designer §3.3 / §3.4): athlete picker shows the existing
/// `athlete-N` ids, plus a `+ New athlete` row that allocates and binds the
/// next id (capped at 8 — PM addendum #10).
/// AC #16(b): if no box is selected, the picker is unavailable.
///
/// `AthletePickerModel` is the pure value-type that the SwiftUI sheet renders.
/// It exposes:
///   - `rows: [Row]` — sorted by id ascending.
///   - `bottomRow: BottomRow` — `.newAthlete` when `< 8`; `.locked(copy:)` at cap.
///   - `select(_:on:store:)` — rebinds an existing id.
///   - `allocateNew(on:store:)` — allocates new + binds.
@MainActor
final class AthletePickerTests: XCTestCase {

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

    func test_rows_match_athletes_sorted_ascending() {
        let store = makeStore(athletes: [
            Athlete(id: "athlete-3", display_name: "athlete-3", color_hex: "#10B981"),
            Athlete(id: "athlete-1", display_name: "athlete-1", color_hex: "#3B82F6"),
        ])
        let model = AthletePickerModel(store: store)
        XCTAssertEqual(model.rows.map(\.athleteId), ["athlete-1", "athlete-3"])
    }

    func test_bottomRow_is_newAthlete_when_under_cap() {
        let store = makeStore(athletes: [
            Athlete(id: "athlete-1", display_name: "athlete-1", color_hex: "#3B82F6"),
        ])
        let model = AthletePickerModel(store: store)
        XCTAssertEqual(model.bottomRow, .newAthlete(LockedCopy.newAthleteRow))
    }

    func test_bottomRow_is_locked_copy_at_cap() {
        let athletes = (1...8).map { Athlete(id: "athlete-\($0)", display_name: "athlete-\($0)", color_hex: AthletePalette.hexes[$0 - 1]) }
        let store = makeStore(athletes: athletes)
        let model = AthletePickerModel(store: store)
        XCTAssertEqual(model.bottomRow, .locked(LockedCopy.projectFullAthleteCap))
    }

    func test_select_rebinds_existing_id_on_selected_instance() {
        let athletes = [
            Athlete(id: "athlete-1", display_name: "athlete-1", color_hex: "#3B82F6"),
            Athlete(id: "athlete-2", display_name: "athlete-2", color_hex: "#F59E0B"),
        ]
        let ann = CocoAnnotation(
            id: 1, image_id: 1, category_id: ClassCategory.gi.rawValue,
            bbox: [0, 0, 10, 10], area: 100, iscrowd: 0, segmentation: [], score: nil,
            attributes: CocoAnnotationAttributes(athlete_id: "athlete-1", source: "user", model_version: nil),
            keypoints: [], num_keypoints: 0
        )
        let store = makeStore(athletes: athletes, annotations: [ann])
        let model = AthletePickerModel(store: store)

        model.select(athleteId: "athlete-2", on: 1)

        XCTAssertEqual(store.coco.annotations.first?.attributes.athlete_id, "athlete-2")
    }

    func test_allocateNew_appends_athlete_and_binds_to_selected_instance() {
        let ann = CocoAnnotation(
            id: 1, image_id: 1, category_id: ClassCategory.gi.rawValue,
            bbox: [0, 0, 10, 10], area: 100, iscrowd: 0, segmentation: [], score: nil,
            attributes: CocoAnnotationAttributes(athlete_id: "athlete-1", source: "user", model_version: nil),
            keypoints: [], num_keypoints: 0
        )
        let store = makeStore(athletes: [
            Athlete(id: "athlete-1", display_name: "athlete-1", color_hex: "#3B82F6"),
        ], annotations: [ann])
        let model = AthletePickerModel(store: store)

        let id = model.allocateNew(on: 1)

        XCTAssertEqual(id, "athlete-2")
        XCTAssertEqual(store.coco.bjj_annotate_meta?.athletes.count, 2)
        XCTAssertEqual(store.coco.annotations.first?.attributes.athlete_id, "athlete-2")
    }

    func test_allocateNew_returns_nil_at_cap() {
        let athletes = (1...8).map { Athlete(id: "athlete-\($0)", display_name: "athlete-\($0)", color_hex: AthletePalette.hexes[$0 - 1]) }
        let store = makeStore(athletes: athletes)
        let model = AthletePickerModel(store: store)
        XCTAssertNil(model.allocateNew(on: 1),
                     "PM addendum #10: allocate returns nil at the 8-athlete cap")
    }
}
