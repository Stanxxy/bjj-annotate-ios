import Foundation
@testable import BJJAnnotate

/// Scriptable iCloud ubiquity resolver for unit tests (AIP §5 / Marker E).
///
/// Production code uses `SystemUbiquityResolver` which calls the real Foundation
/// APIs (`URLResourceKey.isUbiquitousItemKey`, `startDownloadingUbiquitousItem(at:)`).
/// Tests inject `FakeUbiquityResolver` to drive the placeholder → current state
/// transition without iCloud or simulator entanglement.
final class FakeUbiquityResolver: UbiquityResolver, @unchecked Sendable {
    /// Return value for `isUbiquitous(at:)`.
    var isUbiquitousResult: Bool = false
    /// Sequence of statuses returned by successive `downloadingStatus(at:)` calls.
    /// When the queue empties, the last returned value is reused.
    var statusQueue: [URLUbiquitousItemDownloadingStatus] = []
    /// Throw on next `startDownloadingAndWait` invocation (simulates a Foundation
    /// `startDownloadingUbiquitousItem` raise).
    var throwOnStartDownload: Error? = nil

    private(set) var isUbiquitousCalls: [URL] = []
    private(set) var statusCalls: [URL] = []
    private(set) var startDownloadCalls: [URL] = []

    func isUbiquitous(at url: URL) throws -> Bool {
        isUbiquitousCalls.append(url)
        return isUbiquitousResult
    }

    func downloadingStatus(at url: URL) throws -> URLUbiquitousItemDownloadingStatus {
        statusCalls.append(url)
        if statusQueue.count > 1 {
            return statusQueue.removeFirst()
        }
        return statusQueue.first ?? .current
    }

    func startDownloadingAndWait(at url: URL, timeout: TimeInterval) async throws {
        startDownloadCalls.append(url)
        if let throwError = throwOnStartDownload { throw throwError }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let status = try downloadingStatus(at: url)
            if status == .current || status == .downloaded { return }
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms poll for test speed
        }
        throw UbiquityError.materializationTimeout
    }
}
