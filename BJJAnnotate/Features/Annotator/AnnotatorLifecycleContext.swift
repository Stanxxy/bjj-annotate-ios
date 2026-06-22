import Foundation
import os

/// Errors thrown by `AnnotatorLifecycleContext` factory and helpers.
enum AnnotatorLifecycleError: Error, Equatable {
    /// The image URL could not be located in the sorted folder scan.
    /// Returning a default id (e.g. 1) would scope annotations to the wrong image — forbidden.
    case imageNotFoundInFolder(imageURL: URL, folderURL: URL)
    /// The folder scan itself failed.
    case folderScanFailed(description: String)
    /// The existing annotations.json could not be decoded; the file is preserved unchanged.
    case decodeFailed(description: String)
}

/// Per-project annotation lifecycle context. Created when `AnnotatorView` appears
/// and torn down when the view disappears.
///
/// I1 decision: the store is per-PROJECT (one `CocoDocument` for the whole folder),
/// not per-image. The COCO file (`annotations.json`) is per-project; `AnnotationStore`
/// is instantiated once per project folder and uses `imageId` to scope mutations to
/// the current image. This matches the AIP §3 design: one `var coco: CocoDocument`
/// on the store, accessed from any image.
///
/// `imageId` is the 1-based position of the image file in the sorted scan of the
/// project folder — consistent across openings of the same image from the same folder.
///
/// Thread-safety: `make(...)` is async and must be called from `@MainActor` context
/// (it immediately hops to a background task for I/O). The returned context is
/// `@MainActor`-bound via `AnnotationStore`.
@MainActor
struct AnnotatorLifecycleContext {
    let store: AnnotationStore
    let coordinator: CocoFileCoordinator
    /// The write adapter; exposed so tests can call `adapter.flushNow()` which
    /// supplies the latest payload as a fallback, resolving the adapter-task race
    /// between `scheduleWrite(payload)` and an immediate `coordinator.flushNow()`.
    /// Production code uses `LifecycleFlushBridge.flushSynchronously(coordinator:)`.
    let adapter: CocoWriteSchedulingAdapter?

    // MARK: - Bootstrap

    /// Three canonical BJJ categories in COCO Keypoints 1.0 format.
    static func bootstrapCategories() -> [CocoCategory] {
        return [
            CocoCategory(
                id: ClassCategory.gi.rawValue,
                name: "gi-athlete",
                supercategory: "person",
                keypoints: [],
                skeleton: []
            ),
            CocoCategory(
                id: ClassCategory.nogi.rawValue,
                name: "nogi-athlete",
                supercategory: "person",
                keypoints: [],
                skeleton: []
            ),
            CocoCategory(
                id: ClassCategory.ref.rawValue,
                name: "referee",
                supercategory: "person",
                keypoints: nil,
                skeleton: nil
            ),
        ]
    }

    /// Derives the 1-based imageId for the given imageURL within the folder.
    ///
    /// Throws `AnnotatorLifecycleError.folderScanFailed` if the folder cannot be scanned.
    /// Throws `AnnotatorLifecycleError.imageNotFoundInFolder` if the image is absent from
    /// the sorted scan — returning a default (e.g. `1`) is FORBIDDEN because it would scope
    /// annotations to a DIFFERENT image's id (cross-contamination, M3 defect).
    ///
    /// The caller (`make(...)`) propagates this as a thrown error so the annotator never
    /// opens with a silently incorrect imageId.
    static func imageId(
        for imageURL: URL,
        in folderURL: URL,
        ubiquity: any UbiquityResolver = SystemUbiquityResolver()
    ) throws -> Int {
        let folder = ProjectFolder(url: folderURL)
        let images: [URL]
        do {
            images = try folder.scanImages(ubiquity: ubiquity)
        } catch {
            throw AnnotatorLifecycleError.folderScanFailed(description: error.localizedDescription)
        }
        if let idx = images.firstIndex(of: imageURL) {
            return idx + 1  // 1-based
        }
        // Try last-path-component match to handle symlink vs resolved path differences.
        let imageName = imageURL.lastPathComponent
        if let idx = images.firstIndex(where: { $0.lastPathComponent == imageName }) {
            return idx + 1
        }
        // Image not found in the sorted scan: throw rather than default to 1.
        // Defaulting to 1 would silently annotate the wrong image (M3 defect — FORBIDDEN).
        throw AnnotatorLifecycleError.imageNotFoundInFolder(imageURL: imageURL, folderURL: folderURL)
    }

