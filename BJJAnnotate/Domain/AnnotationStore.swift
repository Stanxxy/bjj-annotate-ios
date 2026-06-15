import Foundation
import Observation
import os

/// Typed errors surfaced by `AnnotationStore.lastError`. Phase 1 only emits these
/// from the persistence layer (read/decode/encode failures, conflict surface, iCloud
/// materialization timeout). Mutations themselves cannot fail — the store is purely
/// in-memory at the domain layer (AIP §3 Marker C).
enum AnnotationStoreError: Error, Equatable {
    case decodeFailed(description: String)
    case encodeFailed(description: String)
    case writeFailed(description: String)
    case readFailed(description: String)
    case icloudMaterializationTimeout
}

/// Protocol for the file-write scheduler. The production implementation is
/// `CocoFileCoordinator` (T8/T9); tests use `SilentScheduler` to exercise the
/// domain layer independently of disk I/O.
protocol WriteScheduling: AnyObject {
    /// Called by `AnnotationStore` after every mutation. Implementations debounce
    /// at 500ms via Task cancellation (AIP §4 / AC #23 / AC #24). NEVER call
    /// synchronously from inside the store.
    func scheduleWrite(_ payload: CocoDocument)
}

/// `@Observable` single-source-of-truth for annotation state.
///
/// AC #5: `store.coco` IS what is written to disk. No second representation.
/// AC #4: each mutating method results in exactly ONE observation invalidation —
///        achieved by replacing the entire `coco` document via a single setter call.
/// Marker C: mutation is synchronous; persistence is debounced separately.
/// Marker D: class change preserves athlete-id binding.
/// Addendum #1: Ref → Gi/NoGi auto-binds the next free athlete-id.
@Observable
@MainActor
final class AnnotationStore {
    /// Sole authoritative annotation state. Re-assignment triggers a single
    /// Observation invalidation by virtue of the macro-generated setter.
    var coco: CocoDocument

    /// Non-blocking persistence-fault surface (read/write/encode/decode/iCloud).
    var lastError: AnnotationStoreError?

    /// Non-blocking conflict surface — set by `CocoFileCoordinator` after sidecar
    /// emission (T10). UI banners on non-nil.
    var lastConflict: ConflictEvent?

    /// Active image_id (the annotator surface is per-image). Used to scope mutations
    /// to the right image_state and to filter the on-screen annotations.
    let imageId: Int

    private let scheduler: WriteScheduling
    private let logger: Logger

    init(
        initial: CocoDocument,
        imageId: Int,
        scheduler: WriteScheduling,
        logger: Logger = Logger(subsystem: "com.stanxxy.bjjannotate", category: "annotation-store")
    ) {
        self.coco = initial
        self.imageId = imageId
        self.scheduler = scheduler
        self.logger = logger
    }

    /// Clears `lastError` once the UI has acknowledged.
    func clearLastError() { lastError = nil }

    /// Clears `lastConflict` once the user has dismissed the banner.
    func clearLastConflict() { lastConflict = nil }

    // MARK: - Mutations

    /// Creates a new box OR updates an existing one. Returns the (possibly newly
    /// allocated) instance id so the caller can immediately select it.
    ///
    /// AC #16: new box auto-assigns sticky category, next-free athlete-id, source
    /// 'user', no model_version.
    /// AC #17: first ever box defaults to category 1 (gi-athlete) when sticky absent.
    @discardableResult
    func upsertBox(_ intent: BBoxIntent) -> Int {
        var next = coco
        let id: Int
        if let existing = intent.instanceId {
            id = existing
            if let idx = next.annotations.firstIndex(where: { $0.id == existing }) {
                next.annotations[idx].bbox = intent.rect.coco
                next.annotations[idx].area = intent.rect.area
            }
        } else {
            // Allocate next free instance id (max + 1 in annotations array).
            id = (next.annotations.map(\.id).max() ?? 0) + 1
            let stickyCategory = next.bjj_annotate_meta?.settings.sticky_category_id ?? 1
            let categoryId = stickyCategory  // AC #17: defaults to 1 when sticky was 1 / not set
            // Allocate athlete-id IF the new box's category is athlete (not referee).
            var athleteId: String? = nil
            if categoryId != ClassCategory.ref.rawValue,
               let allocated = AthleteRegistry.allocate(in: next.bjj_annotate_meta?.athletes ?? []) {
                athleteId = allocated.id
                next.bjj_annotate_meta?.athletes.append(allocated)
            }
            let ann = CocoAnnotation(
                id: id,
                image_id: imageId,
                category_id: categoryId,
                bbox: intent.rect.coco,
                area: intent.rect.area,
                iscrowd: 0,
                segmentation: [],
                score: nil,
                attributes: CocoAnnotationAttributes(athlete_id: athleteId, source: "user", model_version: nil),
                keypoints: categoryId == ClassCategory.ref.rawValue ? nil : [],
                num_keypoints: categoryId == ClassCategory.ref.rawValue ? nil : 0
            )
            next.annotations.append(ann)
        }
        // MARK: Undo registration site (Phase 4 hook)
        coco = next
        scheduler.scheduleWrite(coco)
        return id
    }

