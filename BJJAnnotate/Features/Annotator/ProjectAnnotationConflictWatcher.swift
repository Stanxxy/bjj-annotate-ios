import Foundation
import Observation

/// Lightweight project-level conflict watcher.
///
/// I3: AC #34 requires conflict banners on BOTH `AnnotatorView` AND `ProjectGridView`.
/// The per-image `AnnotationStore.lastConflict` covers `AnnotatorView` (set by
/// `CocoFileCoordinator` after a write-time conflict check). `ProjectGridView` needs a
/// separate `@Observable` object that can surface a conflict even before the user opens
/// the annotator.
///
/// Lifecycle: one watcher per project grid session. `ProjectGridView` holds a reference
/// and `AnnotatorView` forwards the coordinator's conflict event to it on write.
///
/// The watcher does NOT re-probe NSFileVersion itself — it is fed events from the
/// `CocoFileCoordinator` (the authoritative conflict detector). The coordinator calls
/// `receive(conflictEvent:)` after emitting the sidecar.
///
/// Tests inject events via `inject(_:)` (same as `receive(conflictEvent:)` — visible
/// for test access).
@Observable
@MainActor
final class ProjectAnnotationConflictWatcher {
    /// URL of the project's `annotations.json`. Used as identity only (not read here).
    let annotationsURL: URL

    /// Non-nil when an unresolved conflict has been detected for this project.
    private(set) var lastConflict: ConflictEvent?

    init(annotationsURL: URL) {
        self.annotationsURL = annotationsURL
    }

    /// Called by `CocoFileCoordinator` (via the `AnnotationStore`) after emitting a
    /// conflict sidecar. Sets `lastConflict`; the banner on `ProjectGridView` renders
    /// via `bannerMessage`.
    func receive(conflictEvent: ConflictEvent) {
        lastConflict = conflictEvent
    }

    /// Test injection point — same semantics as `receive(conflictEvent:)`.
    func inject(_ event: ConflictEvent) {
        lastConflict = event
    }

    /// Banner copy (locked string) when a conflict is present. Nil when no conflict.
    var bannerMessage: String? {
        guard lastConflict != nil else { return nil }
        return LockedCopy.conflictBanner
    }

    /// Dismisses the banner (clears `lastConflict`). Called from the banner close button.
    func dismiss() {
        lastConflict = nil
    }
}
