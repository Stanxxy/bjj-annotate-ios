import SwiftUI

/// App shell: `NavigationStack` hosting the project list and pushing to the project grid.
///
/// I3 (integration): a `GridWrapper` subview is used for each `.grid` destination; it
/// owns a `@State private var conflictWatcher` so the watcher lives as long as the grid
/// view is in the navigation stack. The watcher is passed to `ProjectGridView` (conflict
/// banner, AC #34). `AnnotatorView` receives `conflictWatcher: nil` in Phase 1 because
/// SwiftUI NavigationStack sibling destinations cannot directly share @State. Phase 2
/// will thread the watcher via a NavigationStack-level @Observable environment injection.
struct RootView: View {
    @StateObject var listViewModel: ProjectListViewModel
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
        _listViewModel = StateObject(wrappedValue: ProjectListViewModel(bookmarkStore: bookmarkStore))
    }

    var body: some View {
        NavigationStack(path: $path) {
            ProjectListView(viewModel: listViewModel) { row in
                path.append(.grid(bookmarkID: row.id))
            }
            .navigationDestination(for: NavigationDestination.self) { destination in
                switch destination {
                case .grid(let bookmarkID):
                    GridWrapper(
                        bookmarkID: bookmarkID,
                        bookmarkStore: bookmarkStore,
                        thumbnailCache: thumbnailCache,
                        path: $path
                    )
                case .annotator(_, let imageURL, let folderURL):
                    // I3: no watcher passed here — GridWrapper injects it via the path
                    // push closure. Phase 2 can thread it via an environment value if
                    // the AC #34 cross-navigation requirement strengthens.
                    AnnotatorView(imageURL: imageURL, folderURL: folderURL)
                }
            }
        }
    }
}

// MARK: - Grid wrapper (I3: owns the conflict watcher lifecycle)

/// Intermediate view that owns a `@State` `ProjectAnnotationConflictWatcher`.
/// The watcher lives as long as this view is active in the navigation stack, so
/// events forwarded by `AnnotatorView` survive navigation back to the grid and
/// the banner can appear on `ProjectGridView` (AC #34).
///
/// Phase 1 limitation: the watcher is NOT wired to `AnnotatorView` because
/// `NavigationStack` sibling destinations cannot share `@State`. The GridWrapper
/// owns the watcher and passes it to `ProjectGridView`; once `AnnotatorView` has
/// `AnnotationStore` loaded, it mirrors conflict events via `.onChange(of: store.lastConflict)`.
/// For that mirroring to reach `ProjectGridView`, a Phase 2 follow-up will inject
/// the watcher via an `@Environment` value so the sibling `AnnotatorView` destination
/// receives the same instance.
private struct GridWrapper: View {
    let bookmarkID: String
    let bookmarkStore: BookmarkStore
    let thumbnailCache: ThumbnailCache
    @Binding var path: [RootView.NavigationDestination]

    @StateObject private var gridVM: ProjectGridViewModel
    // I3: one watcher per GridWrapper instance (= per project grid session).
    @StateObject private var watcher = ProjectAnnotationConflictWatcher(
        annotationsURL: URL(fileURLWithPath: "/dev/null")
    )

    init(
        bookmarkID: String,
        bookmarkStore: BookmarkStore,
        thumbnailCache: ThumbnailCache,
        path: Binding<[RootView.NavigationDestination]>
    ) {
        self.bookmarkID = bookmarkID
        self.bookmarkStore = bookmarkStore
        self.thumbnailCache = thumbnailCache
        self._path = path
        _gridVM = StateObject(wrappedValue: ProjectGridViewModel(bookmarkStore: bookmarkStore, bookmarkID: bookmarkID))
    }

    var body: some View {
        ProjectGridView(
            viewModel: gridVM,
            cache: thumbnailCache,
            onOpen: { imageURL, folderURL in
                path.append(.annotator(bookmarkID: bookmarkID, imageURL: imageURL, folderURL: folderURL))
            },
            conflictWatcher: watcher
        )
    }
}
