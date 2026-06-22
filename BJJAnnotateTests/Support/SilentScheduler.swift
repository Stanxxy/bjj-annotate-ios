import Foundation
@testable import BJJAnnotate

/// Test double for `WriteScheduling` — records calls but never touches disk.
///
/// Used by `AnnotationStoreTests` to exercise the domain layer independently of
/// file I/O. The real production scheduler is `CocoFileCoordinator` (T8/T9).
final class SilentScheduler: WriteScheduling {
    private(set) var scheduledPayloads: [CocoDocument] = []

    func scheduleWrite(_ payload: CocoDocument) {
        scheduledPayloads.append(payload)
    }
}
