import Foundation
import Observation

enum ProjectGridState: Equatable {
    case loading
    case empty
    case populated([URL])
    case error(String)
}

/// `@Observable` view model for `ProjectGridView`. Holds the resolved folder URL and the scan
/// result. AIP §3: scan is sync `throws` but called from a detached task to keep the main
/// actor responsive.
///
/// Finding #6: `displayName` is a STORED property set once during `load()`. It is NOT a
/// computed property that re-resolves the bookmark on every render — that pattern triggered
/// `URL(resolvingBookmarkData:)` on the main actor every time SwiftUI invalidated the body
/// (iCloud-backed bookmarks can block on network I/O). Resolution errors now flow through
/// the existing `.error(...)` state instead of being silently swallowed via `try?`.
@Observable
@MainActor
final class ProjectGridViewModel {
    let bookmarkStore: BookmarkStore
    let bookmarkID: String
    var state: ProjectGridState = .loading

    /// Folder display name, set in `load()` after a successful resolve. Defaults to "Project"
    /// before the first load (used as the navigation title placeholder during the loading
    /// state). Never derived via `try?` from a SwiftUI body.
    private(set) var displayName: String = "Project"

    /// Resolved folder URL. Set during `load()` after a successful bookmark resolution.
    /// Used by `ProjectGridView.onOpen` callback to pass the folder URL to `AnnotatorView`
    /// for the per-project `AnnotationStore` lifecycle (I2 integration).
    private(set) var folderURL: URL? = nil

    init(bookmarkStore: BookmarkStore, bookmarkID: String) {
        self.bookmarkStore = bookmarkStore
        self.bookmarkID = bookmarkID
    }

    func load() async {
        state = .loading
        do {
            let url = try bookmarkStore.resolve(id: bookmarkID)
            // Resolved successfully — refresh displayName and folderURL from the live URL.
            displayName = url.lastPathComponent
            folderURL = url

            // `startAccessingSecurityScopedResource()` returns true for security-scoped
            // bookmarks (iCloud Drive, external volumes). For local temp paths (UI tests,
            // Documents directory without entitlement) it returns false as a no-op.
            // We proceed regardless — if access truly fails the scan will throw and
            // the `.error` state will surface via the catch below.
            let accessStarted = url.startAccessingSecurityScopedResource()
            defer {
                if accessStarted { url.stopAccessingSecurityScopedResource() }
            }

            let folder = ProjectFolder(url: url)
            let scan = try await Task.detached(priority: .userInitiated) {
                try folder.scanImages()
            }.value

            state = scan.isEmpty ? .empty : .populated(scan)
        } catch let resolutionError as BookmarkResolutionError {
            state = .error(Self.describe(resolutionError))
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private static func describe(_ err: BookmarkResolutionError) -> String {
        switch err {
        case .unknownId: return "That project no longer exists."
        case .notFound: return "That folder couldn't be found."
        case .accessDenied: return "Couldn't access that folder."
        case .notADirectory: return "That isn't a folder."
        case .foundation(let detail): return detail
        }
    }
}
