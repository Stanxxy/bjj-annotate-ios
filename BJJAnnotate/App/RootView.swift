import SwiftUI

/// App shell: `NavigationStack` hosting the project list and pushing to the project grid.
///
/// I3 (integration): `RootView` creates a `ProjectAnnotationConflictWatcher` per
/// grid push and passes it to both `ProjectGridView` (for the project-level banner)
/// and down to `AnnotatorView` (which mirrors its per-image store conflict events
/// into the watcher).
struct RootView: View {
    @State var listViewModel: ProjectListViewModel
    let thumbnailCache: ThumbnailCache
    let bookmarkStore: BookmarkStore

    @State private var path: [NavigationDestination] = []

    enum NavigationDestination: Hashable {
        case grid(bookmarkID: String)
        /// T13: pushed when the user taps a thumbnail in the project grid.
        /// Carries both the bookmark id (for re-resolution), the image URL,
        /// AND the folder URL (so AnnotatorView can own the per-project lifecycle).
        case annotator(bookmarkID: String, imageURL: URL, folderURL: URL)
    }

    init(bookmarkStore: BookmarkStore, thumbnailCache: ThumbnailCache = ThumbnailCache()) {
        self.bookmarkStore = bookmarkStore
        self.thumbnailCache = thumbnailCache
        _listViewModel = State(initialValue: ProjectListViewModel(bookmarkStore: bookmarkStore))
    }

    var body: some View {
        NavigationStack(path: $path) {
            ProjectListView(viewModel: listViewModel) { row in
                path.append(.grid(bookmarkID: row.id))
            }
            .navigationDestination(for: NavigationDestination.self) { destination in
                switch destination {
                case .grid(let bookmarkID):
                    let gridVM = ProjectGridViewModel(bookmarkStore: bookmarkStore, bookmarkID: bookmarkID)
                    ProjectGridView(viewModel: gridVM, cache: thumbnailCache) { imageURL, folderURL in
                        path.append(.annotator(bookmarkID: bookmarkID, imageURL: imageURL, folderURL: folderURL))
                    }
                case .annotator(let bookmarkID, let imageURL, let folderURL):
                    // I3: resolve the folder URL from bookmark to produce the conflict watcher.
                    AnnotatorView(
                        imageURL: imageURL,
                        folderURL: folderURL
                    )
                }
            }
        }
    }
}
