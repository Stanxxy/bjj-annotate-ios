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
///
/// Note: `ConflictPresentation` class was eliminated in iOS-16 refactor commit.
/// `ConflictBanner` and `ConflictDiffModal` read `AnnotationStore.lastConflict`
/// directly. These tests verify the store-level behavior that those views depend on.
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

    private func makeConflict(ids: [Int] = [3, 7]) -> ConflictEvent {
        ConflictEvent(
            sidecarURL: URL(fileURLWithPath: "/tmp/sidecar.json"),
            winnerURL: URL(fileURLWithPath: "/tmp/winner.json"),
            differingAnnotationIds: ids
        )
    }

    // AC #34: No conflict → store.lastConflict is nil.
    func test_lastConflict_is_nil_on_fresh_store() {
        let store = makeStore()
        XCTAssertNil(store.lastConflict)
    }

    // AC #34: Setting lastConflict makes the banner copy available via LockedCopy.
    func test_banner_locked_copy_matches_lockedcopy_constant() {
        // ConflictBanner reads LockedCopy.conflictBanner directly; we assert the
        // constant is non-empty and the store gates on lastConflict != nil.
        let store = makeStore()
        store.lastConflict = makeConflict()
        XCTAssertNotNil(store.lastConflict)
        XCTAssertFalse(LockedCopy.conflictBanner.isEmpty,
                       "LockedCopy.conflictBanner must be a non-empty string (AC #34)")
    }

    // AC #35: LockedCopy.conflictDiffTitle is a non-empty string used by ConflictDiffModal.
    func test_modal_title_locked_copy_is_non_empty() {
        XCTAssertFalse(LockedCopy.conflictDiffTitle.isEmpty,
                       "LockedCopy.conflictDiffTitle must be a non-empty string (AC #35)")
    }

    // AC #35: differingAnnotationIds routes through ConflictEvent on the store.
    func test_differingAnnotationIds_accessible_on_lastConflict() {
        let store = makeStore()
        store.lastConflict = makeConflict(ids: [3, 7, 11])
        XCTAssertEqual(store.lastConflict?.differingAnnotationIds, [3, 7, 11])
    }

    // AC #36: clearLastConflict() sets lastConflict to nil.
    func test_clearLastConflict_sets_lastConflict_to_nil() {
        let store = makeStore()
        store.lastConflict = makeConflict(ids: [3])
        XCTAssertNotNil(store.lastConflict)
        store.clearLastConflict()
        XCTAssertNil(store.lastConflict)
    }
}
