import Foundation

/// Owns the per-image meta fields (`visited_at`, `flagged`).
///
/// Phase 1 surface:
///  - `markVisited()` — fired by `AnnotatorView.task` on first appearance of an
///    image. Establishes the `image_state` row.
///  - `setFlagged(_:)` — fired by the top-bar flag toggle (Designer Addendum §2).
///
/// `ImageStateTracker` is a thin facade over `AnnotationStore`: every method ends
/// in a single `store.coco = ...` assignment so the observation invariant from
/// AC #4 holds (one invalidation per logical user action).
@MainActor
final class ImageStateTracker {
    private weak var store: AnnotationStore?

    init(store: AnnotationStore) {
        self.store = store
    }

    /// Records that the current image was opened. Idempotent: if an entry already
    /// exists, `visited_at` is bumped to now (which keeps MRU semantics if the
    /// store ever surfaces them).
    func markVisited() {
        applyImageState { $0.visited_at = Self.nowISO8601() }
    }

    /// Toggles the per-image flag. Creates an image_state entry if absent.
    func setFlagged(_ on: Bool) {
        applyImageState { $0.flagged = on }
    }

    // MARK: - Private

    private func applyImageState(_ mutate: (inout ImageState) -> Void) {
        guard let store = store else { return }
        var next = store.coco
        guard next.bjj_annotate_meta != nil else { return }
        let imageId = store.imageId
        if let idx = next.bjj_annotate_meta!.image_states.firstIndex(where: { $0.image_id == imageId }) {
            mutate(&next.bjj_annotate_meta!.image_states[idx])
        } else {
            var fresh = ImageState(image_id: imageId, visited_at: Self.nowISO8601(), flagged: false)
            mutate(&fresh)
            next.bjj_annotate_meta!.image_states.append(fresh)
        }
        store.coco = next
    }

    private static func nowISO8601() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}
