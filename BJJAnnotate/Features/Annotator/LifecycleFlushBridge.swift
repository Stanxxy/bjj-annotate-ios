import Foundation
import SwiftUI
import UIKit
import os

/// T21 — Synchronous flush bridge for `UIApplication.willResignActiveNotification`.
///
/// AC #27/#38/Marker F: when the app is about to be suspended (background) or
/// when the active scene resigns, any pending debounced write in
/// `CocoFileCoordinator` MUST be persisted SYNCHRONOUSLY before iOS suspends
/// the process. The bridge runs on the main actor (the notification observer's
/// callback context) and uses `DispatchSemaphore` to wait on the actor's
/// `flushNow()`.
///
/// L-1 carry-forward (T11–T13 evaluator review): the captured-completion
/// Bool's write+read is gated with `os_unfair_lock` so the visibility
/// contract is explicit, not incidental to the semaphore's release/acquire
/// happenstance. This mirrors the hardening applied to
/// `ProjectFolder.applyUbiquityGate` in T15.
final class LifecycleFlushBridge {

    private let logger: Logger

    init(logger: Logger = Logger(subsystem: "com.stanxxy.bjjannotate", category: "lifecycle-flush")) {
        self.logger = logger
    }

    /// Synchronously waits for `coordinator.flushNow()` to complete. Returns
    /// true on success, false on timeout. Designed for direct invocation from
    /// the `willResignActiveNotification` observer's main-thread callback.
    @discardableResult
    func flushSynchronously(coordinator: CocoFileCoordinator, timeoutMs: Int = 5_000) -> Bool {
        // L-1 hardening: gate the captured Bool with os_unfair_lock so the
        // visibility contract across the semaphore barrier is explicit.
        let lock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock_s())
        defer {
            lock.deinitialize(count: 1)
            lock.deallocate()
        }
        var didComplete: Bool = false
        let semaphore = DispatchSemaphore(value: 0)

        Task.detached(priority: .userInitiated) {
            await coordinator.flushNow()
            os_unfair_lock_lock(lock)
            didComplete = true
            os_unfair_lock_unlock(lock)
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + .milliseconds(timeoutMs))
        os_unfair_lock_lock(lock)
        let completed = didComplete
        os_unfair_lock_unlock(lock)

        if waitResult != .success {
            logger.error("flushSynchronously timed out after \(timeoutMs)ms")
            return false
        }
        return completed
    }
}

/// View modifier that installs the willResignActiveNotification observer.
/// Hosts (`AnnotatorView`) attach this once they own a `CocoFileCoordinator`.
/// Removed automatically when the view goes away (`.task` lifecycle).
struct WillResignActiveFlushModifier: ViewModifier {
    let coordinator: CocoFileCoordinator
    let bridge: LifecycleFlushBridge

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                _ = bridge.flushSynchronously(coordinator: coordinator)
            }
    }
}

extension View {
    /// Attaches the lifecycle flush bridge to this view. Use on
    /// `AnnotatorView` so any pending debounced write flushes before the app
    /// is suspended (AC #27/#38/Marker F).
    func flushOnWillResignActive(coordinator: CocoFileCoordinator,
                                  bridge: LifecycleFlushBridge = LifecycleFlushBridge()) -> some View {
        modifier(WillResignActiveFlushModifier(coordinator: coordinator, bridge: bridge))
    }
}
