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
    func refresh() {
        rows = bookmarkStore.all().map { entry in
            do {
                let url = try bookmarkStore.resolve(id: entry.id)
                return ProjectListRow(
                    id: entry.id,
                    state: .ok(displayName: url.lastPathComponent, lastOpenedAt: entry.lastOpenedAt),
                    lastOpenedAt: entry.lastOpenedAt
                )
            } catch {
                return ProjectListRow(id: entry.id, state: .missing, lastOpenedAt: entry.lastOpenedAt)
            }
        }
    }

    /// Persists a newly-picked folder and returns its bookmark id so the caller can navigate.
    /// Bookmark save happens BEFORE we return — caller can safely push to the grid using the id.
    @discardableResult
    func saveNewlyPickedFolder(url: URL) throws -> String {
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
        refresh()
        return id
    }

    /// Replaces the bookmark for an existing row (relocate flow, AC #6).
    func relocate(rowID: String, to url: URL) throws {
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
        refresh()
    }

    /// Bumps the MRU timestamp when the user navigates into a project.
    func touchOpened(rowID: String) {
        bookmarkStore.touch(id: rowID)
        refresh()
    }
}