    /// AC #21 + Marker D: updates category, updates sticky, PRESERVES athlete-id
    /// across athlete↔athlete (Gi↔NoGi).
    ///
    /// Addendum #1 + AC #21: Ref → Gi/NoGi reclass auto-binds the next free
    /// athlete-id (mirrors AC #16 box-create behavior).
    ///
    /// Gi/NoGi → Ref reclass clears the athlete-id binding (Designer §4.2).
    func setClass(instanceId: Int, category: ClassCategory) {
        var next = coco
        guard let idx = next.annotations.firstIndex(where: { $0.id == instanceId }) else { return }
        let oldCategoryId = next.annotations[idx].category_id
        let newCategoryId = category.rawValue
        next.annotations[idx].category_id = newCategoryId

        // Athlete-id reconciliation.
        if newCategoryId == ClassCategory.ref.rawValue {
            // Athlete → Ref: clear binding (the athlete remains in the dictionary).
            next.annotations[idx].attributes.athlete_id = nil
            next.annotations[idx].keypoints = nil
            next.annotations[idx].num_keypoints = nil
        } else if oldCategoryId == ClassCategory.ref.rawValue {
            // Ref → athlete class: auto-bind next free id (Addendum #1).
            if let allocated = AthleteRegistry.allocate(in: next.bjj_annotate_meta?.athletes ?? []) {
                next.bjj_annotate_meta?.athletes.append(allocated)
                next.annotations[idx].attributes.athlete_id = allocated.id
            }
            // If full, athlete_id stays nil — UI will surface 'Project full' on picker open.
            next.annotations[idx].keypoints = []
            next.annotations[idx].num_keypoints = 0
        } else {
            // Athlete → other athlete class: athlete_id preserved (Marker D).
            // keypoints structure (empty array) preserved as well.
        }

        // Sticky category bumps for athlete-class transitions; PM AC #21 says class
        // chip updates sticky_category_id (all three classes contribute).
        next.bjj_annotate_meta?.settings.sticky_category_id = newCategoryId

        // MARK: Undo registration site (Phase 4 hook)
        coco = next
        scheduler.scheduleWrite(coco)
    }

    /// Rebinds an existing instance to a different athlete-id. Caller (the picker)
    /// has confirmed the target id exists in the athlete dictionary; this method
    /// does NOT allocate.
    func setAthleteId(instanceId: Int, athleteId: String) {
        var next = coco
        guard let idx = next.annotations.firstIndex(where: { $0.id == instanceId }) else { return }
        next.annotations[idx].attributes.athlete_id = athleteId
        // MARK: Undo registration site (Phase 4 hook)
        coco = next
        scheduler.scheduleWrite(coco)
    }

    /// Allocates a new athlete and binds it to the given instance. Returns the new
    /// athlete-id, or nil if the project is at the 8-athlete cap (caller renders
    /// 'Project full' locked string).
    @discardableResult
    func allocateAndBindAthlete(toInstanceId instanceId: Int) -> String? {
        var next = coco
        guard let allocated = AthleteRegistry.allocate(in: next.bjj_annotate_meta?.athletes ?? []) else {
            return nil
        }
        next.bjj_annotate_meta?.athletes.append(allocated)
        if let idx = next.annotations.firstIndex(where: { $0.id == instanceId }) {
            next.annotations[idx].attributes.athlete_id = allocated.id
        }
        // MARK: Undo registration site (Phase 4 hook)
        coco = next
        scheduler.scheduleWrite(coco)
        return allocated.id
    }

    /// AC #13 + Marker B: removes the box, KEEPS the athlete entry in the
    /// `bjj_annotate_meta.athletes` dictionary (never reused but never compacted).
    func deleteInstance(instanceId: Int) {
        var next = coco
        next.annotations.removeAll { $0.id == instanceId }
        // MARK: Undo registration site (Phase 4 hook)
        coco = next
        scheduler.scheduleWrite(coco)
    }
}

/// Conflict event published by the file coordinator (T10). Phase 1 carries only
/// the structural pointers; the UI banner renders the locked copy and the modal
/// shows the differing annotation ids (read-only).
struct ConflictEvent: Equatable {
    let sidecarURL: URL
    let winnerURL: URL
    let differingAnnotationIds: [Int]
}
