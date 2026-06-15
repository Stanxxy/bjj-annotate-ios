import SwiftUI

/// Per-image annotation surface.
///
/// T13: navigation push from grid + zero-image guard.
/// T14: AnnotatorCanvasView (zoom/pan/double-tap).
/// T15: Box-tool drag → upsertBox.
/// T16: Selection + 8 handles + resize/move.
/// T17: Class chip row.
/// T18: Athlete picker sheet.
/// T19: Instance list (adaptive bottom-sheet / right-rail).
/// T20: Conflict banner + read-only diff modal.
/// T21: willResignActive synchronous flush bridge.
/// T22 (this commit): zero-image state + explicit Back action; consolidates the
///      presence decision through `AnnotatorImagePresence`.
///
/// The view is intentionally permissive of a nil `store` — the grid currently
/// pushes only with the image URL. A follow-up wires the `AnnotationStore` +
/// `CocoFileCoordinator` lifecycle (per-image read-on-appear / flush-on-resign).
struct AnnotatorView: View {
    let imageURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var tool: AnnotatorTool = .box
    @State private var rejectionToastVisible: Bool = false

    var body: some View {
        Group {
            switch AnnotatorImagePresence.evaluate(imageURL: imageURL) {
            case .imagePresent:
                imageBody
            case .missing:
                missingImageBody
            }
        }
        .navigationTitle(imageURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .accessibilityIdentifier("Annotator.BackButton")
                .accessibilityLabel("Back")
                .accessibilityHint("Returns to the project grid.")
            }
        }
        .accessibilityIdentifier("Annotator.Root")
        .overlay(alignment: .top) {
            if rejectionToastVisible {
                Text(LockedCopy.boxTooSmallToast)
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(Capsule())
                    .padding(.top, 12)
                    .transition(.opacity)
                    .accessibilityIdentifier("Annotator.BoxTooSmallToast")
                    .task {
                        // Task.sleep only throws on cancellation, which is the
                        // explicit signal that the toast was already dismissed
                        // (e.g., the user navigated back). In that case we
                        // simply abandon the auto-hide — the rejection state
                        // belongs to the view's lifecycle.
                        do {
                            try await Task.sleep(nanoseconds: 1_800_000_000)
                        } catch {
                            return
                        }
                        await MainActor.run { rejectionToastVisible = false }
                    }
            }
        }
    }

    private var imageBody: some View {
        AnnotatorCanvasView(
            imageURL: imageURL,
            tool: tool,
            rejectionToastVisible: $rejectionToastVisible
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var missingImageBody: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(AnnotatorImagePresence.missingCopy)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Button {
                dismiss()
            } label: {
                Text("Back to project")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)
            .accessibilityIdentifier("Annotator.MissingImage.BackButton")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier("Annotator.MissingImage")
    }
}
