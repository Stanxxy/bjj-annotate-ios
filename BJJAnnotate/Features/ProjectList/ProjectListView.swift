import SwiftUI

/// Root project list surface. Three states: empty / populated / missing-row inline.
///
/// Designer pack §Section 1; PM AC #4 / #5 / #6.
struct ProjectListView: View {
    @ObservedObject var viewModel: ProjectListViewModel
    @State private var pickerMode: PickerMode? = nil
    var onOpen: (ProjectListRow) -> Void = { _ in }

    enum PickerMode: Identifiable {
        case newProject
        case relocate(rowID: String)
        var id: String {
            switch self {
            case .newProject: return "new"
            case .relocate(let rowID): return "relocate-\(rowID)"
            }
        }
    }

    var body: some View {
        Group {
            if viewModel.rows.isEmpty {
                emptyState
            } else {
                populatedState
            }
        }
        .safeAreaInset(edge: .top) {
            // T12: non-blocking banner driven by BookmarkStore.lastError.
            // Renders above content; dismiss action calls clearLastError().
            if let message = viewModel.bannerMessage {
                bannerView(message: message)
            }
        }
        .navigationTitle("Projects")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            // Designer Resolution #3 / PM Addendum: toolbar `+` ONLY on the populated state.
            // The Designer Mockup Pack §State 1b originally proposed BOTH the toolbar `+`
            // AND a persistent bottom CTA on populated state, but PM resolved this to
            // toolbar-only (Files-app pattern). Empty state retains the bottom CTA.
            // DO NOT re-add a bottom Open Folder button to `populatedState` citing the
            // Designer pack — PM is binding per chain order. See evaluator finding #3.
            if !viewModel.rows.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        pickerMode = .newProject
                    } label: {
                        Label("Open Folder", systemImage: "folder.badge.plus")
                    }
                    .accessibilityLabel("Open Folder")
                    .accessibilityHint("Presents the Files folder picker.")
                }
            }
        }
        .sheet(item: $pickerMode) { mode in
            FolderPicker(
                onPick: { url in
                    handlePick(url: url, mode: mode)
                },
                onCancel: {
                    pickerMode = nil
                }
            )
        }
        // L-3 carry-forward: picker errors route through `viewModel.surfacePickerError`
        // into `bookmarkStore.lastError` and surface via the same banner above.
        // The legacy picker-error alert (two sources of truth for picker failures) is
        // intentionally removed — single source of truth via BookmarkStore.lastError.
        .task {
            await viewModel.refresh()
        }
        .refreshable {
            await viewModel.refresh()
        }
    }

    // MARK: - States

    private var emptyState: some View {
        VStack {
            Spacer()
            EmptyStateView(
                systemImage: "folder.badge.plus",
                title: "No Projects",
                description: LockedCopy.emptyProjectList
            )
            .accessibilityIdentifier("ProjectList.EmptyState")
            Spacer()
            openFolderButton
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var populatedState: some View {
        // Finding #3 + Designer Resolution #3: NO bottom `openFolderButton` here. The toolbar
        // `+` is the ONLY new-project entry point on populated state.
        List {
            ForEach(viewModel.rows) { row in
                rowView(for: row)
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("ProjectList.List")
        .accessibilityAction(named: "Refresh") {
            Task { await viewModel.refresh() }
        }
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func rowView(for row: ProjectListRow) -> some View {
        switch row.state {
        case .ok(let displayName, let lastOpenedAt):
            Button {
                // Navigate immediately; the MRU bump + refresh runs async so it never blocks
                // the push (BUG B).
                onOpen(row)
                Task { await viewModel.touchOpened(rowID: row.id) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text(subtitle(for: lastOpenedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .accessibilityIdentifier("ProjectList.Row.\(row.id)")
            .accessibilityLabel(displayName)
            .accessibilityHint("Opens the project grid for this folder.")

        case .missing:
            Button {
                pickerMode = .relocate(rowID: row.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(LockedCopy.bookmarkErrorRow)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.leading)
                    Spacer()
                }
            }
            .accessibilityIdentifier("ProjectList.MissingRow.\(row.id)")
            // VoiceOver comma per Designer §1c (em-dash renders as a long pause).
            .accessibilityLabel("Folder not found, tap to relocate")
            .accessibilityHint("Presents the Files folder picker to relocate this project.")
        }
    }

    @ViewBuilder
    private func bannerView(message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                viewModel.dismissBanner()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("ProjectList.Banner.Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ProjectList.Banner")
    }

    private var openFolderButton: some View {
        Button {
            pickerMode = .newProject
        } label: {
            Text("Open Folder")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityIdentifier("ProjectList.OpenFolderButton")
        .accessibilityLabel("Open Folder")
        .accessibilityHint("Presents the Files folder picker.")
    }

    // MARK: - Pick handlers

    private func handlePick(url: URL, mode: PickerMode) {
        pickerMode = nil
        Task {
            do {
                switch mode {
                case .newProject:
                    let newID = try await viewModel.saveNewlyPickedFolder(url: url)
                    // Find the row we just created and open it.
                    if let newRow = viewModel.rows.first(where: { $0.id == newID }) {
                        onOpen(newRow)
                    }
                case .relocate(let rowID):
                    try await viewModel.relocate(rowID: rowID, to: url)
                }
            } catch {
                // L-3 carry-forward: route into the same banner surface as
                // decode/encode/stale-refresh errors. No second source of truth.
                viewModel.surfacePickerError(error)
            }
        }
    }

    private func subtitle(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last opened " + formatter.localizedString(for: date, relativeTo: Date())
    }
}
