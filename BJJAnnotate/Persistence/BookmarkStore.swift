import Foundation
import os

/// A persisted, security-scoped folder bookmark.
///
/// `id` is a synthetic UUID minted on first save (AIP §1). The id survives folder renames in
/// Files, MRU re-orderings, and re-picks of the same folder. The folder's display name is NOT
/// stored here — callers MUST derive it from `BookmarkStore.resolve(id:)` at render time
/// (PM Marker D).
struct StoredBookmark: Codable, Identifiable, Equatable {
    let id: String
    var bookmark: Data
    var lastOpenedAt: Date
}

/// Errors surfaced from `BookmarkStore.resolve(id:)`. Callers map these to user-visible
/// affordances; we never swallow silently (PM evaluator constraint).
enum BookmarkResolutionError: Error, Equatable {
    /// No bookmark with this id is currently stored.
    case unknownId
    /// The resolved folder no longer exists on disk. Caller should present the relocate row.
    case notFound
    /// Access to the resolved folder was denied (security-scoped resource start failed).
    case accessDenied
    /// Bookmark resolution succeeded but the URL is not a directory.
    case notADirectory
    /// Bookmark resolution raised a Foundation error.
    case foundation(String)
}

/// Non-blocking error state surfaced by `BookmarkStore` to the UI. Evaluator findings #4/#5:
/// silent `try?` swallows are forbidden; persistence faults must surface so the UI can banner
/// and the user can recover.
enum BookmarkStoreError: Error, Equatable {
    /// `loadAll()` could not decode the stored blob. UI should banner; the corrupt bytes are
    /// preserved in `UserDefaults` (we do NOT overwrite on read) so a debugger can inspect.
    case decodeFailed(description: String)
    /// `persist(_:)` could not encode the in-memory bookmark list. With the current
    /// `StoredBookmark` schema this is unreachable, but the case exists so a future schema
    /// change has a typed surface to raise on instead of swallowing.
    case encodeFailed(description: String)
    /// Stale-refresh path tried to re-mint a bookmark and failed. Original bookmark is
    /// preserved so the user can still navigate; the failure is logged and surfaced.
    case staleRefreshFailed(description: String)
    /// File-picker flow (`UIDocumentPickerViewController`) returned an error or the
    /// resolution of the picked URL failed (access denied, not a directory, etc.).
    /// L-3 carry-forward: replaces the legacy `@State private var lastError` alert
    /// on `ProjectListView` so picker faults share the same banner surface as
    /// decode/encode/stale-refresh faults.
    case pickerFailed(description: String)
}

/// Seam for `URL(resolvingBookmarkData:bookmarkDataIsStale:)` + `URL.bookmarkData(options:)`.
/// Allows tests to inject a stale-bookmark scenario without provoking iOS-internal staleness
/// (Finding #7 / AIP §7 R9).
protocol BookmarkResolving {
    /// Resolves a stored bookmark blob to a URL, reporting whether iOS considers it stale.
    func resolve(data: Data) throws -> (url: URL, isStale: Bool)
    /// Re-mints a security-scoped bookmark for the given URL. Caller has already started
    /// security-scoped access.
    func mintBookmark(for url: URL) throws -> Data
}

/// Production resolver using Foundation's URL bookmark APIs.
struct SystemBookmarkResolver: BookmarkResolving {
    func resolve(data: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return (url, stale)
    }

    func mintBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
}

/// MRU-ordered store of security-scoped folder bookmarks, persisted via injected `UserDefaults`.
///
/// AIP §1 (bookmark key strategy) + §2 (`@Observable`). The store does NOT cache resolved URLs
/// or display names — those are derived at render time from `resolve(id:)`.
@MainActor
final class BookmarkStore: ObservableObject {
    private let defaults: UserDefaults
    private let key: String
    /// Bookmark resolution seam. Exposed (not `private`) so `ProjectListViewModel.refresh()` can
    /// pass it into the off-main pure-resolution path (`resolvePure(data:resolver:)`) without
    /// crossing the store's mutable state into the background task (Finding #3 data-race fix).
    let resolver: BookmarkResolving
    private let logger: Logger

