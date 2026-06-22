import SwiftUI

/// Sectioned list for selecting and placing COCO keypoints.
///
/// Three sections: Head (1–5), Arms (6–11), Legs (12–17).
/// Each row shows the KeypointPalette color dot, keypoint name,
/// and a checkmark when the point has been placed.
/// The active point (the one that will receive the next tap on canvas) is
/// highlighted with an accent background.
///
/// A "Mirror L↔R" button at the bottom triggers `store.mirrorKeypoints`.
struct KeypointPickerView: View {

    let store: AnnotationStore
    let selectedInstanceId: Int?
    @Bindable var pickerVM: KeypointPickerViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Interaction hint — always visible so annotators know the gesture model.
            Text("Tap: place  ·  Tap dot: cycle visibility  ·  Drag dot: reposition")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            // Mirror button above the list so it stays in the zone visible above
            // the collapsed sheet. Previously in List.safeAreaInset(edge: .bottom),
            // but that placed it at y≈772 which is underneath the sheet overlay.
            mirrorButton
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            Divider()

            List {
                section(title: "Head",  definitions: KeypointDefinition.headGroup)
                section(title: "Arms",  definitions: KeypointDefinition.armsGroup)
                section(title: "Legs",  definitions: KeypointDefinition.legsGroup)
            }
            .listStyle(.insetGrouped)
        }
    }

    // MARK: - Section builder

    @ViewBuilder
    private func section(title: String, definitions: [KeypointDefinition]) -> some View {
        Section(header: Text(title).font(.caption).foregroundStyle(.secondary)) {
            ForEach(definitions, id: \.index) { kpDef in
                row(for: kpDef)
            }
        }
    }

    // MARK: - Row builder

    private func row(for kpDef: KeypointDefinition) -> some View {
        let isActive = pickerVM.activeKeypointIndex == kpDef.index
        let placed = isPlaced(index: kpDef.index)
        let kpColor = KeypointPalette.color(for: kpDef.side)

        return Button {
            pickerVM.activeKeypointIndex = kpDef.index
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(kpColor)
                    .frame(width: 14, height: 14)

                Text(kpDef.name)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if placed {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isActive ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("KeypointPicker.Row.\(kpDef.index)")
        .accessibilityLabel("\(kpDef.name)\(placed ? ", placed" : "")\(isActive ? ", active" : "")")
    }

    // MARK: - Mirror button

    private var mirrorButton: some View {
        Button {
            if let id = selectedInstanceId {
                store.mirrorKeypoints(instanceId: id)
            }
        } label: {
            Label("Mirror L↔R", systemImage: "arrow.left.arrow.right")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(selectedInstanceId == nil)
        .accessibilityIdentifier("KeypointPicker.MirrorButton")
    }

    // MARK: - Helpers

    private func isPlaced(index: Int) -> Bool {
        guard let id = selectedInstanceId,
              let ann = store.annotationsForCurrentImage.first(where: { $0.id == id }),
              let kps = ann.keypoints, kps.count == 51 else { return false }
        return pickerVM.isPlaced(index: index, in: kps)
    }
}
