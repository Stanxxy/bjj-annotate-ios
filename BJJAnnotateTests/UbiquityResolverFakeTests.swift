import XCTest
@testable import BJJAnnotate

/// `FakeUbiquityResolver` is the test seam for iCloud materialization paths
/// (Marker E). It records calls and returns scripted statuses so unit tests
/// can drive the placeholder → downloading → current state transitions without
/// touching iCloud or the simulator's ubiquity container.
final class UbiquityResolverFakeTests: XCTestCase {

    func test_fake_isUbiquitous_returns_scripted_value() throws {
        let fake = FakeUbiquityResolver()
        fake.isUbiquitousResult = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("x.json")
        XCTAssertTrue(try fake.isUbiquitous(at: url))
        XCTAssertEqual(fake.isUbiquitousCalls.count, 1)
    }

    func test_fake_downloadingStatus_returns_scripted_value() throws {
        let fake = FakeUbiquityResolver()
        fake.statusQueue = [.notDownloaded, .downloaded, .current]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("x.json")
        XCTAssertEqual(try fake.downloadingStatus(at: url), .notDownloaded)
        XCTAssertEqual(try fake.downloadingStatus(at: url), .downloaded)
        XCTAssertEqual(try fake.downloadingStatus(at: url), .current)
    }

    func test_fake_startDownloadingAndWait_returns_when_status_becomes_current() async throws {
        let fake = FakeUbiquityResolver()
        // First call yields .notDownloaded, second yields .current — simulates the
        // placeholder → materialized transition.
        fake.statusQueue = [.notDownloaded, .current]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("x.json")
        try await fake.startDownloadingAndWait(at: url, timeout: 5.0)
        XCTAssertEqual(fake.startDownloadCalls.count, 1)
    }

    func test_fake_startDownloadingAndWait_throws_timeout_when_never_materializes() async {
        let fake = FakeUbiquityResolver()
        fake.statusQueue = [.notDownloaded, .notDownloaded, .notDownloaded]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("x.json")
        do {
            try await fake.startDownloadingAndWait(at: url, timeout: 0.05)
            XCTFail("Expected timeout")
        } catch let UbiquityError.materializationTimeout {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
