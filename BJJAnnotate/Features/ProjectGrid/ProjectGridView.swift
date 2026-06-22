import SwiftUI

/// Thumbnail grid surface. Three states: loading / populated / empty.
///
/// Designer pack §Section 2. Adaptive grid columns 100–160pt; pull-to-refresh available
/// in EVERY state including empty (Designer mandate: ContentUnavailableView wrapped in
/// a ScrollView so .refreshable fires).
///
/// I2/I3 (integration): the `onOpen` callback now passes BOTH the image URL and the
/// resolved folder URL so `RootView` can push `AnnotatorView` with the folder lifecycle.
/// `ProjectAnnotationConflictWatcher` is threaded through from `RootView` so a conflict
/// banner can surface on the grid even before opening the annotator.
struct ProjectGridView: View {
    @Bindable var viewModel: ProjectGridViewModel
    let cache: ThumbnailCache
    /// I2: callback now passes (imageURL, folderURL) so AnnotatorView can own the
    /// per-project lifecycle without re-resolving from the bookmarkID.
    var onOpen: (URL, URL) -> Void = { _, _ in }
    /// I3: optional project-level conflict watcher from RootView.
    var conflictWatcher: ProjectAnnotationConflictWatcher? = nil

    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 8)
    ]

    var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                loadingState
            case .populated(let urls):
                populatedState(urls: urls)
            case .empty:
                emptyState
            case .error(let message):
                errorState(message: message)
            }
        }
        .navigationTitle(viewModel.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await viewModel.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh")
                .accessibilityIdentifier("ProjectGrid.RefreshButton")
            }
        }
        // I3: conflict banner on ProjectGridView (AC #34).
        .safeAreaInset(edge: .top) {
            if let watcher = conflictWatcher, watcher.lastConflict != nil {
                gridConflictBanner(watcher: watcher)
            }
        }
        .task {
            await viewModel.load()
        }
    }

    // MARK: - Conflict banner (I3)

    @ViewBuilder
    private func gridConflictBanner(watcher: ProjectAnnotationConflictWatcher) -> some View {
        if let message = watcher.bannerMessage {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    watcher.dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("ProjectGrid.ConflictBanner.Dismiss")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.orange.opacity(0.15))
            .accessibilityIdentifier("ProjectGrid.ConflictBanner")
        }
    }

    // MARK: - States

    private var loadingState: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(0..<12, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.tertiarySystemFill))
                        .aspectRatio(1, contentMode: .fit)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable {
            await viewModel.load()
        }
        .accessibilityIdentifier("ProjectGrid.LoadingState")
    }

    private func populatedState(urls: [URL]) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(urls, id: \.self) { url in
                    Button {
                        // I2: pass both image URL and folder URL.
                        onOpen(url, viewModel.folderURL ?? url.deletingLastPathComponent())
                    } label: {
                        ThumbnailCell(url: url, cache: cache)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the annotator for this image.")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable {
            await viewModel.load()
        }
        .accessibilityIdentifier("ProjectGrid.PopulatedState")
        .accessibilityAction(named: "Refresh") {
            Task { await viewModel.load() }
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack {
                Spacer(minLength: 80)
                ContentUnavailableView {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 64))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                } description: {
                    Text(LockedCopy.emptyProjectGrid)
                        .multilineTextAlignment(.center)
                }
                Spacer(minLength: 80)
            }
            .frame(maxWidth: .infinity, minHeight: 600)
            .padding(.horizontal, 16)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable {
            await viewModel.load()
        }
        .accessibilityIdentifier("ProjectGrid.EmptyState")
        .accessibilityAction(named: "Refresh") {
            Task { await viewModel.load() }
        }
    }

    private func errorState(message: String) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                Spacer(minLength: 80)
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 64))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 80)
            }
            .frame(maxWidth: .infinity, minHeight: 600)
            .padding(.horizontal, 16)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable {
            await viewModel.load()
        }
        .accessibilityIdentifier("ProjectGrid.ErrorState")
    }
}
