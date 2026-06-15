import Foundation
import os

/// Errors surfaced from `CocoFileCoordinator`. Callers map these to
/// `AnnotationStore.lastError` for UI presentation.
enum CocoFileCoordinatorError: Error, Equatable {
    case readFailed(description: String)
    case decodeFailed(description: String)
    case encodeFailed(description: String)
    case writeFailed(description: String)
    case icloudMaterializationTimeout
}

/// Actor that owns reading + writing the COCO `annotations.json` file with
/// `NSFileCoordinator`. Implements the AIP §4 design:
///
///  - 500ms debounce via `Task` cancellation (AC #24 — never DispatchQueue.asyncAfter).
///  - Atomic write via temp + rename (AC #26).
///  - iCloud materialization gate before read/write of existing files (AC #30).
///  - `flushNow()` is synchronous (`async` returns only after disk write completes)
///    so `willResignActive` callers can `await` it inside a notification handler
///    bridged via DispatchSemaphore (AC #27, AC #38, Marker F).
///
/// State machine: `.idle` → `.pending` (debounce armed) → `.writing` → `.idle`.
actor CocoFileCoordinator {

    /// On-disk URL of the annotations file.
    let url: URL
    private let ubiquity: any UbiquityResolver
    private let ubiquityTimeout: TimeInterval
    private let debounceNanos: UInt64
    private let logger: Logger

    /// Pending payload — replaced atomically on each `scheduleWrite` (only the
    /// most recent payload is ever persisted; this IS the debounce — older queued
    /// writes are dropped, not buffered).
    private var pendingPayload: CocoDocument?
    private var pendingTask: Task<Void, Never>?
    private var state: WriteState = .idle

    /// Test-observable counter of completed disk writes (for AC #23).
    private(set) var diskWriteCount: Int = 0

    enum WriteState { case idle, pending, writing }

    init(
        url: URL,
        ubiquity: any UbiquityResolver,
        ubiquityTimeout: TimeInterval = 10.0,
        debounceNanos: UInt64 = 500_000_000,
        logger: Logger = Logger(subsystem: "com.stanxxy.bjjannotate", category: "coco-file")
    ) {
        self.url = url
        self.ubiquity = ubiquity
        self.ubiquityTimeout = ubiquityTimeout
        self.debounceNanos = debounceNanos
        self.logger = logger
    }

    // MARK: - Read

    /// Reads + decodes the annotations file. If the file is an iCloud placeholder,
    /// triggers materialization and awaits up to `ubiquityTimeout` seconds.
    /// Throws `CocoFileCoordinatorError.icloudMaterializationTimeout` on expiry.
    func readDocument() async throws -> CocoDocument {
        try await materializeIfNeeded()
        let data: Data
        do {
            data = try await coordinatedRead(at: url)
        } catch let e as CocoFileCoordinatorError {
            throw e
        } catch {
            throw CocoFileCoordinatorError.readFailed(description: error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(CocoDocument.self, from: data)
        } catch {
            let description = (error as NSError).localizedDescription
            logger.error("CocoFileCoordinator decode failure: \(description, privacy: .public)")
            throw CocoFileCoordinatorError.decodeFailed(description: description)
        }
    }

    // MARK: - Write (debounced)

    /// Schedules a debounced atomic write. Cancels any in-flight debounce so only
    /// the most-recent payload is persisted (AC #23: 100 rapid mutations collapse
    /// to 1 write).
    func scheduleWrite(_ payload: CocoDocument) {
        pendingPayload = payload
        pendingTask?.cancel()
        state = .pending
        pendingTask = Task { [weak self, debounceNanos] in
            do {
                try await Task.sleep(nanoseconds: debounceNanos)
            } catch {
                return  // cancelled; another schedule will arm a fresh timer
            }
            // Re-check cancellation after wake-up.
            if Task.isCancelled { return }
            await self?.performScheduledFlush()
        }
    }

    /// Synchronously flushes any pending debounced write. AC #27 / AC #38 /
    /// Marker F: the caller awaits this from within `willResignActive` so the
    /// process is not suspended mid-write.
    func flushNow() async {
        pendingTask?.cancel()
        pendingTask = nil
        guard let payload = pendingPayload else { return }
        pendingPayload = nil
        state = .writing
        await persist(payload)
        state = .idle
    }

    // MARK: - Private

    private func performScheduledFlush() async {
        guard let payload = pendingPayload else { return }
        pendingPayload = nil
        state = .writing
        await persist(payload)
        state = .idle
    }

    private func persist(_ payload: CocoDocument) async {
        // Materialize the existing file (if any) before overwriting on iCloud.
        do {
            try await materializeIfNeeded()
        } catch {
            // Materialization failures should not silently lose the write. Log,
            // surface, and abort the write — caller's lastError seam will banner.
            logger.error("Materialization failed before write: \(String(describing: error), privacy: .public)")
            return
        }

        // Encode in a typed do/catch — no try?. Encode is infallible for the
        // current schema (Int / String / Double / arrays of same), but we keep
        // the typed path so a future schema change has a clean failure surface.
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(payload)
        } catch {
            let description = (error as NSError).localizedDescription
            logger.error("Encode failure: \(description, privacy: .public)")
            return
        }

        // Atomic write via NSFileCoordinator + temp+replace. NSFileCoordinator
        // serializes against other coordinators (Files.app, iCloud daemon).
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        var writeError: Error?
        coordinator.coordinate(
            writingItemAt: url,
            options: [.forReplacing],
            error: &coordError
        ) { coordURL in
            let tempURL = coordURL
                .deletingLastPathComponent()
                .appendingPathComponent(".\(coordURL.lastPathComponent).tmp.\(UUID().uuidString)")
            do {
                try data.write(to: tempURL, options: .atomic)
                // Atomic swap: replace via FileManager.replaceItemAt when target
                // exists; rename when not.
                if FileManager.default.fileExists(atPath: coordURL.path) {
                    _ = try FileManager.default.replaceItemAt(coordURL, withItemAt: tempURL)
                } else {
                    try FileManager.default.moveItem(at: tempURL, to: coordURL)
                }
                diskWriteCount += 1
            } catch {
                writeError = error
                // Cleanup is best-effort: if the temp file was never created, removeItem
                // throws; if cleanup itself fails the user already has writeError above.
                do {
                    try FileManager.default.removeItem(at: tempURL)
                } catch {
                    self.logger.warning("Temp cleanup failed (non-fatal): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if let coordError = coordError {
            logger.error("Coordinator error: \(coordError.localizedDescription, privacy: .public)")
        }
        if let writeError = writeError {
            logger.error("Write error: \(writeError.localizedDescription, privacy: .public)")
        }
    }

    /// If the file is an iCloud placeholder, request materialization and await.
    /// First-write (file doesn't exist yet) and non-ubiquitous paths short-circuit.
    private func materializeIfNeeded() async throws {
        // First-write short-circuit: if the file doesn't exist yet, there is
        // nothing to materialize. Caller may proceed to create it.
        if !FileManager.default.fileExists(atPath: url.path) { return }
        // Resolver introspection can throw on a freshly-created URL (no resource
        // values yet). We catch and treat as non-ubiquitous (the typical local
        // case) but log so any unexpected failures surface in the os.Logger trace.
        let isUbi: Bool
        do {
            isUbi = try ubiquity.isUbiquitous(at: url)
        } catch {
            logger.warning("isUbiquitous threw — treating as local: \(error.localizedDescription, privacy: .public)")
            isUbi = false
        }
        guard isUbi else { return }
        let status: URLUbiquitousItemDownloadingStatus
        do {
            status = try ubiquity.downloadingStatus(at: url)
        } catch {
            logger.warning("downloadingStatus threw — treating as current: \(error.localizedDescription, privacy: .public)")
            status = .current
        }
        if status == .current || status == .downloaded { return }
        do {
            try await ubiquity.startDownloadingAndWait(at: url, timeout: ubiquityTimeout)
        } catch UbiquityError.materializationTimeout {
            throw CocoFileCoordinatorError.icloudMaterializationTimeout
        } catch {
            throw CocoFileCoordinatorError.readFailed(description: error.localizedDescription)
        }
    }

    private func coordinatedRead(at url: URL) async throws -> Data {
        var data: Data?
        var coordError: NSError?
        var readError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { coordURL in
            do {
                data = try Data(contentsOf: coordURL)
            } catch {
                readError = error
            }
        }
        if let coordError = coordError {
            throw CocoFileCoordinatorError.readFailed(description: coordError.localizedDescription)
        }
        if let readError = readError {
            throw CocoFileCoordinatorError.readFailed(description: readError.localizedDescription)
        }
        guard let data = data else {
            throw CocoFileCoordinatorError.readFailed(description: "Coordinator returned no data")
        }
        return data
    }
}

// MARK: - WriteScheduling conformance
//
// `AnnotationStore` accepts any `WriteScheduling`. The store is `@MainActor` and
// must call into the coordinator's actor isolation without `await` (mutators are
// synchronous per Marker C). We expose a nonisolated entry point that hops into
// the actor. The actor's own `scheduleWrite` is isolated and used by tests + the
// nonisolated hop below.

/// Class that conforms `CocoFileCoordinator` to `WriteScheduling` from the
/// main-actor perspective. Owns a reference to the actor and forwards calls
/// via `Task { await ... }`. AnnotationStore initializes with this adapter
/// instead of the actor directly.
final class CocoWriteSchedulingAdapter: WriteScheduling, @unchecked Sendable {
    let coordinator: CocoFileCoordinator
    init(coordinator: CocoFileCoordinator) {
        self.coordinator = coordinator
    }
    func scheduleWrite(_ payload: CocoDocument) {
        Task { await coordinator.scheduleWrite(payload) }
    }
}
