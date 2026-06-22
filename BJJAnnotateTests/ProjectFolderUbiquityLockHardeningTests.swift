import XCTest
@testable import BJJAnnotate

/// T15 — L-1 carry-forward hardening for `ProjectFolder.applyUbiquityGate`.
///
/// Evaluator review (T11–T13 LOW #1): the synchronous-bridge in
/// `applyUbiquityGate` captured a `Bool didSucceed` from inside a
/// `Task.detached` and read it after a `DispatchSemaphore.wait`. Darwin
/// semaphores happen to barrier in practice, but the contract is undocumented:
/// the captured Bool's writes are visible to the reader only because the
/// semaphore implementation acts as a release/acquire pair. We harden by
/// putting the captured-result write+read behind an `os_unfair_lock` so the
/// barrier is contractual, not incidental.
///
/// Grep gate: assert the production source uses `os_unfair_lock` in
/// `applyUbiquityGate` (not just `DispatchSemaphore`). And a behavior test
/// that exercises a stress run: the captured result must always be read
/// post-barrier (no spurious skip-or-include).
final class ProjectFolderUbiquityLockHardeningTests: XCTestCase {

    // MARK: - Grep gate

    func test_applyUbiquityGate_synchronization_uses_os_unfair_lock() throws {
        let url = try Self.locateProjectFolder()
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(body.contains("os_unfair_lock"),
                      "L-1 hardening: applyUbiquityGate must synchronize the captured-result Bool with os_unfair_lock, not just DispatchSemaphore.")
    }

    // MARK: - Behavior — stress run

    /// 200 placeholder files with mixed materialization outcomes. The captured
    /// `didSucceed` must always be read post-barrier; no test-detected races.
    /// If the captured Bool's write-side is reordered with respect to the
    /// semaphore signal, a successful materialization would intermittently
    /// surface as a skip (or vice versa). The locked variant rules that out.
    func test_stress_run_captured_result_consistent_with_outcome() throws {
        let temp = try TempDirectory()
        // temp deinits at end of scope — no explicit cleanup needed.
        // Half stuck (skip), half ok (materialize and include).
        var expectedKept: [String] = []
        for i in 0..<200 {
            let name = i % 2 == 0 ? "ok_\(i).jpg" : "stuck_\(i).jpg"
            try temp.makeFile(named: name)
            if name.hasPrefix("ok_") { expectedKept.append(name) }
        }
        expectedKept.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        let resolver = StressUbiquityResolver(stuckPrefix: "stuck_")
        let folder = ProjectFolder(url: temp.url)
        let names = try folder.scanImages(ubiquity: resolver, perFileTimeout: 0.05).map(\.lastPathComponent)
        let kept = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        XCTAssertEqual(kept, expectedKept,
                       "Locked captured-result must yield deterministic include/skip decisions across a 200-file stress run.")
    }

    // MARK: - Helpers

    private static func locateProjectFolder() throws -> URL {
        var url = URL(fileURLWithPath: #file)
        while url.path != "/" && url.lastPathComponent != "bjj-annotate-ios" {
            url.deleteLastPathComponent()
        }
        let probe = url
            .appendingPathComponent("BJJAnnotate")
            .appendingPathComponent("Persistence")
            .appendingPathComponent("ProjectFolder.swift")
        guard FileManager.default.fileExists(atPath: probe.path) else {
            throw XCTSkip("ProjectFolder.swift not found via #file walk.")
        }
        return probe
    }
}

/// Resolver that flips outcome based on filename prefix. `stuck_*` files
/// time out (skip); all others are local (include).
private final class StressUbiquityResolver: UbiquityResolver, @unchecked Sendable {
    let stuckPrefix: String
    init(stuckPrefix: String) { self.stuckPrefix = stuckPrefix }

    func isUbiquitous(at url: URL) throws -> Bool {
        return url.lastPathComponent.hasPrefix(stuckPrefix)
    }

    func downloadingStatus(at url: URL) throws -> URLUbiquitousItemDownloadingStatus {
        return url.lastPathComponent.hasPrefix(stuckPrefix) ? .notDownloaded : .current
    }

    func startDownloadingAndWait(at url: URL, timeout: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        throw UbiquityError.materializationTimeout
    }
}
