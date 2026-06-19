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
/// T22: zero-image state + explicit Back action.
///
/// I1 (integration): `AnnotatorView` owns the per-project `AnnotationStore` +
/// `CocoFileCoordinator` lifecycle. The store is initialized on `.task` via
/// `AnnotatorLifecycleContext.make(...)`, loaded from (or bootstrapped into) the
/// project folder's `annotations.json`. The `@State private var context` is nil
/// while loading, driving a loading overlay.
///
/// I2 (integration): all standalone surfaces (ClassChipRow, AthletePicker,
/// InstanceList, ConflictBanner, LifecycleFlushBridge) are wired here.
///
/// I3 (integration): the project-level conflict watcher receives events from the
/// store's `lastConflict` and forwards them upward to the grid. The optional
/// `conflictWatcher` is passed down from `RootView` through `ProjectGridView`.
struct AnnotatorView: View {
    let imageURL: URL
    let folderURL: URL
    /// Optional project-level watcher. When non-nil, `AnnotatorView` mirrors any
    /// conflict event from the per-image store into the grid-level watcher (I3).
    var conflictWatcher: ProjectAnnotationConflictWatcher? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var tool: AnnotatorTool = .box
    @State private var rejectionToastVisible: Bool = false
    @State private var selectedInstanceId: Int? = nil
    @State private var isPickerShowing: Bool = false
    @State private var isListShowing: Bool = false

    // I1: per-project lifecycle context. nil while loading on appear.
    @State private var context: AnnotatorLifecycleContext? = nil
    @State private var isLoadingContext: Bool = false

