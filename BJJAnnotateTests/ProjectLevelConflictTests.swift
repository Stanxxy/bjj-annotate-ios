import XCTest
@testable import BJJAnnotate

/// I3 integration tests — project-level conflict store (AC #34 on ProjectGridView).
///
/// AC #34 requires a conflict banner on BOTH `AnnotatorView` AND `ProjectGridView`.
/// The per-image `AnnotationStore.lastConflict` covers AnnotatorView. ProjectGridView
/// needs a separate lightweight watcher on the project folder's `annotations.json`
/// so the banner can surface even before opening the annotator.
///
/// `ProjectAnnotationConflictWatcher` is the new type that does not yet exist.
/// Verifies red.
@MainActor
final class ProjectLevelConflictTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("conflict-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    /// I3-A: Fresh project folder with no conflict versions has no active conflict.
    func test_fresh_project_has_no_conflict() async throws {
        let annotationsURL = tempDir.appendingPathComponent("annotations.json")
        let watcher = ProjectAnnotationConflictWatcher(annotationsURL: annotationsURL)
        // Before any file exists, no conflict.
        XCTAssertNil(watcher.lastConflict,
                     "Fresh project must have no lastConflict before any file is written.")
    }

    /// I3-B: `ProjectAnnotationConflictWatcher` exposes a `bannerMessage` matching
    ///        `LockedCopy.conflictBanner` when `lastConflict` is non-nil.
    func test_banner_message_uses_locked_copy_when_conflict_exists() async throws {
        let annotationsURL = tempDir.appendingPathComponent("annotations.json")
        let watcher = ProjectAnnotationConflictWatcher(annotationsURL: annotationsURL)
        // Inject a synthetic conflict event.
        watcher.inject(ConflictEvent(
            sidecarURL: annotationsURL.deletingLastPathComponent().appendingPathComponent("annotations.conflict-2026-06-19T00:00:00Z.json"),
            winnerURL: annotationsURL,
            differingAnnotationIds: [1, 2]
        ))
        XCTAssertEqual(watcher.bannerMessage, LockedCopy.conflictBanner,
                       "Banner message must equal LockedCopy.conflictBanner when conflict is non-nil.")
    }

    /// I3-C: Dismissing the conflict clears `lastConflict`.
    func test_dismiss_clears_lastConflict() async throws {
        let annotationsURL = tempDir.appendingPathComponent("annotations.json")
        let watcher = ProjectAnnotationConflictWatcher(annotationsURL: annotationsURL)
        watcher.inject(ConflictEvent(
            sidecarURL: annotationsURL.deletingLastPathComponent().appendingPathComponent("annotations.conflict-2026-06-19T00:00:01Z.json"),
            winnerURL: annotationsURL,
            differingAnnotationIds: [5]
        ))
        XCTAssertNotNil(watcher.lastConflict)
        watcher.dismiss()
        XCTAssertNil(watcher.lastConflict,
                     "Dismiss must clear lastConflict on the project-level watcher.")
    }
}
