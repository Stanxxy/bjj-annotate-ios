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

/// Write scheduler that drops all payloads. Used by `AnnotatorLifecycleContext.make()`
/// when a decode/read failure prevents the existing `annotations.json` from loading:
/// handing back a writable scheduler pointing at the live corrupt file would let the
/// first mutation overwrite the user's data (M2 defect). `NullWriteScheduler` ensures
/// the error-state store is strictly read-only — no mutation reaches disk.
final class NullWriteScheduler: WriteScheduling {
    func scheduleWrite(_ payload: CocoDocument) {
        // Intentionally empty: all writes are dropped.
        // The store's lastError is set by the caller; the UI presents a banner.
    }
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

    /// Annotations scoped to the currently open image. Use for display and hit-testing;
    /// mutation methods locate instances by globally-unique `id` and don't need this filter.
    var annotationsForCurrentImage: [CocoAnnotation] {
        coco.annotations.filter { $0.image_id == imageId }
    }

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
            // If full, athlete_id stays nil — UI surfaces `LockedCopy.projectFullAthleteCap` on picker open.
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
    /// `LockedCopy.projectFullAthleteCap`).
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

    /// PM Addendum #2 (flag toggle): toggles the `flagged` state for the current
    /// `imageId` in `bjj_annotate_meta.image_states`. Creates the entry if absent.
    /// Follows the same single-setter pattern as all other mutations (AC #4).
    func toggleFlag() {
        var next = coco
        ImageStateTracker.toggleFlag(in: &next, imageId: imageId)
        // MARK: Undo registration site (Phase 4 hook)
        coco = next
        scheduler.scheduleWrite(coco)
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

    /// Removes an athlete from the project athlete dictionary.
    /// If any annotations reference this athlete, their athlete_id is cleared (set to nil).
    /// The no-reuse invariant is preserved: AthleteRegistry.allocate uses max(ids)+1,
    /// so the freed number is never backfilled.
    func removeAthlete(athleteId: String) {
        var next = coco
        for i in next.annotations.indices where next.annotations[i].attributes.athlete_id == athleteId {
            next.annotations[i].attributes.athlete_id = nil
        }
        next.bjj_annotate_meta?.athletes.removeAll { $0.id == athleteId }
        // MARK: Undo registration site (Phase 4 hook)
        coco = next
        scheduler.scheduleWrite(coco)
    }

    // MARK: - Phase 2 Keypoint Mutations

    /// Places or updates a single keypoint for an athlete instance.
    ///
    /// - Parameters:
    ///   - instanceId: The annotation instance id.
    ///   - keypointIndex: 1-based keypoint index (1 = nose … 17 = right_ankle).
    ///   - x: x coordinate in image pixel space.
    ///   - y: y coordinate in image pixel space.
    ///   - visibility: `KPVisibility` state to record.
    ///
    /// Silently ignores referee instances (category_id == 3).
    /// Ensures keypoints array is always 51 elements when non-nil.
    func setKeypoint(instanceId: Int, keypointIndex: Int, x: Double, y: Double, visibility: KPVisibility) {
        var next = coco
        guard let idx = next.annotations.firstIndex(where: { $0.id == instanceId }) else { return }
        // Refuse to place keypoints on referee instances.
        guard next.annotations[idx].category_id != ClassCategory.ref.rawValue else { return }
        // Validate keypoint index.
        guard keypointIndex >= 1, keypointIndex <= 17 else { return }

        // Ensure the keypoints array is exactly 51 elements.
        var kps = next.annotations[idx].keypoints ?? []
        if kps.count != 51 { kps = Array(repeating: 0.0, count: 51) }

        let offset = (keypointIndex - 1) * 3
        kps[offset]     = x
        kps[offset + 1] = y
        kps[offset + 2] = Double(visibility.rawValue)

        next.annotations[idx].keypoints = kps
        next.annotations[idx].num_keypoints = Self.countPlacedKeypoints(kps)

        // MARK: Undo registration site (Phase 4 hook)
        coco = next
        scheduler.scheduleWrite(coco)
    }

    /// Cycles the visibility of an already-placed keypoint:
    /// `notLabeled → visible → occluded → notLabeled`.
    ///
    /// If the keypoint is `notLabeled` (not placed), cycles to `visible` with
    /// the coordinates preserved (0,0 if not previously set). Silently ignores
    /// referee instances.
    func cycleKeypointVisibility(instanceId: Int, keypointIndex: Int) {
        var next = coco
        guard let idx = next.annotations.firstIndex(where: { $0.id == instanceId }) else { return }
        guard next.annotations[idx].category_id != ClassCategory.ref.rawValue else { return }
        guard keypointIndex >= 1, keypointIndex <= 17 else { return }

        var kps = next.annotations[idx].keypoints ?? []
        if kps.count != 51 { kps = Array(repeating: 0.0, count: 51) }

        let offset = (keypointIndex - 1) * 3
        let currentVis = KPVisibility(rawValue: Int(kps[offset + 2])) ?? .notLabeled
        let nextVis: KPVisibility
        switch currentVis {
        case .notLabeled: nextVis = .visible
        case .visible:    nextVis = .occluded
        case .occluded:   nextVis = .notLabeled
        }
        kps[offset + 2] = Double(nextVis.rawValue)

        next.annotations[idx].keypoints = kps
        next.annotations[idx].num_keypoints = Self.countPlacedKeypoints(kps)

        // MARK: Undo registration site (Phase 4 hook)
        coco = next
        scheduler.scheduleWrite(coco)
    }

    /// Mirrors all 8 L↔R keypoint pairs for the given athlete instance.
    ///
    /// Visibility flags travel with the position (if the left shoulder was
    /// `occluded`, after mirror the swapped right-shoulder slot is also `occluded`).
    /// No-op if the instance is a referee.
    func mirrorKeypoints(instanceId: Int) {
        var next = coco
        guard let idx = next.annotations.firstIndex(where: { $0.id == instanceId }) else { return }
        guard next.annotations[idx].category_id != ClassCategory.ref.rawValue else { return }

        var kps = next.annotations[idx].keypoints ?? []
        if kps.count != 51 { kps = Array(repeating: 0.0, count: 51) }

        next.annotations[idx].keypoints = KeypointMirror.mirror(kps)
        // num_keypoints count is unchanged by mirroring (same set of placed points).

        // MARK: Undo registration site (Phase 4 hook)
        coco = next
        scheduler.scheduleWrite(coco)
    }

    // MARK: - Private helpers

    /// Counts keypoints whose visibility is NOT `notLabeled` (raw value > 0).
    /// Operates on a 51-element flat array; stride of 3 reads every visibility slot.
    private static func countPlacedKeypoints(_ kps: [Double]) -> Int {
        var count = 0
        var i = 2
        while i < kps.count {
            if kps[i] > 0 { count += 1 }
            i += 3
        }
        return count
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