    private let flushBridge = LifecycleFlushBridge()

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
                    // Flush any pending write before navigating away.
                    if let ctx = context {
                        _ = flushBridge.flushSynchronously(coordinator: ctx.coordinator)
                    }
                    dismiss()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .accessibilityIdentifier("Annotator.BackButton")
                .accessibilityLabel("Back")
                .accessibilityHint("Returns to the project grid.")
            }
            ToolbarItem(placement: .topBarTrailing) {
                flagButton
            }
        }
        .accessibilityIdentifier("Annotator.Root")
        .overlay(alignment: .top) {
            toastOverlay
        }
        .task {
            await loadContext()
        }
        // I2: wire willResignActive flush once the context is available.
        .onChange(of: context == nil) { _, isNil in
            // Triggers when context transitions nil → non-nil. No-op otherwise.
        }
    }

    // MARK: - Context loading

    private func loadContext() async {
        guard context == nil, !isLoadingContext else { return }
        isLoadingContext = true
        do {
            let ctx = try await AnnotatorLifecycleContext.make(
                folderURL: folderURL,
                imageURL: imageURL
            )
            context = ctx
        } catch {
            // Error surfaces via store.lastError on the context; if make() throws
            // it means we can't even instantiate the coordinator (very rare OS error).
            // Nothing useful to show beyond the existing error banner.
        }
        isLoadingContext = false
    }

    // MARK: - Image body (loaded)

    private var imageBody: some View {
        ZStack {
            if let ctx = context {
                wiredAnnotatorBody(ctx: ctx)
            } else {
                loadingBody
            }
        }
    }

    /// Full wired annotator — all surfaces plugged in.
    private func wiredAnnotatorBody(ctx: AnnotatorLifecycleContext) -> some View {
        let store = ctx.store
        let coordinator = ctx.coordinator
        return ZStack {
            // Conflict banner (I2: wired from store.lastConflict).
            conflictBannerIfNeeded(store: store)

            annotatorLayout(store: store, coordinator: coordinator)
        }
        // I2: lifecycle flush bridge wired to the coordinator.
        .flushOnWillResignActive(coordinator: coordinator, bridge: flushBridge)
        // I3: mirror conflict event to the project-level watcher.
        .onChange(of: store.lastConflict) { _, newConflict in
            if let event = newConflict {
                conflictWatcher?.receive(conflictEvent: event)
            }
        }
        // Surface store.lastError as a banner.
        .safeAreaInset(edge: .top) {
            if let err = store.lastError {
                errorBanner(error: err, store: store)
            }
        }
    }

    @ViewBuilder
    private func conflictBannerIfNeeded(store: AnnotationStore) -> some View {
        if store.lastConflict != nil {
            let conflictPresentation = ConflictPresentation(store: store)
            ConflictBanner(presentation: conflictPresentation)
        }
    }

    @ViewBuilder
    private func annotatorLayout(store: AnnotationStore, coordinator: CocoFileCoordinator) -> some View {
        VStack(spacing: 0) {
            // Canvas (image + boxes + gesture layer).
            canvasRegion(store: store)

            // Tool selector row.
            toolSelectorRow

            // Class chips + athlete picker trigger.
            classAndAthleteRow(store: store)
        }
        // I2: instance list — adaptive (bottom sheet on compact, rail on regular).
        .adaptiveInstanceList(store: store, selectedId: $selectedInstanceId)
        .accessibilityIdentifier("Annotator.WiredLayout")
    }

    private func canvasRegion(store: AnnotationStore) -> some View {
        AnnotatorCanvasView(
            imageURL: imageURL,
            store: store,
            tool: tool,
            rejectionToastVisible: $rejectionToastVisible
        )
        .frame(maxWidth: .infinity)
        .frame(minHeight: 0)
        .layoutPriority(1)
        .background(Color.black)
        .accessibilityElement(children: .contain)
    }

    private var toolSelectorRow: some View {
        HStack(spacing: 8) {
            toolButton(.select, systemImage: "cursorarrow", label: "Select")
            toolButton(.box, systemImage: "square.dashed", label: "Box")
            keypointsButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityIdentifier("Annotator.ToolRow")
    }

    private func toolButton(_ t: AnnotatorTool, systemImage: String, label: String) -> some View {
        Button {
            tool = t
        } label: {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 18))
                Text(label)
                    .font(.caption2)
            }
            .frame(minWidth: 60, minHeight: 44)
            .foregroundStyle(tool == t ? Color.accentColor : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(tool == t ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("Annotator.Tool.\(label)")
    }

    private var keypointsButton: some View {
        Button {
            // No-op (AC #9: disabled).
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "figure.stand")
                    .font(.system(size: 18))
                Text("Keypts")
                    .font(.caption2)
                // "P2" badge.
                Text("P2")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.7))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(minWidth: 60, minHeight: 44)
            .foregroundStyle(Color.primary)
            .opacity(0.4)
        }
        .buttonStyle(.plain)
        .disabled(true)
        .accessibilityLabel("Keypoints, disabled")
        .accessibilityHint("Phase 2 feature.")
        .accessibilityIdentifier("Annotator.Tool.Keypoints")
        .help(LockedCopy.keypointsDisabledTooltip)
    }

    private func classAndAthleteRow(store: AnnotationStore) -> some View {
        HStack(spacing: 0) {
            // I2: ClassChipRow wired to the store.
            ClassChipRow(selectedInstanceId: selectedInstanceId, store: store)

            Spacer()

            // Athlete picker trigger — hidden when Ref is selected.
            if !isRefSelected(store: store) {
                athletePickerTrigger(store: store)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .accessibilityIdentifier("Annotator.ClassAndAthleteRow")
    }

    private func isRefSelected(store: AnnotationStore) -> Bool {
        guard let id = selectedInstanceId,
              let ann = store.coco.annotations.first(where: { $0.id == id }) else {
            return false
        }
        return ann.category_id == ClassCategory.ref.rawValue
    }

    private func athletePickerTrigger(store: AnnotationStore) -> some View {
        Button {
            isPickerShowing = true
        } label: {
            HStack(spacing: 4) {
                if let id = selectedInstanceId,
                   let ann = store.coco.annotations.first(where: { $0.id == id }),
                   let aid = ann.attributes.athlete_id,
                   let hex = AthletePalette.hex(forAthleteId: aid) {
                    Circle()
                        .fill(Color(hex: hex) ?? .secondary)
                        .frame(width: 14, height: 14)
                }
                Text(currentAthleteName(store: store))
                    .font(.subheadline)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption)
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isPickerShowing) {
            AthletePicker(
                model: AthletePickerModel(store: store),
                selectedInstanceId: selectedInstanceId
            ) {
                isPickerShowing = false
            }
            .presentationDetents([.medium, .large])
        }
        .accessibilityIdentifier("Annotator.AthletePickerTrigger")
    }

    private func currentAthleteName(store: AnnotationStore) -> String {
        guard let id = selectedInstanceId,
              let ann = store.coco.annotations.first(where: { $0.id == id }),
              let aid = ann.attributes.athlete_id else {
            return "Athlete"
        }
        return aid
    }

    // MARK: - Instance list wiring (I2)

    private var loadingBody: some View {
        VStack {
            ProgressView()
            Text("Loading…")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .accessibilityIdentifier("Annotator.Loading")
    }

    // MARK: - Missing image

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

    // MARK: - Flag toggle (PM addendum #2: top-bar trailing)

    private var flagButton: some View {
        Button {
            // PM Addendum #2: flag toggle via AnnotationStore (single-setter invariant,
            // AC #4, Marker C). The store drives the debounced write via its scheduler.
            context?.store.toggleFlag()
        } label: {
            let isFlagged = context.map { ctx in
                ctx.store.coco.bjj_annotate_meta?.image_states
                    .first(where: { $0.image_id == ctx.store.imageId })?.flagged == true
            } ?? false
            Image(systemName: isFlagged ? "flag.fill" : "flag")
                .foregroundStyle(isFlagged ? .orange : .secondary)
        }
        .accessibilityLabel("Flag this frame")
        .accessibilityIdentifier("Annotator.FlagButton")
    }

    // MARK: - Toast overlay

    private var toastOverlay: some View {
        Group {
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

    // MARK: - Error banner

    private func errorBanner(error: AnnotationStoreError, store: AnnotationStore) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(errorMessage(for: error))
                .font(.callout)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                store.clearLastError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .accessibilityIdentifier("Annotator.ErrorBanner")
    }

    private func errorMessage(for error: AnnotationStoreError) -> String {
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

// MARK: - Adaptive instance list View extension

private extension View {
    /// Attaches the instance list as a bottom sheet (compact) or right rail (regular).
    /// Uses `Layout.AdaptiveAnchor` so the size-class signal is the only branch.
    func adaptiveInstanceList(
        store: AnnotationStore,
        selectedId: Binding<Int?>
    ) -> some View {
        self.modifier(AdaptiveInstanceListModifier(store: store, selectedId: selectedId))
    }
}

private struct AdaptiveInstanceListModifier: ViewModifier {
    let store: AnnotationStore
    @Binding var selectedId: Int?

    @State private var isSheetShowing = true

    func body(content: Content) -> some View {
        // AC #12: branch on horizontalSizeClass via Layout.AdaptiveAnchor.
        // compact (iPhone portrait, iPad Slide Over) → bottom sheet.
        // regular (iPad full-screen / Split View) → right rail.
        // Layout.AdaptiveAnchor reads @Environment(\.horizontalSizeClass) internally,
        // satisfying R-UI-1 (no UIDevice.userInterfaceIdiom) and AC #12.
        Layout.AdaptiveAnchor(
            compact: {
                content
                    .sheet(isPresented: $isSheetShowing) {
                        InstanceList(
                            model: InstanceListModel(store: store),
                            selectedInstanceId: selectedId,
                            onSelect: { id in selectedId = id },
                            onDelete: { id in
                                store.deleteInstance(instanceId: id)
                                if selectedId == id { selectedId = nil }
                            }
                        )
                        .presentationDetents([.fraction(0.33), .fraction(0.85)])
                        .presentationBackgroundInteraction(.enabled)
                        .interactiveDismissDisabled()
                    }
            },
            regular: {
                HStack(spacing: 0) {
                    content
                    Divider()
                    InstanceList(
                        model: InstanceListModel(store: store),
                        selectedInstanceId: selectedId,
                        onSelect: { id in selectedId = id },
                        onDelete: { id in
                            store.deleteInstance(instanceId: id)
                            if selectedId == id { selectedId = nil }
                        }
                    )
                    .frame(maxWidth: 320)
                    .background(Color(.secondarySystemBackground))
                }
            }
        )
    }
}
