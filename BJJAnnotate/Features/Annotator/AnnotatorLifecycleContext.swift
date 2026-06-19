import Foundation
import os

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
    /// Returns 1 if the image is not found in the scan (defensive; should not
    /// happen in normal use — the grid only passes URLs it received from the same scan).
    static func imageId(
        for imageURL: URL,
        in folderURL: URL,
        ubiquity: any UbiquityResolver = SystemUbiquityResolver()
    ) throws -> Int {
        let folder = ProjectFolder(url: folderURL)
        let images = try folder.scanImages(ubiquity: ubiquity)
        if let idx = images.firstIndex(of: imageURL) {
            return idx + 1  // 1-based
        }
        // Fallback: the image may have been passed with a slightly different URL
        // (e.g. symlink vs resolved path). Try last-path-component match.
        let imageName = imageURL.lastPathComponent
        if let idx = images.firstIndex(where: { $0.lastPathComponent == imageName }) {
            return idx + 1
        }
        return 1
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
    /// - Throws: `CocoFileCoordinatorError` on decode failure (not on missing file — first open
    ///           with no `annotations.json` returns an empty bootstrap document).
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
        let imgId: Int
        do {
            imgId = try imageId(for: imageURL, in: folderURL, ubiquity: ubiquity)
        } catch {
            logger.warning("Failed to scan folder for imageId — defaulting to 1: \(error.localizedDescription, privacy: .public)")
            imgId = 1
        }

        // Try to read the existing annotations.json.
        let adapter = CocoWriteSchedulingAdapter(coordinator: coordinator)
        let store: AnnotationStore

        if FileManager.default.fileExists(atPath: annotationsURL.path) {
            do {
                let doc = try await coordinator.readDocument()
                store = AnnotationStore(initial: doc, imageId: imgId, scheduler: adapter)
            } catch {
                // Decode failure: surface via lastError but fall back to bootstrap so the
                // user can still annotate (they will see the banner). This is the only
                // "fallback" in Phase 1 and is explicitly allowed: the store is not a
                // SECOND source of truth — the old file still exists on disk unchanged.
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
                let bootstrap = Self.makeBootstrapDocument(imageURL: imageURL, imageId: imgId)
                store = AnnotationStore(initial: bootstrap, imageId: imgId, scheduler: adapter)
                store.lastError = storeError
            }
        } else {
            // First open — no existing annotations.json.
            let bootstrap = Self.makeBootstrapDocument(imageURL: imageURL, imageId: imgId)
            store = AnnotationStore(initial: bootstrap, imageId: imgId, scheduler: adapter)
        }

        return AnnotatorLifecycleContext(store: store, coordinator: coordinator)
    }

    // MARK: - Private

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
