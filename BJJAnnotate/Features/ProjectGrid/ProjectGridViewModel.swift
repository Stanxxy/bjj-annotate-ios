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
@Observable
@MainActor
final class ProjectGridViewModel {
    let bookmarkStore: BookmarkStore
    let bookmarkID: String
    var state: ProjectGridState = .loading

    init(bookmarkStore: BookmarkStore, bookmarkID: String) {
        self.bookmarkStore = bookmarkStore
        self.bookmarkID = bookmarkID
    }

    func load() async {
        state = .loading
        do {
            let url = try bookmarkStore.resolve(id: bookmarkID)
            guard url.startAccessingSecurityScopedResource() else {
                state = .error("Couldn't access that folder.")
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

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

    var folderDisplayName: String {
        (try? bookmarkStore.resolve(id: bookmarkID).lastPathComponent) ?? "Project"
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
