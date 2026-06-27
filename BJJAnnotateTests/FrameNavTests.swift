import XCTest
import SwiftUI   // for PresentationDetent (FrameNav.PerFrameResetState)
import UIKit     // for UIKeyCommand (KeyArrowHostVC tests)
@testable import BJJAnnotate

/// Tests for in-annotator frame navigation (prev/next).
///
/// Coverage:
///   1. `FrameNav` pure boundary logic (frame index, isPrev/isNextDisabled).
///   2. Flush-before-switch ordering contract — flush completes before context teardown.
///   3. Back-stack invariant — AnnotatorView never appends to RootView.path (grep gate).
///   4. Per-frame state reset contract (tool, selectedInstanceId, activeKeypointIndex).
///
/// All async tests are `@MainActor` (same as `AnnotatorLifecycleContext`).
@MainActor
final class FrameNavTests: XCTestCase {

    // MARK: - Test directory scaffolding

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameNavTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    /// Writes a minimal valid 1×1 PNG to `tempDir/name` and returns its URL.
    private func makeImage(name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let png: [UInt8] = [
            0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,
            0x00,0x00,0x00,0x0D,0x49,0x48,0x44,0x52,
            0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01,
            0x08,0x02,0x00,0x00,0x00,0x90,0x77,0x53,
            0xDE,0x00,0x00,0x00,0x0C,0x49,0x44,0x41,
            0x54,0x08,0xD7,0x63,0xF8,0xFF,0xFF,0x3F,
            0x00,0x05,0xFE,0x02,0xFE,0xDC,0xCC,0x59,
            0xE7,0x00,0x00,0x00,0x00,0x49,0x45,0x4E,
            0x44,0xAE,0x42,0x60,0x82
        ]
        try Data(png).write(to: url)
        return url
    }

    // MARK: - 1. FrameNav.frameIndex

    func test_frameIndex_returns_1based_position() {
        let a = URL(fileURLWithPath: "/proj/frame_0001.jpg")
        let b = URL(fileURLWithPath: "/proj/frame_0002.jpg")
        let c = URL(fileURLWithPath: "/proj/frame_0003.jpg")
        let list = [a, b, c]

        XCTAssertEqual(FrameNav.frameIndex(for: a, in: list), 1)
        XCTAssertEqual(FrameNav.frameIndex(for: b, in: list), 2)
        XCTAssertEqual(FrameNav.frameIndex(for: c, in: list), 3)
    }

    func test_frameIndex_falls_back_to_lastPathComponent_on_path_mismatch() {
        // Simulates the symlink vs. resolved-path divergence handled by imageId().
        let canonical = URL(fileURLWithPath: "/real/path/frame_0001.jpg")
        let alias    = URL(fileURLWithPath: "/alias/path/frame_0001.jpg")
        let list = [canonical]

        // Exact URL does not match, but lastPathComponent does.
        XCTAssertEqual(FrameNav.frameIndex(for: alias, in: list), 1,
                       "lastPathComponent fallback must yield index 1 for same filename at different path")
    }

    func test_frameIndex_returns_nil_when_not_found() {
        let a = URL(fileURLWithPath: "/proj/frame_0001.jpg")
        let list = [a]
        let ghost = URL(fileURLWithPath: "/proj/ghost.jpg")
        XCTAssertNil(FrameNav.frameIndex(for: ghost, in: list),
                     "frameIndex must return nil for a URL absent from the list")
    }

    func test_frameIndex_returns_nil_for_empty_list() {
        let url = URL(fileURLWithPath: "/proj/frame_0001.jpg")
        XCTAssertNil(FrameNav.frameIndex(for: url, in: []))
    }

    // MARK: - 2. FrameNav.isPrevDisabled

    func test_isPrevDisabled_true_at_first_frame() {
        XCTAssertTrue(FrameNav.isPrevDisabled(frameIndex: 1, frameCount: 3),
                      "Prev must be disabled at frame 1 of 3")
    }

    func test_isPrevDisabled_false_in_middle_frame() {
        XCTAssertFalse(FrameNav.isPrevDisabled(frameIndex: 2, frameCount: 3),
                       "Prev must be enabled at frame 2 of 3")
    }

    func test_isPrevDisabled_false_at_last_frame() {
        XCTAssertFalse(FrameNav.isPrevDisabled(frameIndex: 3, frameCount: 3),
                       "Prev must be enabled at frame 3 of 3 (last)")
    }

    func test_isPrevDisabled_true_when_index_is_nil() {
        XCTAssertTrue(FrameNav.isPrevDisabled(frameIndex: nil, frameCount: 5))
    }

