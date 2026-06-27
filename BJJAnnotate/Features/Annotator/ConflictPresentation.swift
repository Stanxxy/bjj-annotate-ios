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
///
/// `ErrorBanner` is co-located here because it solves an identical reactive
/// observation problem: the banner must appear when `store.lastError` becomes
/// non-nil AND disappear when `clearLastError()` sets it to nil. Both require an
/// `@ObservedObject` child so SwiftUI re-renders on every `@Published` change.
/// Inlining the overlay in `AnnotatorView` (a non-observed struct) breaks both
/// directions — the dismiss button calls `clearLastError()` but the view never
/// invalidates, so the banner is undismissable.

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

/// Reactive error banner anchored via `.overlay(alignment: .top)` on `wiredAnnotatorBody`.
///
/// Observes `store.lastError` via `@ObservedObject` so SwiftUI re-renders on every
/// `@Published` change — both when a new error arrives (banner appears) and when
/// `clearLastError()` sets `lastError = nil` (banner disappears). This is identical to
/// the pattern used by `ConflictBanner` for `lastConflict`.
///
/// The banner must NOT be inlined as a method on `AnnotatorView`: that struct holds no
/// `@ObservedObject` reference to `AnnotationStore`, so inline overlay code only renders
/// once (the error present at the time `wiredAnnotatorBody` was last computed) and never
/// re-renders on subsequent `lastError` changes.
struct ErrorBanner: View {
    @ObservedObject var store: AnnotationStore

    var body: some View {
        if let err = store.lastError {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(Self.message(for: err))
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    store.clearLastError()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("Annotator.ErrorBanner.Dismiss")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("Annotator.ErrorBanner")
        }
    }

    /// Locked copy for each `AnnotationStoreError` case.
    static func message(for error: AnnotationStoreError) -> String {
        switch error {
        case .icloudMaterializationTimeout:
            return LockedCopy.icloudWaitingBanner
        case .decodeFailed, .readFailed:
            return "Could not load annotations — showing empty state."
        case .encodeFailed, .writeFailed:
            return "Could not save annotations — your changes may be lost."
        }
    }
}