    // MARK: - Factory

    /// Creates (or loads) the per-project annotation lifecycle for the given image.
    ///
    /// - Parameters:
    ///   - folderURL: the project folder (parent of the images + `annotations.json`).
    ///   - imageURL: the specific image being opened in the annotator.
    ///   - ubiquity: iCloud resolver (injectable for tests; production uses `SystemUbiquityResolver`).
    ///   - debounceNanos: debounce interval for the write scheduler. Tests pass a shorter value.
    /// - Returns: a fully initialized context with `store` loaded from disk (or bootstrapped).
    /// - Throws: `AnnotatorLifecycleError.imageNotFoundInFolder` / `.folderScanFailed` if the
    ///           imageId cannot be determined (M3 fix: no silent default to 1).
    ///           First-open (no `annotations.json`) returns an empty bootstrap and does not throw.
    ///           Decode failure returns a READ-ONLY error-state store (M2 fix: no writable bootstrap
    ///           on top of the corrupt live file).
    static func make(
        folderURL: URL,
        imageURL: URL,
        ubiquity: any UbiquityResolver = SystemUbiquityResolver(),
        debounceNanos: UInt64 = 500_000_000,
        logger: Logger = Logger(subsystem: "com.stanxxy.bjjannotate", category: "lifecycle-context")
    ) async throws -> AnnotatorLifecycleContext {
        let annotationsURL = folderURL.appendingPathComponent("annotations.json")
        let coordinator = CocoFileCoordinator(
            url: annotationsURL,
            ubiquity: ubiquity,
            ubiquityTimeout: 10.0,
            debounceNanos: debounceNanos
        )

        // Derive imageId synchronously (ProjectFolder.scanImages is sync).
        // M3 fix: imageId(for:in:) now throws on scan-failure or not-found.
        // We propagate the error — no silent default to 1, which would cross-contaminate
        // annotations onto a different image's id.
        let imgId = try imageId(for: imageURL, in: folderURL, ubiquity: ubiquity)

        // Try to read the existing annotations.json.
        let adapter = CocoWriteSchedulingAdapter(coordinator: coordinator)
        let store: AnnotationStore

        if FileManager.default.fileExists(atPath: annotationsURL.path) {
            do {
                let doc = try await coordinator.readDocument()
                let migratedDoc = Self.backfillAthleteIds(doc)
                store = AnnotationStore(initial: migratedDoc, imageId: imgId, scheduler: adapter)
            } catch {
                // M2 fix: decode / read failure must NOT hand back a writable bootstrap
                // pointed at the LIVE annotations.json. The writable adapter would let the
                // first mutation overwrite the user's real (un-decodable) annotations with
                // an empty bootstrap — a data-loss path.
                //
                // Instead: return a store backed by a NullWriteScheduler so NO mutations
                // reach disk. The lastError banner will show; the user must navigate back
                // and resolve the corrupt file externally (Files.app, iCloud restore, etc.)
                // before annotating. The corrupt file is preserved unchanged on disk.
                let storeError: AnnotationStoreError
                if let ce = error as? CocoFileCoordinatorError {
                    switch ce {
                    case .decodeFailed(let d): storeError = .decodeFailed(description: d)
                    case .readFailed(let d): storeError = .readFailed(description: d)
                    case .icloudMaterializationTimeout: storeError = .icloudMaterializationTimeout
                    default: storeError = .readFailed(description: error.localizedDescription)
                    }
                } else {
                    storeError = .readFailed(description: error.localizedDescription)
                }
                logger.error("AnnotatorLifecycleContext: read/decode failure — opening read-only error state. Error: \(String(describing: error), privacy: .public)")
                // Bootstrap document is shown in-memory only (no disk interaction possible).
                // NullWriteScheduler blocks any mutation from reaching the coordinator/disk.
                let bootstrap = Self.makeBootstrapDocument(imageURL: imageURL, imageId: imgId)
                let nullScheduler = NullWriteScheduler()
                store = AnnotationStore(initial: bootstrap, imageId: imgId, scheduler: nullScheduler)
                store.lastError = storeError
                // Return immediately — no conflict wiring needed (store is read-only).
                // adapter is nil: NullWriteScheduler is in use, nothing to flush.
                return AnnotatorLifecycleContext(store: store, coordinator: coordinator, adapter: nil)
            }
        } else {
            // First open — no existing annotations.json. Bootstrap + live scheduler.
            let bootstrap = Self.makeBootstrapDocument(imageURL: imageURL, imageId: imgId)
            store = AnnotationStore(initial: bootstrap, imageId: imgId, scheduler: adapter)
        }

        // B2 fix: wire conflict detection from coordinator → store.lastConflict.
        // The coordinator calls this handler (on a background task) after emitting a sidecar.
        // We hop to @MainActor to set store.lastConflict safely.
        await coordinator.setConflictHandler { [store] event in
            Task { @MainActor in
                store.lastConflict = event
            }
        }

        return AnnotatorLifecycleContext(store: store, coordinator: coordinator, adapter: adapter)
    }

