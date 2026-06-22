import XCTest
@testable import BJJAnnotate

/// B2 — AC #34: end-to-end conflict detection wire.
///
/// `NSFileVersion` real conflicts require two-process iCloud writes and cannot be seeded
/// from iOS unit tests (`addVersionOfItemAtURL:withContentsOfURL:options:error:` is
/// macOS-only; the companion `addTemporaryPlaceholder` selector does not exist in the SDK).
/// `CocoFileCoordinatorConflictTests` covers the sidecar-emission path via `ConflictSidecar.emit`
/// directly.
///
/// This file tests the WIRE between `CocoFileCoordinator.onConflictDetected` and
/// `AnnotationStore.lastConflict` — the B2 production path that `AnnotatorLifecycleContext.make()`
/// establishes via `coordinator.setConflictHandler { [store] event in … }`.
///
/// We inject a synthetic `ConflictEvent` through the coordinator's public `onConflictDetected`
/// callback to validate that:
///   (a) The handler hop from background Task → @MainActor correctly sets `store.lastConflict`.
///   (b) A coordinator with no handler set does NOT crash when a conflict would fire.
///
/// Uses real temp dirs (AC #28 — no FileManager mocks).
@MainActor
final class ConflictWireEndToEndTests: XCTestCase {

    private var temp: TempDirectory!
    private var annotationsURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
        annotationsURL = temp.url.appendingPathComponent("annotations.json")
    }

    override func tearDown() async throws {
        temp = nil
        annotationsURL = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private func makeDoc(annotationId: Int) -> CocoDocument {
        CocoDocument(
            info: nil,
            images: [CocoImage(id: 1, file_name: "f.jpg", width: 10, height: 10)],
            categories: [],
            annotations: [
                CocoAnnotation(
                    id: annotationId,
                    image_id: 1,
                    category_id: 1,
                    bbox: [0, 0, 5, 5],
                    area: 25,
                    iscrowd: 0,
                    segmentation: [],
                    score: nil,
                    attributes: CocoAnnotationAttributes(athlete_id: "athlete-1", source: "user", model_version: nil),
                    keypoints: [],
                    num_keypoints: 0
                )
            ],
            bjj_annotate_meta: BjjAnnotateMeta(
                schema_version: 1,
                athletes: [Athlete(id: "athlete-1", display_name: "athlete-1", color_hex: "#3B82F6")],
                image_states: [],
                settings: MetaSettings(sticky_category_id: 1)
            )
        )
    }

    // MARK: - B2 wire tests

    /// Validates the B2 production wire: `CocoFileCoordinator.setConflictHandler` +
    /// the `Task { @MainActor in store.lastConflict = event }` hop correctly surfaces
    /// a conflict event on `store.lastConflict`.
    ///
    /// This is the path `AnnotatorLifecycleContext.make()` establishes and is the
    /// testable seam for B2 without requiring real iCloud two-process writes.
    func test_conflictHandler_wire_sets_store_lastConflict() async throws {
        let doc = makeDoc(annotationId: 1)
        let bytes = try Self.encoder.encode(doc)
        try bytes.write(to: annotationsURL)

        let coordinator = CocoFileCoordinator(
            url: annotationsURL,
            ubiquity: FakeUbiquityResolver(),
            ubiquityTimeout: 5.0,
            debounceNanos: 0
        )
        let adapter = CocoWriteSchedulingAdapter(coordinator: coordinator)
        let store = AnnotationStore(
            initial: doc,
            imageId: 1,
            scheduler: adapter
        )

        // Wire the conflict handler exactly as AnnotatorLifecycleContext.make() does.
        // This is the B2 production path under test.
        await coordinator.setConflictHandler { [store] event in
            Task { @MainActor in
                store.lastConflict = event
            }
        }

        // Synthesize a conflict event (the coordinator normally builds this from
        // ConflictSidecar.emit — that path is tested in CocoFileCoordinatorConflictTests).
        let syntheticEvent = ConflictEvent(
            sidecarURL: annotationsURL.deletingLastPathComponent()
                .appendingPathComponent("annotations.conflict-2027-01-15T08:00:00Z.json"),
            winnerURL: annotationsURL,
            differingAnnotationIds: [100, 200]
        )

        // Fire the handler via the actor's stored callback (simulates what
        // resolveConflictsIfNeeded does after sidecar emission).
        await coordinator.fireConflictHandlerForTest(syntheticEvent)

        // Allow the @MainActor Task hop to complete.
        await Task.yield()

        // Assert (b): store.lastConflict is non-nil.
        XCTAssertNotNil(
            store.lastConflict,
            "B2: store.lastConflict must be set after the conflict handler fires."
        )
        XCTAssertEqual(store.lastConflict?.differingAnnotationIds, [100, 200])
    }

    /// Confirms that a coordinator with no conflict handler set does NOT crash when
    /// the handler slot is nil (defensive path in resolveConflictsIfNeeded).
    func test_no_conflictHandler_does_not_crash() async throws {
        let doc = makeDoc(annotationId: 1)
        let bytes = try Self.encoder.encode(doc)
        try bytes.write(to: annotationsURL)

        let coordinator = CocoFileCoordinator(
            url: annotationsURL,
            ubiquity: FakeUbiquityResolver(),
            debounceNanos: 0
        )

        // No handler set — fireConflictHandlerForTest must not crash.
        let syntheticEvent = ConflictEvent(
            sidecarURL: annotationsURL.deletingLastPathComponent()
                .appendingPathComponent("annotations.conflict-noop.json"),
            winnerURL: annotationsURL,
            differingAnnotationIds: []
        )
        await coordinator.fireConflictHandlerForTest(syntheticEvent)
        // Passes if no crash occurs.
    }

    /// Confirms that a normal (non-conflict) write does NOT set lastConflict on the store.
    func test_persist_without_conflict_does_not_set_lastConflict() async throws {
        let doc = makeDoc(annotationId: 1)
        let bytes = try Self.encoder.encode(doc)
        try bytes.write(to: annotationsURL)

        let coordinator = CocoFileCoordinator(
            url: annotationsURL,
            ubiquity: FakeUbiquityResolver(),
            debounceNanos: 0
        )
        let adapter = CocoWriteSchedulingAdapter(coordinator: coordinator)
        let store = AnnotationStore(initial: doc, imageId: 1, scheduler: adapter)

        await coordinator.scheduleWrite(doc)
        await coordinator.flushNow()
        await Task.yield()

        XCTAssertNil(store.lastConflict, "Clean write must not set lastConflict.")
    }
}
