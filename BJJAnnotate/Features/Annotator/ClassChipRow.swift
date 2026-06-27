import SwiftUI

/// T17 — Class chip row. Renders Gi / NoGi / Ref chips for the selected
/// annotation. Tap routes through `handleTap(category:on:store:)` so the
/// chip ⇄ store bridge is unit-testable.
///
/// AC #10 / AC #21 / Marker D / Addendum #1: the store's `setClass(...)`
/// already implements sticky update, athlete-id preservation across
/// Gi↔NoGi, clearing on Ref, and auto-binding the next id on Ref → athlete.
/// This view is the gesture-to-store seam.
struct ClassChipRow: View {
    let selectedInstanceId: Int?
    @ObservedObject var store: AnnotationStore

    var body: some View {
        HStack(spacing: 8) {
            chip(for: .gi)
            chip(for: .nogi)
            chip(for: .ref)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityIdentifier("Annotator.ClassChipRow")
    }

    private func chip(for category: ClassCategory) -> some View {
        let isActive = isActiveCategory(category)
        return Button {
            guard let id = selectedInstanceId else { return }
            Self.handleTap(category: category, on: id, store: store)
        } label: {
            Text(Self.label(for: category))
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 64, minHeight: 44)
                .padding(.horizontal, 12)
                .background(
                    Capsule().fill(isActive ? Color.accentColor.opacity(0.2) : Color(.tertiarySystemFill))
                )
                .overlay(
                    Capsule().strokeBorder(isActive ? Color.accentColor : Color.clear, lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
        .disabled(selectedInstanceId == nil)
        .accessibilityIdentifier("Annotator.ClassChip.\(Self.identifier(for: category))")
        .accessibilityLabel(Self.label(for: category))
    }

    /// Returns true when the chip's category matches the currently selected
    /// annotation's category — drives the active visual state.
    private func isActiveCategory(_ category: ClassCategory) -> Bool {
        guard let id = selectedInstanceId,
              let ann = store.coco.annotations.first(where: { $0.id == id }) else { return false }
        return ann.category_id == category.rawValue
    }

    // MARK: - Dispatch seam (unit-tested)

    /// Pure dispatch from chip tap to store mutation. Exposed `static` so
    /// `ClassChipRowTests` can exercise the bridge without instantiating the
    /// SwiftUI view.
    static func handleTap(category: ClassCategory, on instanceId: Int, store: AnnotationStore) {
        store.setClass(instanceId: instanceId, category: category)
    }

    /// Locked label for a given category. Routes through `LockedCopy` so the
    /// grep gate stays one-source-of-truth.
    static func label(for category: ClassCategory) -> String {
        switch category {
        case .gi: return LockedCopy.classChipGi
        case .nogi: return LockedCopy.classChipNoGi
        case .ref: return LockedCopy.classChipRef
        }
    }

    private static func identifier(for category: ClassCategory) -> String {
        switch category {
        case .gi: return "Gi"
        case .nogi: return "NoGi"
        case .ref: return "Ref"
        }
    }
}
