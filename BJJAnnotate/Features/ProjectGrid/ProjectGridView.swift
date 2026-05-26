import SwiftUI

/// Thumbnail grid surface. Three states: loading / populated / empty.
///
/// Designer pack §Section 2. Adaptive grid columns 100–160pt; pull-to-refresh available
/// in EVERY state including empty (Designer mandate: ContentUnavailableView wrapped in
/// a ScrollView so .refreshable fires).
struct ProjectGridView: View {
    @Bindable var viewModel: ProjectGridViewModel
    let cache: ThumbnailCache

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
        .navigationTitle(viewModel.folderDisplayName)
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
        .task {
            await viewModel.load()
        }
    }

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
                    ThumbnailCell(url: url, cache: cache)
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
