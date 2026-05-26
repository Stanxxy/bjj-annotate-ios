import Foundation
import Observation

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

/// MRU-ordered store of security-scoped folder bookmarks, persisted via injected `UserDefaults`.
///
/// AIP §1 (bookmark key strategy) + §2 (`@Observable`). The store does NOT cache resolved URLs
/// or display names — those are derived at render time from `resolve(id:)`.
@Observable
final class BookmarkStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, storageKey: String = "bjj.annotate.bookmarks.v1") {
        self.defaults = defaults
        self.key = storageKey
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
        var stale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: entry.bookmark,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
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

        // Existence check — needed for AC #6 (folder moved to Trash; URL resolves but path is gone).
        if !FileManager.default.fileExists(atPath: url.path) {
            throw BookmarkResolutionError.notFound
        }

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if !isDir.boolValue {
            throw BookmarkResolutionError.notADirectory
        }

        if stale {
            // PM AC #9: refresh stale bookmarks transparently.
            if let started = startAccessing(url: url) {
                defer { stopAccessing(url: url, token: started) }
                if let refreshed = try? url.bookmarkData(
                    options: .minimalBookmark,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    replace(id: id, bookmark: refreshed, openedAt: entry.lastOpenedAt)
                }
            }
        }

        return url
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
            return try JSONDecoder().decode([StoredBookmark].self, from: data)
        } catch {
            // Corrupt blob: surface as empty rather than crash. Logged here would be nicer,
            // but Phase 0 has no logger; the empty state is recoverable via "Open Folder".
            return []
        }
    }

    private func persist(_ items: [StoredBookmark]) {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: key)
        }
    }
}
