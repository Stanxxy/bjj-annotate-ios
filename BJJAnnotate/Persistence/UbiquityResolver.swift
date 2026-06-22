import Foundation

/// Errors surfaced from `UbiquityResolver`. The most important is
/// `materializationTimeout` which `CocoFileCoordinator` maps to
/// `AnnotationStoreError.icloudMaterializationTimeout` and the locked banner copy
/// `LockedCopy.icloudWaitingBanner` (AC #30).
enum UbiquityError: Error, Equatable {
    case materializationTimeout
    case startDownloadFailed(String)
}

/// Seam for iCloud ubiquitous-item materialization (Marker E).
///
/// Phase 0 V3 + V5 were deferred citing this gap (`iCloudUbiquitousItemGap` insight
/// in the KB). Phase 1 closes it by introducing this protocol; the production
/// `SystemUbiquityResolver` calls the real Foundation APIs and `FakeUbiquityResolver`
/// (test bundle) lets unit tests drive the placeholder → current transition without
/// iCloud or the simulator's ubiquity container.
protocol UbiquityResolver: Sendable {
    /// Whether the URL is managed by iCloud.
    func isUbiquitous(at url: URL) throws -> Bool

    /// Current downloading status (`.current`, `.downloaded`, `.notDownloaded`).
    func downloadingStatus(at url: URL) throws -> URLUbiquitousItemDownloadingStatus

    /// Triggers a download and awaits materialization up to `timeout`. Throws
    /// `UbiquityError.materializationTimeout` if the file is still a placeholder
    /// after the timeout elapses.
    func startDownloadingAndWait(at url: URL, timeout: TimeInterval) async throws
}

/// Production implementation. Uses Foundation's iCloud APIs verbatim.
struct SystemUbiquityResolver: UbiquityResolver {
    func isUbiquitous(at url: URL) throws -> Bool {
        let v = try url.resourceValues(forKeys: [.isUbiquitousItemKey])
        return v.isUbiquitousItem ?? false
    }

    func downloadingStatus(at url: URL) throws -> URLUbiquitousItemDownloadingStatus {
        let v = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        return v.ubiquitousItemDownloadingStatus ?? .current
    }

    func startDownloadingAndWait(at url: URL, timeout: TimeInterval) async throws {
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            throw UbiquityError.startDownloadFailed(error.localizedDescription)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let status = try downloadingStatus(at: url)
            if status == .current || status == .downloaded { return }
            try await Task.sleep(nanoseconds: 200_000_000) // 200ms poll
        }
        throw UbiquityError.materializationTimeout
    }
}
