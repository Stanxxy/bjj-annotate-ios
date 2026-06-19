import SwiftUI

/// T19 — Instance list model + view.
///
/// AC #12/#13: one row per annotation, tap selects the box on canvas.
/// AC #14 mobile-first: bottom sheet on compact, right rail on regular.
///        Adaptive branch goes through `Layout.AdaptiveAnchor` so the
///        size-class signal stays the only adaptive input (R-UI-1).
///
/// Empty state copy: `LockedCopy.instanceListEmptyState`.
@MainActor
final class InstanceListModel {
    let store: AnnotationStore

    init(store: AnnotationStore) {
        self.store = store
    }

    struct Row: Identifiable, Equatable {
        let instanceId: Int
        let label: String
        /// nil when the row is a referee — the view renders system gray
        /// (Designer §2.4). Athletes use the 8-color palette.
        let colorHex: String?
        var id: Int { instanceId }
    }

    var rows: [Row] {
        return store.coco.annotations
            .sorted { $0.id < $1.id }
            .map { ann in
                if ann.category_id == ClassCategory.ref.rawValue {
                    return Row(instanceId: ann.id, label: LockedCopy.classChipRef, colorHex: nil)
                }
                let label = ann.attributes.athlete_id ?? "—"
                let colorHex = ann.attributes.athlete_id.flatMap(AthletePalette.hex(forAthleteId:))
                return Row(instanceId: ann.id, label: label, colorHex: colorHex)
            }
    }

    var emptyStateCopy: String { LockedCopy.instanceListEmptyState }
}

/// Visible surface: adapts between right rail and bottom sheet via the size
/// class. Uses `Layout.AdaptiveAnchor` so R-UI-1 stays honored.
struct InstanceList: View {
    @State var model: InstanceListModel
    let selectedInstanceId: Int?
    let onSelect: (Int) -> Void
    var onDelete: ((Int) -> Void)? = nil

    var body: some View {
        Layout.AdaptiveAnchor(
            compact: { compactSheet },
            regular: { regularRail }
        )
    }

    /// iPhone portrait / iPad slide-over. Anchored to bottom 60% per Designer §5;
    /// the host (AnnotatorView) configures the .sheet detents — this view
    /// renders the body only.
    private var compactSheet: some View {
        listBody
            .accessibilityIdentifier("Annotator.InstanceList.Compact")
    }

    private var regularRail: some View {
        listBody
            .frame(maxWidth: 320)
            .accessibilityIdentifier("Annotator.InstanceList.Regular")
    }

    private var listBody: some View {
        Group {
            if model.rows.isEmpty {
                ContentUnavailableView {
                    Image(systemName: "square.dashed")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                } description: {
                    Text(model.emptyStateCopy)
                        .multilineTextAlignment(.center)
                }
                .accessibilityIdentifier("Annotator.InstanceList.Empty")
            } else {
                List {
                    ForEach(model.rows) { row in
                        Button {
                            onSelect(row.instanceId)
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(rowColor(row))
                                    .frame(width: 14, height: 14)
                                Text(row.label)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if row.instanceId == selectedInstanceId {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.accent)
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("Annotator.InstanceList.Row.\(row.instanceId)")
                        .accessibilityLabel(row.label)
                        .accessibilityHint("Selects this box on the canvas.")
                        .swipeActions(edge: .trailing) {
                            if let del = onDelete {
                                Button(role: .destructive) {
                                    del(row.instanceId)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .accessibilityIdentifier("Annotator.InstanceList.Row.\(row.instanceId).Delete")
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func rowColor(_ row: InstanceListModel.Row) -> Color {
        guard let hex = row.colorHex else { return .secondary }
        return Color(hex: hex) ?? .secondary
    }
}
