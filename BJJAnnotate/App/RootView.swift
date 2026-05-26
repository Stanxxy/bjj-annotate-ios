import SwiftUI

/// App shell: `NavigationStack` hosting the project list and pushing to the project grid.
/// AIP §5: no `NavigationSplitView` in Phase 0 (revisit in Phase 1 when Annotator joins).
struct RootView: View {
    @State var listViewModel: ProjectListViewModel
    let thumbnailCache: ThumbnailCache
    let bookmarkStore: BookmarkStore

    @State private var path: [NavigationDestination] = []

    enum NavigationDestination: Hashable {
        case grid(bookmarkID: String)
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
                    ProjectGridView(viewModel: gridVM, cache: thumbnailCache)
                }
            }
        }
    }
}
