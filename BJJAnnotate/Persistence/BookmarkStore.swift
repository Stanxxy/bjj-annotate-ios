import Foundation
import Observation
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
@Observable
final class BookmarkStore {
    private let defaults: UserDefaults
    private let key: String
    private let resolver: BookmarkResolving
    private let logger: Logger

    /// Non-blocking surface for the most recent persistence fault. UI banners on non-nil and
    /// calls `clearLastError()` once the user has acknowledged (Findings #4 / #5).
    var lastError: BookmarkStoreError?

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
    func resolve(id: String) throws -> URL {
        guard let entry = loadAll().first(where: { $0.id == id }) else {
            throw BookmarkResolutionError.unknownId
        }

        let outcome: (url: URL, isStale: Bool)
        do {
            outcome = try resolver.resolve(data: entry.bookmark)
        } catch let nsError as NSError {
            // Foundation may surface "file does not exist" through several error domains:
            //   - NSCocoaErrorDomain / NSFileReadNoSuchFileError (Cocoa file APIs)
            //   - NSPOSIXErrorDomain code 2 (ENOENT)
            //   - NSFileProviderInternalErrorDomain / NSURLErrorDomain in iCloud cases
            // We also normalize on the underlying error chain since the URL bookmark API
            // wraps the original ENOENT inside a generic "Couldn't open" wrapper.
            if Self.isFileNotFoundError(nsError) {
                throw BookmarkResolutionError.notFound
            }
            throw BookmarkResolutionError.foundation(nsError.localizedDescription)
        }

        let url = outcome.url

        // Existence check — needed for AC #6 (folder moved to Trash; URL resolves but path is gone).
        if !FileManager.default.fileExists(atPath: url.path) {
            throw BookmarkResolutionError.notFound
        }

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if !isDir.boolValue {
            throw BookmarkResolutionError.notADirectory
        }

        if outcome.isStale {
            refreshStaleBookmark(id: id, url: url, previousLastOpenedAt: entry.lastOpenedAt)
        }

        return url
    }

    /// PM AC #9 / Finding #7: re-mint and persist the bookmark after iOS reports staleness.
    /// Failure here is non-fatal — the resolved URL is still usable for THIS session; we just
    /// log and surface `lastError` so the next launch can retry.
    private func refreshStaleBookmark(id: String, url: URL, previousLastOpenedAt: Date) {
        // The test seam (`FakeBookmarkResolver`) returns canned URLs that may not be backed
        // by a real security-scoped resource; we still attempt to start access for production
        // bookmarks. If `startAccessing` returns nil we proceed without it — `mintBookmark`
        // may still succeed for local file URLs in tests, and will throw for real bookmarks
        // which we then surface.
        let token = startAccessing(url: url)
        defer {
            if let token = token { stopAccessing(url: url, token: token) }
        }

        do {
            let refreshed = try resolver.mintBookmark(for: url)
            replace(id: id, bookmark: refreshed, openedAt: previousLastOpenedAt)
        } catch {
            let description = (error as NSError).localizedDescription
            logger.error("Stale-bookmark refresh failed for id \(id, privacy: .public): \(description, privacy: .public)")
            assertionFailure("Stale-bookmark refresh failed: \(description)")
            lastError = .staleRefreshFailed(description: description)
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
    private static func isFileNotFoundError(_ error: NSError) -> Bool {
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
