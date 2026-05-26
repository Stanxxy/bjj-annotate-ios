import SwiftUI

/// Root project list surface. Three states: empty / populated / missing-row inline.
///
/// Designer pack §Section 1; PM AC #4 / #5 / #6.
struct ProjectListView: View {
    @Bindable var viewModel: ProjectListViewModel
    @State private var pickerMode: PickerMode? = nil
    @State private var lastError: String? = nil
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
        .navigationTitle("Projects")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
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
        .alert("Couldn't open folder", isPresented: .constant(lastError != nil), actions: {
            Button("OK") { lastError = nil }
        }, message: {
            Text(lastError ?? "")
        })
        .task {
            viewModel.refresh()
        }
        .refreshable {
            viewModel.refresh()
        }
    }

    // MARK: - States

    private var emptyState: some View {
        VStack {
            Spacer()
            ContentUnavailableView {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } description: {
                Text(LockedCopy.emptyProjectList)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            openFolderButton
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier("ProjectList.EmptyState")
    }

    private var populatedState: some View {
        VStack(spacing: 0) {
            List {
                ForEach(viewModel.rows) { row in
                    rowView(for: row)
                }
            }
            .listStyle(.insetGrouped)
            .accessibilityIdentifier("ProjectList.List")
            .accessibilityAction(named: "Refresh") {
                viewModel.refresh()
            }

            openFolderButton
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func rowView(for row: ProjectListRow) -> some View {
        switch row.state {
        case .ok(let displayName, let lastOpenedAt):
            Button {
                viewModel.touchOpened(rowID: row.id)
                onOpen(row)
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
        do {
            switch mode {
            case .newProject:
                let newID = try viewModel.saveNewlyPickedFolder(url: url)
                // Find the row we just created and open it.
                if let newRow = viewModel.rows.first(where: { $0.id == newID }) {
                    onOpen(newRow)
                }
            case .relocate(let rowID):
                try viewModel.relocate(rowID: rowID, to: url)
            }
        } catch {
            lastError = (error as? BookmarkResolutionError).map(describe) ?? error.localizedDescription
        }
    }

    private func describe(_ err: BookmarkResolutionError) -> String {
        switch err {
        case .unknownId: return "That project no longer exists."
        case .notFound: return "That folder couldn't be found."
        case .accessDenied: return "Couldn't access that folder. Try picking it again."
        case .notADirectory: return "That isn't a folder."
        case .foundation(let detail): return detail
        }
    }

    private func subtitle(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last opened " + formatter.localizedString(for: date, relativeTo: Date())
    }
}
