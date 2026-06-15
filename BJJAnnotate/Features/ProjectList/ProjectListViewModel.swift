import Foundation
import Observation

/// Row state for the project list (Designer pack §State 1b/1c).
///
/// `.ok` rows render the folder name + relative-date subtitle and push to the grid.
/// `.missing` rows render in orange with the locked relocate copy and tap to re-pick.
enum ProjectListRowState: Equatable {
    case ok(displayName: String, lastOpenedAt: Date)
    case missing
}

struct ProjectListRow: Identifiable, Equatable {
    let id: String              // BookmarkStore id (synthetic UUID)
    let state: ProjectListRowState
    let lastOpenedAt: Date      // canonical sort key (independent of state)
}

/// `@Observable` view model for `RootView` / `ProjectListView`.
///
/// - Re-derives display names from `BookmarkStore.resolve(id:)` on `refresh()` — never caches
///   names (PM Marker D).
/// - Drives the relocate flow: `relocate(rowID:to:)` rewrites the bookmark via
///   `BookmarkStore.replace(id:bookmark:)`, preserving id + MRU position.
@Observable
@MainActor
final class ProjectListViewModel {
    let bookmarkStore: BookmarkStore
    private(set) var rows: [ProjectListRow] = []

    init(bookmarkStore: BookmarkStore) {
        self.bookmarkStore = bookmarkStore
    }

    /// Recomputes the row list from the current `BookmarkStore` snapshot. Safe to call from any
    /// .onAppear, .refreshable, or post-picker handler.
    ///
    /// BUG B + Finding #3 (data race). `BookmarkStore.resolve(id:)` performs
    /// `URL(resolvingBookmarkData:)` + re-mint + `fileExists` — synchronous iCloud-coordinated
    /// I/O. Doing that per row on the main actor stalled the UI ~2s on root pull-to-refresh and
    /// the relocate tap, so the heavy resolution MUST stay off the main actor (the list resolves
    /// N bookmarks; `ProjectGridViewModel.load()` resolving a single bookmark on the main actor
    /// is NOT a workable mirror here).
    ///
    /// But `resolve(id:)` ALSO mutates the `@Observable` store (`replace` UserDefaults write +
    /// `lastError`), and the store has no synchronization — calling it off-main while
    /// `touchOpened()` mutates the same store on the main actor is a data race. So we split the
    /// work along the grid VM's actual philosophy (offload *value* work, mutate *state* on the
    /// main actor):
    ///   1. Off the main actor, `BookmarkStore.resolvePure(data:resolver:)` does ONLY the
    ///      thread-safe resolution I/O and returns per-row VALUE types (resolved URL or error,
    ///      plus any refreshed bookmark bytes / stale-refresh failure to apply).
    ///   2. Back on the main actor, we apply the persistence (`replace`) + `lastError` and build
    ///      `rows`. The store is therefore only ever mutated from the main actor — race-free.
    /// The MRU snapshot is captured up front so ordering stays deterministic regardless of
    /// concurrency.
    func refresh() async {
        // MRU-ordered snapshot (sort key is `lastOpenedAt`, independent of resolution result).
        // The snapshot carries the bookmark BYTES so the off-main resolution needs no store reads.
        let entries = bookmarkStore.all()
        let resolver = bookmarkStore.resolver

        // Resolve off the main actor — PURE value work only, no store mutation. We iterate the
        // snapshot in order and build results in the same order, so the result is deterministic —
        // no concurrency-driven reordering.
        let results: [(entry: StoredBookmark, resolution: BookmarkStore.PureResolution)] =
            await Task.detached(priority: .userInitiated) {
                entries.map { entry in
                    (entry, BookmarkStore.resolvePure(data: entry.bookmark, resolver: resolver))
                }
            }.value

        // Back on the main actor: apply persistence + error side effects, then publish rows.
        // All store mutation happens here, on the main actor — never from the detached task.
        var newRows: [ProjectListRow] = []
        newRows.reserveCapacity(results.count)
        for (entry, resolution) in results {
            if let refreshed = resolution.refreshedBookmark {
                bookmarkStore.replace(id: entry.id, bookmark: refreshed, openedAt: entry.lastOpenedAt)
            }
            if let failure = resolution.staleRefreshFailureDescription {
                bookmarkStore.lastError = .staleRefreshFailed(description: failure)
            }
            if let url = resolution.url {
                newRows.append(ProjectListRow(
                    id: entry.id,
                    state: .ok(displayName: url.lastPathComponent, lastOpenedAt: entry.lastOpenedAt),
                    lastOpenedAt: entry.lastOpenedAt
                ))
            } else {
                newRows.append(ProjectListRow(id: entry.id, state: .missing, lastOpenedAt: entry.lastOpenedAt))
            }
        }
        rows = newRows
    }

    /// Persists a newly-picked folder and returns its bookmark id so the caller can navigate.
    /// Bookmark save happens BEFORE we return — caller can safely push to the grid using the id.
    @discardableResult
    func saveNewlyPickedFolder(url: URL) async throws -> String {
        guard url.startAccessingSecurityScopedResource() else {
            throw BookmarkResolutionError.accessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let bookmark = try url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let id = bookmarkStore.save(bookmark: bookmark)
        await refresh()
        return id
    }

    /// Replaces the bookmark for an existing row (relocate flow, AC #6).
    func relocate(rowID: String, to url: URL) async throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw BookmarkResolutionError.accessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let bookmark = try url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        bookmarkStore.replace(id: rowID, bookmark: bookmark)
        await refresh()
    }

    /// Bumps the MRU timestamp when the user navigates into a project.
    func touchOpened(rowID: String) async {
        bookmarkStore.touch(id: rowID)
        await refresh()
    }
}
