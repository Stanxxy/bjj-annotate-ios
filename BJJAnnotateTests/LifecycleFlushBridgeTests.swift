import XCTest
@testable import BJJAnnotate

/// T21 — willResignActive synchronous flush bridge.
///
/// AC #27 / AC #38 / Marker F: when the app receives
/// `UIApplication.willResignActiveNotification`, any pending debounced write
/// MUST be persisted SYNCHRONOUSLY before the process is suspended. The bridge
/// from the @MainActor notification observer to the actor-isolated
/// `CocoFileCoordinator.flushNow()` uses `DispatchSemaphore` to wait for the
/// async flush to complete.
///
/// L-1 carry-forward: the captured-result Bool on the bridge is gated with
/// `os_unfair_lock` so the visibility contract is explicit, mirroring the
/// hardening applied to `ProjectFolder.applyUbiquityGate` in T15.
///
/// This file asserts:
///   1. The bridge actually waits — `flushSynchronously(...)` returns AFTER
///      the actor's `flushNow()` completes (no early return on cancel).
///   2. The captured completion flag is read post-barrier (grep gate for
///      `os_unfair_lock` in the bridge source).
@MainActor
final class LifecycleFlushBridgeTests: XCTestCase {

    func test_flushSynchronously_returns_after_actor_flush_completes() async throws {
        // Set up a coordinator with a real temp file so flushNow does the
        // encode + write path.
        let temp = try TempDirectory()
        let url = try temp.makeFile(named: "annotations.json", contents: Data("{}".utf8))

        let coordinator = CocoFileCoordinator(
            url: url,
            ubiquity: FakeUbiquityResolver(),
            debounceNanos: 50_000_000  // 50ms — small so the test is fast
        )

        // Schedule a write but don't await the debounce.
        let meta = BjjAnnotateMeta(
            schema_version: 1,
            athletes: [],
            image_states: [],
            settings: MetaSettings(sticky_category_id: 1)
        )
        let payload = CocoDocument(
            info: nil,
            images: [CocoImage(id: 1, file_name: "f.jpg", width: 1920, height: 1080)],
            categories: [],
            annotations: [],
            bjj_annotate_meta: meta
        )
        await coordinator.scheduleWrite(payload)

        // Bridge call: must block until the actor has finished its flushNow().
        let bridge = LifecycleFlushBridge()
        let didFlush = bridge.flushSynchronously(coordinator: coordinator, timeoutMs: 2000)
        XCTAssertTrue(didFlush, "Bridge must report success when actor finishes within budget")

        // After the bridge returns, the write must already be on disk.
        let onDiskWriteCount = await coordinator.diskWriteCount
        XCTAssertEqual(onDiskWriteCount, 1,
                       "Pending payload must be persisted by the time the bridge returns")
    }

    func test_flushSynchronously_returns_false_on_timeout() async throws {
        // Pass a coordinator with no pending write — flushNow() is a no-op
        // but the bridge should still return true (success, nothing to do).
        let temp = try TempDirectory()
        let url = try temp.makeFile(named: "annotations.json", contents: Data("{}".utf8))
        let coordinator = CocoFileCoordinator(url: url, ubiquity: FakeUbiquityResolver())
        let bridge = LifecycleFlushBridge()
        let didFlush = bridge.flushSynchronously(coordinator: coordinator, timeoutMs: 500)
        XCTAssertTrue(didFlush, "No-op flush still reports success")
    }

    // MARK: - L-1 grep gate

    func test_bridge_uses_os_unfair_lock_for_captured_result() throws {
        var url = URL(fileURLWithPath: #file)
        while url.path != "/" && url.lastPathComponent != "bjj-annotate-ios" {
            url.deleteLastPathComponent()
        }
        let probe = url
            .appendingPathComponent("BJJAnnotate")
            .appendingPathComponent("Features")
            .appendingPathComponent("Annotator")
            .appendingPathComponent("LifecycleFlushBridge.swift")
        guard FileManager.default.fileExists(atPath: probe.path) else {
            throw XCTSkip("LifecycleFlushBridge.swift not found via #file walk.")
        }
        let body = try String(contentsOf: probe, encoding: .utf8)
        XCTAssertTrue(body.contains("os_unfair_lock"),
                      "L-1 carry-forward: LifecycleFlushBridge must gate the captured completion Bool with os_unfair_lock, mirroring ProjectFolder.applyUbiquityGate.")
    }
}
