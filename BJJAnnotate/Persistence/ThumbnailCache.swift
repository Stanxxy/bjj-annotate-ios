import Foundation
import QuickLookThumbnailing
import UIKit

/// Off-main thumbnail provider backed by `QLThumbnailGenerator` and an `NSCache`.
///
/// AIP §4. Cache key = `"<absolutePath>|<isoModificationDate>"` so file edits invalidate.
/// Bounds: 512 entries, 64 MB total. No disk cache (QL has one already at the OS level).
actor ThumbnailCache {
    private let cache: NSCache<NSString, UIImage>
    private let requestSizePoints: CGFloat
    private let scale: CGFloat

    init(
        countLimit: Int = 512,
        totalCostLimit: Int = 64 * 1024 * 1024,
        requestSizePoints: CGFloat = 256,
        scale: CGFloat? = nil
    ) {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
        self.cache = cache
        self.requestSizePoints = requestSizePoints
        // Avoid touching `UIScreen.main.scale` from arbitrary actor contexts (it requires
        // main-thread access on some iOS versions); default to 2x and let the caller override.
        self.scale = scale ?? 2.0
    }

    /// Returns a thumbnail for `url`, generating + caching on miss. Returns nil for unsupported
    /// file types (QLThumbnailGenerator does not throw — see AIP risk R2).
    func image(for url: URL) async -> UIImage? {
        guard let key = Self.cacheKey(for: url) else { return nil }
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard let image = await Self.generate(url: url, sizePoints: requestSizePoints, scale: scale) else {
            return nil
        }
        cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
        return image
    }

    /// Test-only inspection helper: returns the cache key we'd compute for a URL right now.
    /// Exposed at internal access so unit tests can assert invalidation semantics.
    static func cacheKey(for url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return "\(url.path)|\(formatter.string(from: modDate))"
    }

    private static func generate(url: URL, sizePoints: CGFloat, scale: CGFloat) async -> UIImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: sizePoints, height: sizePoints),
            scale: scale,
            representationTypes: .thumbnail
        )
        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                continuation.resume(returning: rep?.uiImage)
            }
        }
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        return cg.bytesPerRow * cg.height
    }
}
