import Foundation

/// Scans a project folder for image files at the root level only.
///
/// PM AC #10: `.jpg/.jpeg/.png/.heic` only (case-insensitive); subdirectories are NOT recursed;
/// directories (notably `.mlpackage`) are excluded even though the extension whitelist is
/// strict (defense-in-depth — covers e.g. a hypothetical `foo.jpg` directory).
///
/// T11: scanImages consults an iCloud `UbiquityResolver` to materialize placeholders
/// before returning. Files that fail to materialize within `perFileTimeout` are
/// SKIPPED — they are not surfaced as errors (other images may have succeeded and
/// the user can pull-to-refresh once iCloud catches up). Closes Phase 0 V3/V5
/// deferral (`iCloudUbiquitousItemGap` insight).
struct ProjectFolder {
    let url: URL

    /// Accepted file extensions, lowercased. Exactly the four PM AC #10 calls out.
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic"]

    /// Default budget for materializing a single iCloud placeholder during a scan.
    /// Smaller than the read-path 10s budget because the scan is bulk; if any single
    /// file is slow, the user is better served by it being skipped (visible in next
    /// pull-to-refresh) than by the whole scan blocking.
    static let defaultPerFileTimeout: TimeInterval = 2.0

    init(url: URL) {
        self.url = url
    }

    /// Returns image URLs at the root of the folder, sorted ascending by filename
    /// (case-insensitive — matches Files.app + Photos.app behavior).
    ///
    /// - Parameters:
    ///   - ubiquity: iCloud resolver. Production passes `SystemUbiquityResolver()`;
    ///     tests inject `FakeUbiquityResolver`.
    ///   - perFileTimeout: maximum time spent materializing any single iCloud
    ///     placeholder. Files that exceed this are skipped.
    func scanImages(
        ubiquity: any UbiquityResolver = SystemUbiquityResolver(),
        perFileTimeout: TimeInterval = ProjectFolder.defaultPerFileTimeout
    ) throws -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        let items = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        let candidates = items
            .filter { Self.isImageFile($0) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        return Self.applyUbiquityGate(candidates, ubiquity: ubiquity, timeout: perFileTimeout)
    }

    // MARK: - Helpers

    private static func isImageFile(_ url: URL) -> Bool {
        // Exclude directories (covers .mlpackage and any other bundle / directory the user
        // dropped into the folder). Two-layer guard: directory check first, extension whitelist
        // second.
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        if values?.isDirectory == true { return false }
        return imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Synchronously walks the candidate list and trims any iCloud placeholders that
    /// cannot be materialized within `timeout`. Local files are never blocked on.
    private static func applyUbiquityGate(
        _ candidates: [URL],
        ubiquity: any UbiquityResolver,
        timeout: TimeInterval
    ) -> [URL] {
        var resolved: [URL] = []
        resolved.reserveCapacity(candidates.count)
        for candidate in candidates {
            // Decide ubiquity status; if the call throws, treat the file as
            // unavailable and skip (best signal we have without iCloud).
            let isUbiquitous: Bool
            do {
                isUbiquitous = try ubiquity.isUbiquitous(at: candidate)
            } catch {
                continue
            }
            if !isUbiquitous {
                resolved.append(candidate)
                continue
            }
            // Ubiquitous: only block if it's not already current.
            let status: URLUbiquitousItemDownloadingStatus
            do {
                status = try ubiquity.downloadingStatus(at: candidate)
            } catch {
                continue
            }
            if status == .current || status == .downloaded {
                resolved.append(candidate)
                continue
            }
            // Placeholder: try to materialize within the per-file budget.
            let semaphore = DispatchSemaphore(value: 0)
            var didSucceed = false
            Task.detached {
                do {
                    try await ubiquity.startDownloadingAndWait(at: candidate, timeout: timeout)
                    didSucceed = true
                } catch {
                    didSucceed = false
                }
                semaphore.signal()
            }
            // Wait at most timeout + small slack (handles the sleep-then-throw path).
            let waitResult = semaphore.wait(timeout: .now() + .milliseconds(Int(timeout * 1000) + 200))
            if waitResult == .success && didSucceed {
                resolved.append(candidate)
            }
            // Else: skip silently per T11 contract.
        }
        return resolved
    }
}
