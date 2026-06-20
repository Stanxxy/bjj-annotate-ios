import SwiftUI

/// T18 — Athlete picker model + view.
///
/// `AthletePickerModel` is the pure value-type that drives the SwiftUI sheet:
///   - `rows` are the existing `athlete-N` ids, sorted ascending.
///   - `bottomRow` is either the new-athlete allocator row (locked copy via
///     `LockedCopy.newAthleteRow`) or the project-full row (locked copy via
///     `LockedCopy.projectFullAthleteCap`) at the cap.
///   - `select(...)` rebinds; `allocateNew(...)` allocates + binds + returns
///     the new id (or nil at cap).
///
/// The model deliberately does NOT own UI state — it reads from the live
/// store every time. That mirrors the project-list refresh discipline:
/// derived state is recomputed, never cached.
@MainActor
final class AthletePickerModel {
    let store: AnnotationStore

    init(store: AnnotationStore) {
        self.store = store
    }

    struct Row: Identifiable, Equatable {
        let athleteId: String
        let colorHex: String
        var id: String { athleteId }
    }

    enum BottomRow: Equatable {
        case newAthlete(String)
        case locked(String)
    }

    var rows: [Row] {
        let athletes = store.coco.bjj_annotate_meta?.athletes ?? []
        return athletes
            .compactMap { athlete -> Row? in
                Row(athleteId: athlete.id, colorHex: athlete.color_hex)
            }
            .sorted { lhs, rhs in
                let lhsN = AthletePalette.athleteNumber(lhs.athleteId) ?? Int.max
                let rhsN = AthletePalette.athleteNumber(rhs.athleteId) ?? Int.max
                return lhsN < rhsN
            }
    }

    var bottomRow: BottomRow {
        let athletes = store.coco.bjj_annotate_meta?.athletes ?? []
        if AthleteRegistry.allocate(in: athletes) == nil {
            return .locked(LockedCopy.projectFullAthleteCap)
        }
        return .newAthlete(LockedCopy.newAthleteRow)
    }

    /// Rebinds an existing athlete-id to the selected instance.
    func select(athleteId: String, on instanceId: Int) {
        store.setAthleteId(instanceId: instanceId, athleteId: athleteId)
    }

    /// Allocates a new athlete + binds it to the selected instance. Returns
    /// the new id, or nil at the 8-athlete cap.
    @discardableResult
    func allocateNew(on instanceId: Int) -> String? {
        return store.allocateAndBindAthlete(toInstanceId: instanceId)
    }

    /// Removes an athlete from the project dictionary. If any annotations reference
    /// this athlete, their athlete_id is cleared before removal.
    func remove(athleteId: String) {
        store.removeAthlete(athleteId: athleteId)
    }
}

struct AthletePicker: View {
    @State var model: AthletePickerModel
    let selectedInstanceId: Int?
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.rows) { row in
                        Button {
                            if let id = selectedInstanceId {
                                model.select(athleteId: row.athleteId, on: id)
                                onDismiss()
                            }
                        } label: {
                            HStack {
                                Circle()
                                    .fill(Color(hex: row.colorHex) ?? .gray)
                                    .frame(width: 16, height: 16)
                                Text(row.athleteId)
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                        }
                        .accessibilityIdentifier("Annotator.AthletePicker.Row.\(row.athleteId)")
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                model.remove(athleteId: row.athleteId)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .accessibilityIdentifier("Annotator.AthletePicker.Row.\(row.athleteId).Delete")
                        }
                    }
                }
                Section {
                    bottomRowView
                }
            }
            .navigationTitle("Athlete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDismiss)
                }
            }
            .accessibilityIdentifier("Annotator.AthletePicker")
        }
    }

    @ViewBuilder
    private var bottomRowView: some View {
        switch model.bottomRow {
        case .newAthlete(let copy):
            Button {
                if let id = selectedInstanceId {
                    _ = model.allocateNew(on: id)
                    onDismiss()
                }
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.tint)
                    Text(copy)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.vertical, 6)
            }
            .accessibilityIdentifier("Annotator.AthletePicker.NewAthlete")
        case .locked(let copy):
            HStack {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                Text(copy)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 6)
            .accessibilityIdentifier("Annotator.AthletePicker.Locked")
        }
    }
}
