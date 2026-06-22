import SwiftUI

/// T20 — Conflict banner + read-only diff modal presentation.
///
/// AC #34/#35/#36: presents `ConflictEvent` over both `AnnotatorView` and
/// `ProjectGridView`. The banner copy + modal title are locked
/// (`LockedCopy.conflictBanner` + `LockedCopy.conflictDiffTitle`).
///
/// Design choice: `ConflictPresentation` class is eliminated. `ConflictBanner`
/// and `ConflictDiffModal` receive `AnnotationStore` directly — the store is the
/// observable source of truth for `lastConflict`, so a thin wrapper class adds
/// nothing and doubles the observation chain. Commit note: eliminated wrapper,
/// pass AnnotationStore directly.

/// Renders the conflict banner (taps open the diff modal). Anchored via
/// `.safeAreaInset(edge: .top)` on the host view.
struct ConflictBanner: View {
    @ObservedObject var store: AnnotationStore
    @State private var isShowingModal: Bool = false

    var body: some View {
        if store.lastConflict != nil {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Button {
                    isShowingModal = true
                } label: {
                    Text(LockedCopy.conflictBanner)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("Annotator.ConflictBanner.Body")
                Button {
                    store.clearLastConflict()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("Annotator.ConflictBanner.Dismiss")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("Annotator.ConflictBanner")
            .sheet(isPresented: $isShowingModal) {
                ConflictDiffModal(store: store, onClose: { isShowingModal = false })
            }
        }
    }
}

/// Read-only modal listing the differing annotation ids. Dismiss does NOT
/// clear the banner (AC #36).
struct ConflictDiffModal: View {
    @ObservedObject var store: AnnotationStore
    let onClose: () -> Void

    private var differingAnnotationIds: [Int] {
        store.lastConflict?.differingAnnotationIds ?? []
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Differing annotations") {
                    if differingAnnotationIds.isEmpty {
                        Text("No structural differences detected.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(differingAnnotationIds, id: \.self) { id in
                            Text("instance \(id)")
                                .accessibilityIdentifier("Annotator.ConflictDiff.Row.\(id)")
                        }
                    }
                }
            }
            .navigationTitle(LockedCopy.conflictDiffTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onClose)
                }
            }
            .accessibilityIdentifier("Annotator.ConflictDiffModal")
        }
    }
}