    /// Non-blocking surface for the most recent persistence fault. UI banners on non-nil and
    /// calls `clearLastError()` once the user has acknowledged (Findings #4 / #5).
    @Published var lastError: BookmarkStoreError?

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "bjj.annotate.bookmarks.v1",
        resolver: BookmarkResolving = SystemBookmarkResolver(),
        logger: Logger = Logger(subsystem: "com.stanxxy.bjjannotate", category: "persistence")
    ) {
        self.defaults = defaults
        self.key = storageKey
        self.resolver = resolver
        self.logger = logger
    }

    // MARK: - Error surface

    /// Clears the most recent persistence fault. Call after the UI has acknowledged the
    /// banner / alert.
    func clearLastError() {
        lastError = nil
    }

    // MARK: - Reads

    /// All saved bookmarks, sorted MRU (most-recently-opened first). Satisfies PM AC #5.
    func all() -> [StoredBookmark] {
        loadAll().sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    // MARK: - Writes

    /// Saves a new bookmark and returns its synthetic UUID id.
    ///
    /// If an existing bookmark has byte-equal `bookmark` data, the existing id is preserved
    /// and `lastOpenedAt` is bumped to now (dedupe-on-blob, AIP §1).
    @discardableResult
    func save(bookmark: Data, openedAt: Date = Date()) -> String {
        var items = loadAll()
        if let idx = items.firstIndex(where: { $0.bookmark == bookmark }) {
            items[idx].lastOpenedAt = openedAt
            persist(items)
            return items[idx].id
        }
        let newID = UUID().uuidString
        items.append(StoredBookmark(id: newID, bookmark: bookmark, lastOpenedAt: openedAt))
        persist(items)
        return newID
    }

    /// Replaces the bookmark data of an existing entry, preserving its id and MRU position.
    /// Used after a successful re-pick of a moved/deleted folder (PM AC #6).
    func replace(id: String, bookmark: Data, openedAt: Date = Date()) {
        var items = loadAll()
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].bookmark = bookmark
        items[idx].lastOpenedAt = openedAt
        persist(items)
    }

    /// Bumps `lastOpenedAt` for an existing entry. No-op if id is unknown.
    func touch(id: String, openedAt: Date = Date()) {
        var items = loadAll()
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].lastOpenedAt = openedAt
        persist(items)
    }

    /// Removes a bookmark by id.
    func remove(id: String) {
        let items = loadAll().filter { $0.id != id }
        persist(items)
    }

    // MARK: - Resolution

    /// Resolves a saved bookmark to its current URL.
    ///
    /// On `bookmarkDataIsStale == true`, the bookmark is re-minted and rewritten (PM AC #9).
    /// Display name is NOT cached — callers consume `result.url.lastPathComponent` at render
    /// time (PM Marker D).
    ///
    /// This is the @MainActor-friendly convenience used by single-bookmark callers
    /// (`ProjectGridViewModel.load()` resolves ONE bookmark). It both resolves AND applies the
    /// stale-refresh side effects (`replace` + `lastError`) inline. The list view model must NOT
    /// use this off the main actor — it would mutate store state from a background thread (data
    /// race). The list path uses `Self.resolvePure(data:resolver:)` off-main and applies the
    /// side effects back on the main actor via `applyRefresh(...)`.
    func resolve(id: String) throws -> URL {
        guard let entry = loadAll().first(where: { $0.id == id }) else {
            throw BookmarkResolutionError.unknownId
        }

        let result = Self.resolvePure(data: entry.bookmark, resolver: resolver)

        // Apply the (pure) outcome's side effects on this (main-actor) caller's thread.
        if let refreshed = result.refreshedBookmark {
            replace(id: id, bookmark: refreshed, openedAt: entry.lastOpenedAt)
        }
        if let staleFailure = result.staleRefreshFailureDescription {
            logger.error("Stale-bookmark refresh failed for id \(id, privacy: .public): \(staleFailure, privacy: .public)")
            lastError = .staleRefreshFailed(description: staleFailure)
        }

        return try result.urlOrThrow()
    }

    // MARK: - Pure resolution (off-main-safe)

    /// Value-type outcome of resolving a single bookmark blob WITHOUT mutating any store state.
    ///
    /// BUG B / Finding #3 (data race): `ProjectListViewModel.refresh()` resolves N bookmarks off
    /// the main actor. `resolve(id:)` mutates the `@Observable` store (`replace` UserDefaults
    /// write + `lastError`), which is unsafe from a background thread. So the heavy I/O
    /// (`URL(resolvingBookmarkData:)`, re-mint, existence/dir gates) runs in `resolvePure` and
    /// returns this value type; the caller applies the persistence + error side effects back on
    /// the main actor.
    struct PureResolution {
        /// The resolved-and-validated URL on success; `nil` if resolution failed.
        let url: URL?
        /// The resolution error if it failed; `nil` on success.
        let error: BookmarkResolutionError?
        /// Freshly-minted bookmark bytes to persist via `replace(id:bookmark:)`, when the
        /// resolver reported staleness and the re-mint succeeded. `nil` otherwise (no write).
        let refreshedBookmark: Data?
        /// Non-fatal stale-refresh failure description to surface via `lastError`, when the
        /// re-mint threw on an otherwise-recoverable path. `nil` if no failure to surface.
        let staleRefreshFailureDescription: String?

        func urlOrThrow() throws -> URL {
            if let url { return url }
            throw error ?? BookmarkResolutionError.notFound
        }
    }

    /// Pure (no-`self`-mutation) bookmark resolution. Safe to call from a detached/background
    /// task: it touches only the injected `resolver` (a value/seam) and `FileManager`, never the
    /// store's `@Observable` state. All BUG A rename-recovery logic is preserved here; the only
    /// difference from `resolve(id:)` is that the persistence (`replace`) and `lastError` side
    /// effects are RETURNED as values for the main actor to apply, instead of mutated inline.
    nonisolated static func resolvePure(data: Data, resolver: BookmarkResolving) -> PureResolution {
        let outcome: (url: URL, isStale: Bool)
        do {
            outcome = try resolver.resolve(data: data)
        } catch let nsError as NSError {
            // Foundation may surface "file does not exist" through several error domains:
            //   - NSCocoaErrorDomain / NSFileReadNoSuchFileError (Cocoa file APIs)
            //   - NSPOSIXErrorDomain code 2 (ENOENT)
            //   - NSFileProviderInternalErrorDomain / NSURLErrorDomain in iCloud cases
            // We also normalize on the underlying error chain since the URL bookmark API
            // wraps the original ENOENT inside a generic "Couldn't open" wrapper.
            let resolutionError: BookmarkResolutionError = isFileNotFoundError(nsError)
                ? .notFound
                : .foundation(nsError.localizedDescription)
            return PureResolution(url: nil, error: resolutionError, refreshedBookmark: nil, staleRefreshFailureDescription: nil)
        }

        // BUG A (V5 rename): on an iCloud folder RENAME the resolver reports `isStale == true`
        // and the URL it first hands back can still point at the STALE original path. If we ran
        // the `fileExists` gate against that stale URL we'd wrongly throw `.notFound` and show
        // the "tap to relocate" copy for a folder that merely got renamed.
        //
        // So when stale, re-mint FIRST: that re-resolves the bookmark to the folder's CURRENT
        // location and yields the URL we then existence-check. The refreshed bytes are returned
        // (not persisted here) so the main actor performs the UserDefaults write race-free.
        // The TRASH case (AC #6) is preserved: if the folder is genuinely gone the re-mint also
        // resolves to a non-existent path (or fails), and the existence gate below still yields
        // `.notFound`.
        let url: URL
        var refreshedBookmark: Data? = nil
        var staleRefreshFailureDescription: String? = nil
        if outcome.isStale {
            let refresh = refreshStaleBookmarkPure(resolvedURL: outcome.url, resolver: resolver)
            url = refresh.url
            refreshedBookmark = refresh.refreshedBookmark
            staleRefreshFailureDescription = refresh.failureDescription
        } else {
            url = outcome.url
        }

        // Existence check — runs against the CURRENT url (refreshed on rename). AC #6: folder
        // moved to Trash resolves to a path that no longer exists → `.notFound`.
        if !FileManager.default.fileExists(atPath: url.path) {
            return PureResolution(url: nil, error: .notFound, refreshedBookmark: refreshedBookmark, staleRefreshFailureDescription: staleRefreshFailureDescription)
        }

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if !isDir.boolValue {
            return PureResolution(url: nil, error: .notADirectory, refreshedBookmark: refreshedBookmark, staleRefreshFailureDescription: staleRefreshFailureDescription)
        }

        return PureResolution(url: url, error: nil, refreshedBookmark: refreshedBookmark, staleRefreshFailureDescription: staleRefreshFailureDescription)
    }

    /// Pure (no-`self`-mutation) stale-bookmark refresh. PM AC #9 / Finding #7 + BUG A: re-mint
    /// the bookmark after iOS reports staleness, then re-resolve the freshly-minted blob to
    /// obtain the folder's CURRENT URL. Safe to call off the main actor — it touches only the
    /// injected `resolver` and returns the persistence/`lastError` side effects as values for the
    /// caller to apply on the main actor.
    ///
    /// Returns:
    ///  - `url`: the URL for the downstream existence/directory gates.
    ///     - On a RENAME the re-resolve yields the NEW (existing) path → silent recovery.
    ///     - On a TRASH the re-resolve yields a path that still doesn't exist (or re-mint/resolve
    ///       fails) → returns the best URL and the existence gate yields `.notFound` (AC #6).
    ///  - `refreshedBookmark`: bytes to persist via `replace(...)` on success, else `nil`.
    ///  - `failureDescription`: non-fatal re-mint failure to surface via `lastError`, else `nil`.
    private nonisolated static func refreshStaleBookmarkPure(
        resolvedURL: URL,
        resolver: BookmarkResolving
    ) -> (url: URL, refreshedBookmark: Data?, failureDescription: String?) {
        // The test seam returns canned URLs that may not be backed by a real security-scoped
        // resource; we still attempt to start access for production bookmarks. If
        // `startAccessingSecurityScopedResource` returns false we proceed without it —
        // `mintBookmark` may still succeed for local file URLs in tests, and will throw for real
        // bookmarks which we then surface.
        let started = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if started { resolvedURL.stopAccessingSecurityScopedResource() }
        }

        do {
            let refreshed = try resolver.mintBookmark(for: resolvedURL)
            // Re-resolve the refreshed bookmark to pick up the folder's current location
            // (the whole point of BUG A's rename recovery). If this re-resolve fails we still
            // hand the refreshed bytes back for persistence; fall back to the originally-resolved
            // URL for the existence gate.
            if let reResolved = try? resolver.resolve(data: refreshed) {
                return (reResolved.url, refreshed, nil)
            }
            return (resolvedURL, refreshed, nil)
        } catch {
            // BUG A regression guard: re-mint can legitimately FAIL when the folder is genuinely
            // gone (Trash). That is NOT a programmer error — we must NOT `assertionFailure` here
            // (it would crash the legitimate AC #6 trash flow now that re-mint runs before the
            // existence gate). We return the failure description so the caller surfaces
            // `lastError` (a refresh failure on an *existing* folder stays visible to the UI), and
            // return the originally-resolved URL so the existence gate makes the final call
            // (→ `.notFound` for a trashed folder).
            let description = (error as NSError).localizedDescription
            return (resolvedURL, nil, description)
        }
    }

    /// Convenience: start security-scoped access. Returns the URL if access started, nil on
    /// failure. Caller MUST balance with `stopAccessing(url:token:)` (AIP §6.1 evaluator gate).
    func startAccessing(url: URL) -> URL? {
        return url.startAccessingSecurityScopedResource() ? url : nil
    }

    func stopAccessing(url: URL, token: URL) {
        token.stopAccessingSecurityScopedResource()
    }

    // MARK: - Private

    /// Walks the NSError chain and returns true if any layer indicates "file not found".
    /// Robust against the URL-bookmark API wrapping the underlying ENOENT.
    private nonisolated static func isFileNotFoundError(_ error: NSError) -> Bool {
        var current: NSError? = error
        while let err = current {
            if err.domain == NSCocoaErrorDomain && err.code == NSFileReadNoSuchFileError {
                return true
            }
            if err.domain == NSPOSIXErrorDomain && err.code == 2 {
                return true
            }
            // The URL-bookmark API may surface NSCocoaErrorDomain 260 (NSFileNoSuchFileError)
            // or the message-level "doesn't exist" indicator on some iOS versions.
            if err.domain == NSCocoaErrorDomain && err.code == 4 {
                return true
            }
            let nextError = (err.userInfo[NSUnderlyingErrorKey] as? NSError)
                ?? (err.userInfo["NSUnderlyingError"] as? NSError)
            // Stop if we don't make progress.
            if nextError === current { return false }
            current = nextError
        }
        return false
    }

    private func loadAll() -> [StoredBookmark] {
        guard let data = defaults.data(forKey: key) else { return [] }
        do {
            let items = try JSONDecoder().decode([StoredBookmark].self, from: data)
            return items
        } catch {
            // Finding #5: surface as non-blocking error instead of silently returning [].
            //
            // DESIGN CHOICE (commit message documents this): we DO return [] so the UI can
            // render (the alternative — refusing to proceed — would brick the app and require
            // a delete-and-reinstall). The corrupt blob is PRESERVED in UserDefaults under
            // `key` (we never overwrite on read), so a future debug build can inspect it. The
            // user is informed via `lastError` so they know to expect a missing project list
            // and can re-pick via "Open Folder".
            let description = (error as NSError).localizedDescription
            logger.error("BookmarkStore.loadAll decode failure: \(description, privacy: .public)")
            // NOTE: NO `assertionFailure` here — corruption is a runtime condition we expect
            // to observe (and a test in BookmarkStoreErrorSurfacingTests deliberately seeds
            // it). The user-visible surface is `lastError`; debug introspection comes from
            // the os.Logger trace.
            lastError = .decodeFailed(description: description)
            return []
        }
    }

    private func persist(_ items: [StoredBookmark]) {
        // Finding #4: previously `try? JSONEncoder().encode(items)`. With the current
        // schema (String / Data / Date) encode is infallible by construction, so we use
        // `try!`-equivalent via explicit do/catch that traps in debug and surfaces in
        // release rather than silently dropping the write.
        do {
            let data = try JSONEncoder().encode(items)
            defaults.set(data, forKey: key)
        } catch {
            let description = (error as NSError).localizedDescription
            logger.error("BookmarkStore.persist encode failure: \(description, privacy: .public)")
            assertionFailure("BookmarkStore encode failure (should be unreachable with current schema): \(description)")
            lastError = .encodeFailed(description: description)
        }
    }
}
