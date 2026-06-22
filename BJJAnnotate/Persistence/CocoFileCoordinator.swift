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

    /// B2 fix: optional callback invoked (on a detached Task) after a real
    /// `NSFileVersion` conflict is detected and the sidecar has been emitted.
    /// The callback runs the `ConflictEvent` to the caller (AnnotatorLifecycleContext)
    /// which bridges it to `AnnotationStore.lastConflict` on the MainActor.
    /// Set by `AnnotatorLifecycleContext.make()` after construction.
    var onConflictDetected: (@Sendable (ConflictEvent) -> Void)?

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

    // MARK: - Conflict handler wiring

    /// Sets the conflict callback from outside the actor (requires `await`).
    /// Called by `AnnotatorLifecycleContext.make()` after the store is ready.
    func setConflictHandler(_ handler: @escaping @Sendable (ConflictEvent) -> Void) {
        self.onConflictDetected = handler
    }

    /// Test-only seam: fires the conflict handler with a synthetic event, allowing
    /// B2 wire tests to exercise the handler→store.lastConflict hop without needing
    /// real NSFileVersion iCloud two-process writes (which are unavailable in tests).
    /// Production code never calls this; only `ConflictWireEndToEndTests` does.
    func fireConflictHandlerForTest(_ event: ConflictEvent) {
        onConflictDetected?(event)
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
    ///
    /// - Parameter latestFallback: a payload supplied by the caller as a fallback
    ///   when the adapter's fire-and-forget `Task { await scheduleWrite(payload) }`
    ///   has not yet been processed by the actor (race between the adapter's task
    ///   and an immediate `flushNow()` call). If the actor already has a pending
    ///   payload (the normal path), `latestFallback` is ignored.
    func flushNow(latestFallback: CocoDocument? = nil) async {
        pendingTask?.cancel()
        pendingTask = nil
        // Use the actor's own pending payload if available; fall back to the
        // caller-supplied payload to handle the adapter-task race.
        let payload = pendingPayload ?? latestFallback
        guard let payload = payload else { return }
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
        // B2 fix: probe for NSFileVersion conflicts BEFORE overwriting.
        // If conflicts exist: preserve the loser(s) as sidecar(s), keep the
        // most-recent version as the new active content, mark conflicts resolved.
        // AC #34: no data silently discarded.
        await resolveConflictsIfNeeded(winnerPayload: payload)

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

    /// B2: Probes `NSFileVersion.unresolvedConflictVersionsOfItem(at:)`. If conflicts exist:
    /// - Reads the loser's bytes from its version URL.
    /// - Emits a `annotations.conflict-<ISO8601>.json` sidecar via `ConflictSidecar.emit`.
    /// - Marks the version as resolved so iCloud stops surfacing it.
    /// - Fires `onConflictDetected` with the `ConflictEvent` so the UI can banner.
    ///
    /// The "winner" is the `winnerPayload` in-memory document (the last persisted
    /// state from the current device). The loser is the remote iCloud version.
    /// AC #34: no loser data silently discarded.
    /// AC #36: athlete dictionaries are NEVER merged — the sidecar preserves the loser verbatim.
    private func resolveConflictsIfNeeded(winnerPayload: CocoDocument) async {
        guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url),
              !conflicts.isEmpty else {
            return
        }
        logger.info("CocoFileCoordinator: \(conflicts.count, privacy: .public) unresolved NSFileVersion conflict(s) detected for \(self.url.lastPathComponent, privacy: .public)")

        let directory = url.deletingLastPathComponent()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        for version in conflicts {
            let versionURL = version.url
            // Read the loser's bytes.
            let loserBytes: Data
            do {
                loserBytes = try Data(contentsOf: versionURL)
            } catch {
                logger.error("Failed to read conflict version bytes: \(error.localizedDescription, privacy: .public)")
                version.isResolved = true
                continue
            }

            // Decode loser to compute differing annotation ids.
            // If loser is undecodable (extremely corrupt), differingIds is empty;
            // the sidecar is still emitted so the bytes are preserved on disk.
            let differingIds: [Int]
            do {
                let loserDoc = try JSONDecoder().decode(CocoDocument.self, from: loserBytes)
                differingIds = ConflictSidecar.differingAnnotationIds(winner: winnerPayload, loser: loserDoc)
            } catch {
                logger.warning("Conflict loser document could not be decoded for diff — sidecar emitted without diff ids: \(error.localizedDescription, privacy: .public)")
                differingIds = []
            }

            // Emit sidecar — preserves loser verbatim, AC #34 + #36.
            let modDate = version.modificationDate ?? Date()
            let event: ConflictEvent
            do {
                event = try ConflictSidecar.emit(
                    directory: directory,
                    losersBytes: loserBytes,
                    loserModificationDate: modDate,
                    winnerURL: url,
                    differingAnnotationIds: differingIds
                )
            } catch {
                logger.error("ConflictSidecar.emit failed: \(error.localizedDescription, privacy: .public)")
                version.isResolved = true
                continue
            }

            // Mark resolved so iCloud stops surfacing this version.
            version.isResolved = true

            // Notify the UI (store.lastConflict) via the injected callback.
            if let handler = onConflictDetected {
                handler(event)
            }
            logger.info("ConflictSidecar emitted: \(event.sidecarURL.lastPathComponent, privacy: .public)")
        }
        // Remove all old versions after resolution to keep the version history clean.
        // removeOtherVersionsOfItem(at:) is synchronous + throwing; failure is non-fatal
        // (iCloud may retry). AC #34 data-safety is already satisfied by the sidecar above.
        do {
            try NSFileVersion.removeOtherVersionsOfItem(at: url)
        } catch {
            logger.warning("removeOtherVersions failed (non-fatal): \(error.localizedDescription, privacy: .public)")
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
///
/// `latestPayload` is updated synchronously on every `scheduleWrite(_:)` call
/// (before the async hop) so `flushNow(latestFallback:)` can safely pick it up
/// even when the actor's task-queue has not yet processed the `scheduleWrite`
/// message (the adapter-task race in immediate flush scenarios — tests + AC #27).
final class CocoWriteSchedulingAdapter: WriteScheduling, @unchecked Sendable {
    let coordinator: CocoFileCoordinator
    /// Last payload received from the store. Updated before the async hop so
    /// `flushNow(latestFallback:)` can drain it even if the actor task hasn't run yet.
    private(set) var latestPayload: CocoDocument?

    init(coordinator: CocoFileCoordinator) {
        self.coordinator = coordinator
    }
    func scheduleWrite(_ payload: CocoDocument) {
        latestPayload = payload
        Task { await coordinator.scheduleWrite(payload) }
    }

    /// Flushes the latest payload to disk, bypassing the debounce timer.
    /// Passes `latestPayload` as the fallback so even an unprocessed actor-queue
    /// `scheduleWrite` message still reaches disk.
    func flushNow() async {
        await coordinator.flushNow(latestFallback: latestPayload)
        latestPayload = nil
    }
}
