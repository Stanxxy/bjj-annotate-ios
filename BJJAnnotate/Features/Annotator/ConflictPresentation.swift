import SwiftUI

/// T20 — Conflict banner + read-only diff modal presentation.
///
/// AC #34/#35/#36: presents `ConflictEvent` over both `AnnotatorView` and
/// `ProjectGridView`. The banner copy + modal title are locked
/// (`LockedCopy.conflictBanner` + `LockedCopy.conflictDiffTitle`).
///
/// `ConflictPresentation` reads the store and exposes presentation-level
/// state. Dismissing the banner clears `store.lastConflict`; dismissing the
/// modal does NOT (per AC #36 — the user explicitly closes the banner).
@MainActor
@Observable
final class ConflictPresentation {
    let store: AnnotationStore

    init(store: AnnotationStore) {
        self.store = store
    }

    var bannerMessage: String? {
        return store.lastConflict == nil ? nil : LockedCopy.conflictBanner
    }

    var modalTitle: String { LockedCopy.conflictDiffTitle }

    var differingAnnotationIds: [Int] {
        return store.lastConflict?.differingAnnotationIds ?? []
    }

    /// Called from the banner's close button. Clears the conflict surface.
    func dismiss() {
        store.clearLastConflict()
    }
}

/// Renders the conflict banner (taps open the diff modal). Anchored via
/// `.safeAreaInset(edge: .top)` on the host view.
struct ConflictBanner: View {
    @Bindable var presentation: ConflictPresentation
    @State private var isShowingModal: Bool = false

    var body: some View {
        if let message = presentation.bannerMessage {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Button {
                    isShowingModal = true
                } label: {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("Annotator.ConflictBanner.Body")
                Button {
                    presentation.dismiss()
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
                ConflictDiffModal(presentation: presentation, onClose: { isShowingModal = false })
            }
        }
    }
}

/// Read-only modal listing the differing annotation ids. Dismiss does NOT
/// clear the banner (AC #36).
struct ConflictDiffModal: View {
    @Bindable var presentation: ConflictPresentation
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Differing annotations") {
                    if presentation.differingAnnotationIds.isEmpty {
                        Text("No structural differences detected.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(presentation.differingAnnotationIds, id: \.self) { id in
                            Text("instance \(id)")
                                .accessibilityIdentifier("Annotator.ConflictDiff.Row.\(id)")
                        }
                    }
                }
            }
            .navigationTitle(presentation.modalTitle)
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
