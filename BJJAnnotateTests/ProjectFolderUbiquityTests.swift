import XCTest
@testable import BJJAnnotate

/// T11 — `ProjectFolder.scanImages` ubiquity back-apply.
///
/// Phase 0 V3 + V5 were deferred citing the `iCloudUbiquitousItemGap` insight:
/// `scanImages` synchronously enumerates the directory and may return URLs that
/// are iCloud placeholders (not yet materialized). Phase 1 closes the gap by
/// having scanImages consult a `UbiquityResolver` and either:
///   (a) trigger materialization and wait (within a tight per-file budget), or
///   (b) skip placeholders that fail to materialize.
///
/// Production wires `SystemUbiquityResolver`; tests inject `FakeUbiquityResolver`.
final class ProjectFolderUbiquityTests: XCTestCase {

    private var temp: TempDirectory!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temp = try TempDirectory()
    }

    override func tearDown() {
        temp = nil
        super.tearDown()
    }

    /// Happy path: resolver says the file is ubiquitous, status sequence reports
    /// `.notDownloaded` then `.current`. scanImages awaits materialization and
    /// includes the file in the result.
    func test_scanImages_with_fake_resolver_returns_after_materialization() throws {
        try temp.makeFile(named: "cloudy.jpg")
        let resolver = FakeUbiquityResolver()
        resolver.isUbiquitousResult = true
        resolver.statusQueue = [.notDownloaded, .current]

        let folder = ProjectFolder(url: temp.url)
        let names = try folder.scanImages(ubiquity: resolver, perFileTimeout: 0.5).map(\.lastPathComponent)

        XCTAssertEqual(names, ["cloudy.jpg"])
        XCTAssertEqual(resolver.startDownloadCalls.count, 1,
                       "Placeholder must trigger startDownloadingAndWait exactly once per file")
    }

    /// Failure path: resolver reports ubiquitous, but materialization times out.
    /// scanImages SKIPS the file (does not throw — other images may have succeeded).
    func test_scanImages_skips_placeholders_that_time_out() throws {
        try temp.makeFile(named: "stuck.jpg")
        try temp.makeFile(named: "ok.jpg")

        // First call (stuck.jpg) times out; second (ok.jpg) is local.
        let resolver = StubbornUbiquityResolver(
            stuckNames: ["stuck.jpg"]
        )

        let folder = ProjectFolder(url: temp.url)
        let names = try folder.scanImages(ubiquity: resolver, perFileTimeout: 0.05).map(\.lastPathComponent)

        XCTAssertEqual(names, ["ok.jpg"],
                       "Placeholders that fail to materialize must be skipped, not surfaced as errors")
    }

    /// Default-arg call still compiles and uses SystemUbiquityResolver; the
    /// existing Phase 0 callers (ProjectGridViewModel.load) do not need to change.
    func test_default_resolver_call_is_compatible_with_legacy_call_sites() throws {
        try temp.makeFile(named: "local.jpg")
        let folder = ProjectFolder(url: temp.url)
        // No argument list — exercises the default-parameter overload.
        let names = try folder.scanImages().map(\.lastPathComponent)
        XCTAssertEqual(names, ["local.jpg"])
    }
}

/// Per-file scriptable resolver: marks specific filenames as stuck-in-cloud
/// placeholders, the rest as local.
private final class StubbornUbiquityResolver: UbiquityResolver, @unchecked Sendable {
    let stuckNames: Set<String>
    init(stuckNames: [String]) { self.stuckNames = Set(stuckNames) }

    func isUbiquitous(at url: URL) throws -> Bool {
        return stuckNames.contains(url.lastPathComponent)
    }

    func downloadingStatus(at url: URL) throws -> URLUbiquitousItemDownloadingStatus {
        return stuckNames.contains(url.lastPathComponent) ? .notDownloaded : .current
    }

    func startDownloadingAndWait(at url: URL, timeout: TimeInterval) async throws {
        if stuckNames.contains(url.lastPathComponent) {
            // Simulate Foundation's wait-then-timeout cleanly.
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            throw UbiquityError.materializationTimeout
        }
    }
}