    // MARK: - Private

    /// Backfill athlete_id for annotations that are athlete-category but have nil athlete_id.
    /// This repairs data created before the allocation code was stable.
    /// Safe to run multiple times (idempotent — only touches nil athlete_ids).
    ///
    /// Ghost-athlete purge: athletes listed in meta but referenced by zero annotations
    /// are removed first. Without this, a cap-full ghost list (8 entries, 0 referenced)
    /// blocks AthleteRegistry.allocate from assigning real slots, leaving every row "—".
    private static func backfillAthleteIds(_ doc: CocoDocument) -> CocoDocument {
        var result = doc
        guard result.bjj_annotate_meta != nil else { return result }

        // Remove athletes not referenced by any annotation so the allocator has room.
        let referencedIds = Set(
            result.annotations
                .filter { $0.category_id != ClassCategory.ref.rawValue }
                .compactMap { $0.attributes.athlete_id }
        )
        let validAthletes = (result.bjj_annotate_meta?.athletes ?? [])
            .filter { referencedIds.contains($0.id) }
        result.bjj_annotate_meta?.athletes = validAthletes

        // Allocate fresh ids for annotations that have none.
        for i in result.annotations.indices {
            let ann = result.annotations[i]
            guard ann.category_id != ClassCategory.ref.rawValue,
                  ann.attributes.athlete_id == nil else { continue }
            if let allocated = AthleteRegistry.allocate(in: result.bjj_annotate_meta?.athletes ?? []) {
                result.annotations[i].attributes.athlete_id = allocated.id
                result.bjj_annotate_meta?.athletes.append(allocated)
            }
        }
        return result
    }

    private static func makeBootstrapDocument(imageURL: URL, imageId: Int) -> CocoDocument {
        let imageName = imageURL.lastPathComponent
        // Derive width/height: if the image can be loaded, use real dimensions.
        // If not (e.g. test fixture), use 0 — COCO allows 0 for unknown dimensions.
        let imageSize: (w: Int, h: Int)
        if let uiImg = UIImage(contentsOfFile: imageURL.path) {
            imageSize = (Int(uiImg.size.width), Int(uiImg.size.height))
        } else {
            imageSize = (0, 0)
        }
        return CocoDocument(
            info: CocoInfo(
                contributor: "BJJAnnotate",
                date_created: ISO8601DateFormatter().string(from: Date()),
                description: "BJJAnnotate Phase 1",
                version: "1.0",
                year: Calendar.current.component(.year, from: Date())
            ),
            images: [
                CocoImage(
                    id: imageId,
                    file_name: imageName,
                    width: imageSize.w,
                    height: imageSize.h
                )
            ],
            categories: bootstrapCategories(),
            annotations: [],
            bjj_annotate_meta: BjjAnnotateMeta(
                schema_version: 1,
                athletes: [],
                image_states: [],
                settings: MetaSettings(sticky_category_id: 1)
            )
        )
    }
}

// MARK: - UIImage import guard

import UIKit
