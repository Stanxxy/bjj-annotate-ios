import XCTest
@testable import BJJAnnotate

/// T20 — Conflict banner + read-only diff modal.
///
/// AC #34: Non-blocking banner on AnnotatorView AND ProjectGridView when the
/// store reports `lastConflict != nil`. Locked copy: LockedCopy.conflictBanner.
/// AC #35: Tapping the banner presents a read-only modal listing the
/// differing annotation ids (LockedCopy.conflictDiffTitle).
/// AC #36: Dismissing the modal does NOT clear the banner; the user must
/// explicitly dismiss via the banner's close button (which clears the store).
@MainActor
final class ConflictBannerTests: XCTestCase {

    private func makeStore() -> AnnotationStore {
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
        return AnnotationStore(initial: doc, imageId: 1, scheduler: scheduler)
    }

    func test_conflictPresentation_is_nil_when_lastConflict_is_nil() {
        let store = makeStore()
        let presentation = ConflictPresentation(store: store)
        XCTAssertNil(presentation.bannerMessage)
    }

    func test_conflictPresentation_surfaces_locked_banner_when_lastConflict_set() {
        let store = makeStore()
        store.lastConflict = ConflictEvent(
            sidecarURL: URL(fileURLWithPath: "/tmp/sidecar.json"),
            winnerURL: URL(fileURLWithPath: "/tmp/winner.json"),
            differingAnnotationIds: [3, 7]
        )
        let presentation = ConflictPresentation(store: store)
        XCTAssertEqual(presentation.bannerMessage, LockedCopy.conflictBanner)
    }

    func test_modalTitle_is_locked_copy() {
        let store = makeStore()
        store.lastConflict = ConflictEvent(
            sidecarURL: URL(fileURLWithPath: "/tmp/sidecar.json"),
            winnerURL: URL(fileURLWithPath: "/tmp/winner.json"),
            differingAnnotationIds: [3, 7]
        )
        let presentation = ConflictPresentation(store: store)
        XCTAssertEqual(presentation.modalTitle, LockedCopy.conflictDiffTitle)
    }

    func test_differingAnnotationIds_routes_through_presentation() {
        let store = makeStore()
        store.lastConflict = ConflictEvent(
            sidecarURL: URL(fileURLWithPath: "/tmp/sidecar.json"),
            winnerURL: URL(fileURLWithPath: "/tmp/winner.json"),
            differingAnnotationIds: [3, 7, 11]
        )
        let presentation = ConflictPresentation(store: store)
        XCTAssertEqual(presentation.differingAnnotationIds, [3, 7, 11])
    }

    func test_dismissBanner_clears_lastConflict() {
        let store = makeStore()
        store.lastConflict = ConflictEvent(
            sidecarURL: URL(fileURLWithPath: "/tmp/sidecar.json"),
            winnerURL: URL(fileURLWithPath: "/tmp/winner.json"),
            differingAnnotationIds: [3]
        )
        let presentation = ConflictPresentation(store: store)
        presentation.dismiss()
        XCTAssertNil(store.lastConflict)
        XCTAssertNil(presentation.bannerMessage)
    }
}