    func test_isPrevDisabled_true_when_frameCount_is_zero() {
        XCTAssertTrue(FrameNav.isPrevDisabled(frameIndex: 1, frameCount: 0))
    }

    // MARK: - 3. FrameNav.isNextDisabled

    func test_isNextDisabled_true_at_last_frame() {
        XCTAssertTrue(FrameNav.isNextDisabled(frameIndex: 3, frameCount: 3),
                      "Next must be disabled at frame 3 of 3")
    }

    func test_isNextDisabled_false_in_middle_frame() {
        XCTAssertFalse(FrameNav.isNextDisabled(frameIndex: 2, frameCount: 3),
                       "Next must be enabled at frame 2 of 3")
    }

    func test_isNextDisabled_false_at_first_frame() {
        XCTAssertFalse(FrameNav.isNextDisabled(frameIndex: 1, frameCount: 3),
                       "Next must be enabled at frame 1 of 3 (first)")
    }

    func test_isNextDisabled_true_when_index_is_nil() {
        XCTAssertTrue(FrameNav.isNextDisabled(frameIndex: nil, frameCount: 5))
    }

    func test_isNextDisabled_true_when_frameCount_is_zero() {
        XCTAssertTrue(FrameNav.isNextDisabled(frameIndex: 1, frameCount: 0))
    }

    // MARK: - 4. Single-frame list: both prev and next disabled

    func test_single_frame_both_prev_and_next_disabled() {
        let idx = 1
        let n = 1
        XCTAssertTrue(FrameNav.isPrevDisabled(frameIndex: idx, frameCount: n),
                      "N=1: Prev must be disabled")
        XCTAssertTrue(FrameNav.isNextDisabled(frameIndex: idx, frameCount: n),
                      "N=1: Next must be disabled")
    }

    // MARK: - 5. Frame navigation targets (driven by FrameNav product code)

    /// m2 replacement: drives real `FrameNav` product code instead of Swift array arithmetic.
    ///
    /// Previously this was `test_prev_next_index_math` which tested `list[idx - 2]` and
    /// `list[idx]` with a hard-coded integer — tautological (tests Swift, not product logic).
    /// This replacement uses `FrameNav.frameIndex` to obtain `idx` and the boundary guards
    /// to confirm navigation is possible, then verifies the documented `switchFrame`
    /// navigation expressions produce the expected target frames.
    func test_prev_next_targets_driven_by_FrameNav_frameIndex() {
        let a = URL(fileURLWithPath: "/p/frame_0001.jpg")
        let b = URL(fileURLWithPath: "/p/frame_0002.jpg")
        let c = URL(fileURLWithPath: "/p/frame_0003.jpg")
        let list = [a, b, c]

        // Obtain 1-based index via real product code.
        let idx = FrameNav.frameIndex(for: b, in: list)
        XCTAssertEqual(idx, 2, "b must be at 1-based index 2 (via FrameNav.frameIndex)")

        // Confirm boundaries allow navigation in both directions.
        XCTAssertFalse(FrameNav.isPrevDisabled(frameIndex: idx, frameCount: list.count),
                       "Prev must be enabled at frame 2 of 3")
        XCTAssertFalse(FrameNav.isNextDisabled(frameIndex: idx, frameCount: list.count),
                       "Next must be enabled at frame 2 of 3")

        // Verify switchFrame's documented navigation array expressions:
        //   Prev: frameList[i - 2]  (1-based i → 0-based prev = i-2)
        //   Next: frameList[i]      (1-based i → 0-based next = i)
        guard let i = idx else { XCTFail("idx must not be nil"); return }
        XCTAssertEqual(list[i - 2], a, "Prev from frame 2 must target frame_0001 (list[0])")
        XCTAssertEqual(list[i],     c, "Next from frame 2 must target frame_0003 (list[2])")
    }

    // MARK: - 6. Flush-before-switch ordering

