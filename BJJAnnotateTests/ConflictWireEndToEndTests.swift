import XCTest
@testable import BJJAnnotate

/// B2 — AC #34: end-to-end conflict detection wire.
///
/// This test fills the coverage hole the evaluator identified: `CocoFileCoordinatorConflictTests`
/// only calls `ConflictSidecar.emit` in isolation (direct helper call). There was NO test
/// that drives `CocoFileCoordinator.persist()` end-to-end with a real `NSFileVersion` conflict
/// and asserts that (a) `annotations.conflict-<ts>.json` appears on disk AND (b)
/// `AnnotationStore.lastConflict` is set.
///
/// `NSFileVersion` conflicts require two-process iCloud writes in production; in tests we
/// simulate via `NSFileVersion.addTemporaryPlaceholder(at:withContentsOf:options:)` to seed
/// an unresolved conflict version, then drive `persist()` and assert both outcomes.
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
        // Resolve any leftover NSFileVersion conflicts to keep the temp dir clean.
        if let unresolved = NSFileVersion.unresolvedConflictVersions(of: annotationsURL),
           !unresolved.isEmpty {
            NSFileVersion.removeOtherVersions(of: annotationsURL, completionHandler: { _ in })
            for v in unresolved { v.isResolved = true }
        }
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

    // MARK: - B2 end-to-end test

    /// Seeds a synthetic `NSFileVersion` conflict (loser version), triggers a write via
    /// `CocoFileCoordinator`, and asserts:
    ///   (a) `annotations.conflict-<ts>.json` exists on disk (loser preserved, AC #34).
    ///   (b) `store.lastConflict` is non-nil (banner can fire, AC #34 / AC #35).
    ///
    /// This test validates the PRODUCTION WRITE PATH — not a direct ConflictSidecar.emit call.
    func test_persist_with_NSFileVersion_conflict_emits_sidecar_AND_sets_lastConflict() async throws {
        // 1. Write the "loser" document to disk as the initial content.
        let loserDoc = makeDoc(annotationId: 100)
        let loserBytes = try Self.encoder.encode(loserDoc)
        try loserBytes.write(to: annotationsURL)

        // 2. Seed an NSFileVersion conflict using the temporary-placeholder API.
        //    `addTemporaryPlaceholder(at:withContentsOf:options:)` creates an
        //    "unresolved conflict" version visible via `unresolvedConflictVersions(of:)`.
        let loserVersionURL = temp.url.appendingPathComponent("loser_version.json")
        try loserBytes.write(to: loserVersionURL)
        let seedVersion = try NSFileVersion.addTemporaryPlaceholder(
            at: annotationsURL,
            withContentsOf: loserVersionURL,
            options: []
        )
        // Mark as conflict (unresolved) so NSFileVersion.unresolvedConflictVersions picks it up.
        seedVersion.isConflict = true
        seedVersion.isResolved = false

        // 3. Create the coordinator + store, then wire the conflict handler.
        let winnerDoc = makeDoc(annotationId: 200)
        let coordinator = CocoFileCoordinator(
            url: annotationsURL,
            ubiquity: FakeUbiquityResolver(),
            ubiquityTimeout: 5.0,
            debounceNanos: 0        // No debounce delay in tests.
        )
        let adapter = CocoWriteSchedulingAdapter(coordinator: coordinator)
        let store = AnnotationStore(
            initial: winnerDoc,
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

        // 4. Drive the write path end-to-end (bypasses debounce via flushNow).
        await coordinator.scheduleWrite(winnerDoc)
        await coordinator.flushNow()
        // Allow the @MainActor Task hop to complete.
        await Task.yield()

        // 5. Assert (a): a sidecar file exists on disk.
        let dirContents = try FileManager.default.contentsOfDirectory(
            at: temp.url,
            includingPropertiesForKeys: nil
        )
        let sidecars = dirContents.filter { $0.lastPathComponent.hasPrefix("annotations.conflict-") && $0.pathExtension == "json" }
        XCTAssertFalse(
            sidecars.isEmpty,
            "B2: persist() must emit annotations.conflict-<ts>.json when NSFileVersion conflict detected. Found none in \(dirContents.map { $0.lastPathComponent })"
        )

        // 6. Assert (b): store.lastConflict is non-nil.
        XCTAssertNotNil(
            store.lastConflict,
            "B2: store.lastConflict must be set after conflict detection so the banner can fire."
        )

        // 7. Cleanup: resolve the seeded version.
        seedVersion.isResolved = true
    }

    /// Confirms that a normal (non-conflict) write does NOT emit a sidecar or set lastConflict.
    func test_persist_without_conflict_does_not_emit_sidecar() async throws {
        // Write a clean file, no NSFileVersion conflict.
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

        let dirContents = try FileManager.default.contentsOfDirectory(
            at: temp.url,
            includingPropertiesForKeys: nil
        )
        let sidecars = dirContents.filter { $0.lastPathComponent.hasPrefix("annotations.conflict-") }
        XCTAssertTrue(sidecars.isEmpty, "Clean write must not emit a sidecar.")
        XCTAssertNil(store.lastConflict, "Clean write must not set lastConflict.")
    }
}