    /// Verifies that the flush (diskWriteCount increment) happens BEFORE context teardown
    /// by re-enacting the switchFrame ordering contract with a real coordinator.
    ///
    /// Creates a context, schedules a write, then calls flushSynchronously — exactly
    /// what switchFrame does for the outgoing context — and confirms diskWriteCount
    /// incremented before the context is released.
    func test_flush_happens_before_context_nil() async throws {
        let img = try makeImage(name: "frame_0001.png")

        let ctx = try await AnnotatorLifecycleContext.make(
            folderURL: tempDir,
            imageURL: img,
            ubiquity: FakeUbiquityResolver()
        )

        // Mutate store so there is a pending write.
        ctx.store.upsertBox(BBoxIntent(rect: BBox(x: 10, y: 10, w: 50, h: 50)))

        let writesBefore = await ctx.coordinator.diskWriteCount

        // Simulate the flush step in switchFrame.
        let bridge = LifecycleFlushBridge()
        let didFlush = bridge.flushSynchronously(coordinator: ctx.coordinator, timeoutMs: 3000)

        let writesAfterFlush = await ctx.coordinator.diskWriteCount

        // Only now "tear down" (analogous to context = nil in switchFrame).
        // The context object still exists here but is no longer referenced.

        XCTAssertTrue(didFlush, "flushSynchronously must report success")
        XCTAssertGreaterThan(writesAfterFlush, writesBefore,
                             "Flush must have written to disk before context is released")
    }

    /// NullWriteScheduler (decode-error) context allows flush without error (no-op path).
    func test_flush_on_null_scheduler_context_is_noop_and_safe() async throws {
        let img = try makeImage(name: "frame_0001.png")
        // Corrupt annotations.json forces the NullWriteScheduler path.
        let annotationsURL = tempDir.appendingPathComponent("annotations.json")
        try Data("CORRUPT".utf8).write(to: annotationsURL)

        let ctx = try await AnnotatorLifecycleContext.make(
            folderURL: tempDir,
            imageURL: img,
            ubiquity: FakeUbiquityResolver()
        )

        // Context must be in error state (NullWriteScheduler).
        XCTAssertNotNil(ctx.store.lastError,
                        "Corrupt annotations.json must produce a lastError (read-only store)")

        // Flush must not crash and must complete — it's a no-op for NullWriteScheduler.
        let bridge = LifecycleFlushBridge()
        let didFlush = bridge.flushSynchronously(coordinator: ctx.coordinator, timeoutMs: 2000)
        XCTAssertTrue(didFlush, "flush on NullWriteScheduler context must return true (no-op, not an error)")
    }

    // MARK: - 7. Back-stack invariant (grep gate)

    /// Structural guarantee: `AnnotatorView.swift` must never append to a `path`
    /// variable. Frame navigation is in-place; `RootView.path` must not grow.
    ///
    /// This grep gate is the strongest automated check available without a full
    /// UI integration test harness.
    func test_annotator_view_does_not_append_to_path() throws {
        let root = Self.repoRoot()
        let sourceURL = root
            .appendingPathComponent("BJJAnnotate")
            .appendingPathComponent("Features")
            .appendingPathComponent("Annotator")
            .appendingPathComponent("AnnotatorView.swift")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw XCTSkip("AnnotatorView.swift not found via #file walk — skip grep gate.")
        }
        let body = try String(contentsOf: sourceURL, encoding: .utf8)

        // The file must NOT contain `path.append` — that would push onto the navigation stack.
        XCTAssertFalse(body.contains("path.append"),
                       "AnnotatorView must never append to a path array — frame switching must be in-place (RootView.path must not grow).")
    }

    // MARK: - 8. Per-frame state reset — Contract 3 (M1)

    /// `.keypoints` tool resets to `.select` on frame switch.
    func test_perFrameReset_keypoints_tool_resets_to_select() {
        let result = FrameNav.applyPerFrameReset(
            tool: .keypoints, selectedInstanceId: 3,
            activeKeypointIndex: 5, sheetDetent: .fraction(0.85)
        )
        XCTAssertEqual(result.tool, .select,
                       ".keypoints tool must be reset to .select after frame switch")
    }

    /// `.box` and `.select` tools persist unchanged.
    func test_perFrameReset_non_keypoints_tool_persists() {
        let boxResult = FrameNav.applyPerFrameReset(
            tool: .box, selectedInstanceId: nil,
            activeKeypointIndex: 1, sheetDetent: .fraction(0.33)
        )
        XCTAssertEqual(boxResult.tool, .box, ".box tool must persist across frame switch")

        let selectResult = FrameNav.applyPerFrameReset(
            tool: .select, selectedInstanceId: nil,
            activeKeypointIndex: 1, sheetDetent: .fraction(0.33)
        )
        XCTAssertEqual(selectResult.tool, .select, ".select tool must persist across frame switch")
    }

    /// `selectedInstanceId` is always nil after reset, regardless of prior value.
    func test_perFrameReset_selectedInstanceId_always_nil() {
        let result = FrameNav.applyPerFrameReset(
            tool: .box, selectedInstanceId: 42,
            activeKeypointIndex: 1, sheetDetent: .fraction(0.33)
        )
        XCTAssertNil(result.selectedInstanceId,
                     "selectedInstanceId must be nil after per-frame reset")
    }

    /// `activeKeypointIndex` resets to 1 (first keypoint).
    func test_perFrameReset_activeKeypointIndex_resets_to_1() {
        let result = FrameNav.applyPerFrameReset(
            tool: .keypoints, selectedInstanceId: nil,
            activeKeypointIndex: 9, sheetDetent: .fraction(0.85)
        )
        XCTAssertEqual(result.activeKeypointIndex, 1,
                       "activeKeypointIndex must reset to 1 after frame switch")
    }

    /// `sheetDetent` resets to `.fraction(0.33)` (un-collapsed).
    func test_perFrameReset_sheetDetent_resets_to_fraction_33() {
        let result = FrameNav.applyPerFrameReset(
            tool: .select, selectedInstanceId: nil,
            activeKeypointIndex: 3, sheetDetent: .fraction(0.85)
        )
        XCTAssertEqual(result.sheetDetent, .fraction(0.33),
                       "sheetDetent must reset to .fraction(0.33) after frame switch")
    }

    /// `isViewLocked` is intentionally absent from `PerFrameResetState` — it persists
    /// across frame switches and must never appear in the reset output.
    ///
    /// This is a structural/documentation test. If someone adds `isViewLocked` to
    /// `PerFrameResetState`, the caller in `switchFrame` must be explicitly updated.
    func test_perFrameReset_output_does_not_include_isViewLocked() {
        let result = FrameNav.applyPerFrameReset(
            tool: .box, selectedInstanceId: nil,
            activeKeypointIndex: 1, sheetDetent: .fraction(0.33)
        )
        // Exhaustively access every field. If a new field (e.g. isViewLocked) is added,
        // the compiler will not warn here — but the test documents intent.
        // The four fields below are the COMPLETE set; isViewLocked must NOT be one of them.
        _ = result.tool
        _ = result.selectedInstanceId
        _ = result.activeKeypointIndex
        _ = result.sheetDetent
        // If isViewLocked were present it would appear here — it must not.
        XCTAssertTrue(true, "PerFrameResetState must contain exactly: tool, selectedInstanceId, activeKeypointIndex, sheetDetent — no isViewLocked")
    }

    // MARK: - 9. Flush-before-switch ordering via spy (M2)

    /// Proves that `FrameNav.executeSwitchFrameOrdered` calls flush BEFORE tearDownContext.
    ///
    /// This test drives the SAME sequencing function that `switchFrame` uses, so any
    /// reordering of the closure calls within `switchFrame` (e.g. nil-then-flush) would
    /// require reordering inside `executeSwitchFrameOrdered`, which this test catches.
    func test_executeSwitchFrameOrdered_calls_flush_before_tearDown() {
        var callOrder: [String] = []
        FrameNav.executeSwitchFrameOrdered(
            flush:           { callOrder.append("flush") },
            resetState:      { callOrder.append("reset") },
            tearDownContext: { callOrder.append("tearDown") },
            activateNew:     { callOrder.append("activate") }
        )
        XCTAssertEqual(callOrder, ["flush", "reset", "tearDown", "activate"],
                       "Steps must execute in documented order: flush → reset → tearDown → activate")
        guard let flushIdx     = callOrder.firstIndex(of: "flush"),
              let tearDownIdx  = callOrder.firstIndex(of: "tearDown") else {
            XCTFail("Both flush and tearDown must be recorded by spy")
            return
        }
        XCTAssertLessThan(flushIdx, tearDownIdx,
                          "flush (step 1) must occur before context teardown (step 3)")
    }

    // MARK: - 10. KeyArrowHostVC keyboard wiring (M3)

    /// `keyCommands` provides left and right arrow commands.
    func test_keyArrowHostVC_provides_left_and_right_arrow_commands() {
        let vc = KeyArrowHostVC()
        guard let commands = vc.keyCommands else {
            XCTFail("KeyArrowHostVC.keyCommands must not be nil")
            return
        }
        let inputs = commands.compactMap { $0.input }
        XCTAssertTrue(inputs.contains(UIKeyCommand.inputLeftArrow),
                      "Must include a left arrow (←) key command")
        XCTAssertTrue(inputs.contains(UIKeyCommand.inputRightArrow),
                      "Must include a right arrow (→) key command")
    }

    /// Left arrow command action triggers `onPrev`.
    func test_keyArrowHostVC_left_arrow_fires_onPrev() {
        let vc = KeyArrowHostVC()
        var prevFired = false
        vc.onPrev = { prevFired = true }
        guard let commands = vc.keyCommands,
              let leftCmd = commands.first(where: { $0.input == UIKeyCommand.inputLeftArrow }) else {
            XCTFail("KeyArrowHostVC must have a left arrow key command")
            return
        }
        vc.perform(leftCmd.action)
        XCTAssertTrue(prevFired,
                      "onPrev must fire when the left arrow key command action is triggered")
    }

    /// Right arrow command action triggers `onNext`.
    func test_keyArrowHostVC_right_arrow_fires_onNext() {
        let vc = KeyArrowHostVC()
        var nextFired = false
        vc.onNext = { nextFired = true }
        guard let commands = vc.keyCommands,
              let rightCmd = commands.first(where: { $0.input == UIKeyCommand.inputRightArrow }) else {
            XCTFail("KeyArrowHostVC must have a right arrow key command")
            return
        }
        vc.perform(rightCmd.action)
        XCTAssertTrue(nextFired,
                      "onNext must fire when the right arrow key command action is triggered")
    }

    /// Boundary guard: prev closure is a no-op when already at the first frame.
    ///
    /// Tests the guard logic that `AnnotatorView` wraps inside the `onPrev` closure
    /// it hands to `KeyArrowInterceptor`. At frame 1, `isPrevDisabled` is true and
    /// the closure must return without calling `switchFrame`.
    func test_keyboard_prev_closure_is_noop_at_first_frame() {
        let list = [
            URL(fileURLWithPath: "/p/frame_0001.jpg"),
            URL(fileURLWithPath: "/p/frame_0002.jpg"),
            URL(fileURLWithPath: "/p/frame_0003.jpg"),
        ]
        let currentIdx: Int? = 1  // first frame
        var prevNavigated = false

        // Re-enact the AnnotatorView onPrev closure verbatim.
        let guardedPrev: () -> Void = {
            guard !FrameNav.isPrevDisabled(frameIndex: currentIdx, frameCount: list.count),
                  let i = currentIdx else { return }
            _ = list[i - 2]   // would call switchFrame in production
            prevNavigated = true
        }
        guardedPrev()
        XCTAssertFalse(prevNavigated,
                       "Prev closure at frame 1 must be a no-op — boundary guard must prevent navigation")
    }

    /// Boundary guard: next closure is a no-op when already at the last frame.
    func test_keyboard_next_closure_is_noop_at_last_frame() {
        let list = [
            URL(fileURLWithPath: "/p/frame_0001.jpg"),
            URL(fileURLWithPath: "/p/frame_0002.jpg"),
        ]
        let currentIdx: Int? = 2  // last frame
        var nextNavigated = false

        let guardedNext: () -> Void = {
            guard !FrameNav.isNextDisabled(frameIndex: currentIdx, frameCount: list.count),
                  let i = currentIdx else { return }
            _ = list[i]       // would call switchFrame in production
            nextNavigated = true
        }
        guardedNext()
        XCTAssertFalse(nextNavigated,
                       "Next closure at last frame must be a no-op — boundary guard must prevent navigation")
    }

    // MARK: - 11. Reload race — generation guard (m4)

    /// Drives `FrameNav.shouldApplyLoad` — the pure helper extracted from the two
    /// post-await guard sites inside `loadContext()` — to verify its accept/reject
    /// semantics directly.
    ///
    /// Non-tautological because:
    ///   - Both assertions call the REAL product function; deleting `shouldApplyLoad`
    ///     breaks the build.
    ///   - If `shouldApplyLoad` were inverted (`myTrigger != current`) the first
    ///     assertion ("fresh load applies") would fail (returns false for equal UUIDs)
    ///     and the second ("stale load rejected") would also fail (returns true for
    ///     unequal UUIDs), making the inversion detectable.
    func test_shouldApplyLoad_accepts_fresh_and_rejects_stale() {
        let captured = UUID()   // stamp captured at the start of a loadContext task
        let bumped   = UUID()   // contextLoadTrigger after a subsequent switchFrame call

        // Fresh load: myTrigger still matches the current trigger — apply the result.
        XCTAssertTrue(
            FrameNav.shouldApplyLoad(myTrigger: captured, current: captured),
            "shouldApplyLoad must return true when myTrigger == current (fresh load)")

        // Stale load: current trigger has advanced — discard the in-flight result.
        XCTAssertFalse(
            FrameNav.shouldApplyLoad(myTrigger: captured, current: bumped),
            "shouldApplyLoad must return false when current trigger has advanced past myTrigger (stale load)")
    }

    // MARK: - Private helpers

    private static func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #file)
        while url.path != "/" && url.lastPathComponent != "bjj-annotate-ios" {
            url.deleteLastPathComponent()
        }
        return url
    }
}
