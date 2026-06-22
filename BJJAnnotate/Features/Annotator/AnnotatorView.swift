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
    @State private var keypointPickerVM = KeypointPickerViewModel()
    // Collapsed to .height(36) (handle-only strip) when the keypoint picker is active
    // so the 260pt safeAreaInset picker is not hidden behind the sheet.
    @State private var sheetDetent: PresentationDetent = .fraction(0.33)
    @State private var isPresentingShareSheet: Bool = false
    /// View-lock flag. When true ALL single-finger drags route to pan; keypoint
    /// taps are suppressed. Layered OVER `tool` — the enum stays closed (3 cases)
    /// and the selected box remains highlighted but immutable.
    @State private var isViewLocked: Bool = false

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
            ToolbarItemGroup(placement: .topBarTrailing) {
                flagButton
                shareButton
            }
        }
        .accessibilityIdentifier("Annotator.Root")
        // On iOS 26 a Group-level accessibilityIdentifier propagates to all
        // descendant elements, shadowing their own identifiers. Adding
        // .accessibilityElement(children: .contain) tells the engine to expose
        // Annotator.Root as a named container whose children remain independently
        // accessible with their own identifiers.
        .accessibilityElement(children: .contain)
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
        // ActivitySharePresenter is a zero-size transparent UIViewController embedded here
        // so it can present UIActivityViewController directly via UIKit. This avoids wrapping
        // UIActivityViewController in a SwiftUI .sheet, which conflicts with the annotator's
        // own bottom sheet (UIKit dismissal reaches the SwiftUI layer and removes the panel).
        .background(
            ActivitySharePresenter(
                url: folderURL.appendingPathComponent("annotations.json"),
                isPresented: $isPresentingShareSheet
            )
        )
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
        .overlay(alignment: .top) {
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
        canvasRegion(store: store)
            .adaptiveInstanceList(
                store: store,
                selectedId: $selectedInstanceId,
                selectedDetent: $sheetDetent,
                toolbarHeader: {
                    VStack(spacing: 0) {
                        toolSelectorRow(store: store)
                        classAndAthleteRow(store: store)
                    }
                    .background(.regularMaterial)
                }
            )
            // Collapse the sheet when the keypoint picker is active so the 260pt
            // safeAreaInset picker is not hidden behind the sheet.
            .onChange(of: tool == .keypoints && isAthleteSelected(store: store)) { _, isActive in
                withAnimation {
                    // .height(36): just the grab handle visible — keeps the picker
                    // list exposed (~200pt) so mirror button and rows aren't buried.
                    sheetDetent = isActive ? .height(36) : .fraction(0.33)
                }
            }
            .accessibilityIdentifier("Annotator.WiredLayout")
    }

    private func canvasRegion(store: AnnotationStore) -> some View {
        AnnotatorCanvasView(
            imageURL: imageURL,
            store: store,
            tool: tool,
            isViewLocked: isViewLocked,
            rejectionToastVisible: $rejectionToastVisible,
            selectedInstanceId: $selectedInstanceId,
            keypointPickerVM: keypointPickerVM
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .accessibilityElement(children: .contain)
        // Phase 2 (BUG2 fix): Show the keypoint picker as a canvas inset, NOT inside the
        // sheet toolbarHeader. The sheet only has the instance list and the compact toolbar
        // rows; the picker sits directly below the canvas (above the sheet) so the canvas
        // retains full height minus the picker inset (~260pt). The GeometryReader inside
        // AnnotatorCanvasView gets the reduced size after the inset, so tap-to-place
        // coordinate mapping remains correct.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if tool == .keypoints && isAthleteSelected(store: store) {
                KeypointPickerView(
                    store: store,
                    selectedInstanceId: selectedInstanceId,
                    pickerVM: keypointPickerVM
                )
                .frame(maxHeight: 260)
                .background(.regularMaterial)
            }
        }
    }

    private func toolSelectorRow(store: AnnotationStore) -> some View {
        HStack(spacing: 8) {
            toolButton(.select, systemImage: "cursorarrow", label: "Select")
            toolButton(.box, systemImage: "square.dashed", label: "Box")
            keypointsButton(store: store)
            Spacer()
            // Pan/Lock toggle — always present (not gated on selection).
            // off = lock.open / "Pan" label; on = lock.fill / "Locked" label.
            // Thumb-reachable at right edge; 44×44 minimum touch target.
            Button {
                isViewLocked.toggle()
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: isViewLocked ? "lock.fill" : "lock.open")
                        .font(.system(size: 18))
                    Text(isViewLocked ? "Locked" : "Pan")
                        .font(.caption2)
                }
                .frame(minWidth: 44, minHeight: 44)
                .foregroundStyle(isViewLocked ? Color.accentColor : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isViewLocked ? Color.accentColor.opacity(0.12) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isViewLocked ? "Pan locked — tap to unlock" : "Pan unlocked — tap to lock")
            .accessibilityIdentifier("Annotator.ViewLockButton")
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

    /// Keypoints tool button — enabled only when the selected instance is an athlete
    /// (not a referee). When no instance is selected or the selected instance is a
    /// referee, the button is disabled and shows a tooltip.
    private func keypointsButton(store: AnnotationStore) -> some View {
        let isEnabled = isAthleteSelected(store: store)
        let isActive = tool == .keypoints
        return Button {
            guard isEnabled else { return }
            tool = .keypoints
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "figure.stand")
                    .font(.system(size: 18))
                Text("Keypts")
                    .font(.caption2)
            }
            .frame(minWidth: 60, minHeight: 44)
            .foregroundStyle(isActive ? Color.accentColor : (isEnabled ? Color.primary : Color.primary))
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .opacity(isEnabled ? 1.0 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(isEnabled ? "Keypoints" : "Keypoints, select an athlete first")
        .accessibilityIdentifier("Annotator.Tool.Keypoints")
        .help(isEnabled ? "" : LockedCopy.keypointsDisabledTooltip)
    }

    private func isAthleteSelected(store: AnnotationStore) -> Bool {
        guard let id = selectedInstanceId,
              let ann = store.coco.annotations.first(where: { $0.id == id }) else {
            return false
        }
        return ann.category_id != ClassCategory.ref.rawValue
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
        // Phase 2: if the selected instance becomes referee, exit keypoints tool.
        .onChange(of: selectedInstanceId) { _, _ in
            if tool == .keypoints && !isAthleteSelected(store: store) {
                tool = .select
            }
        }
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

    // MARK: - Share / Export (top-bar trailing)

    private var shareButton: some View {
        Button {
            // Flush pending write before the share sheet opens so the file is current.
            if let ctx = context {
                _ = flushBridge.flushSynchronously(coordinator: ctx.coordinator)
            }
            isPresentingShareSheet = true
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .disabled(context == nil)
        .accessibilityLabel("Export annotations")
        .accessibilityIdentifier("Annotator.ShareButton")
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

// MARK: - Share sheet helper

/// Presents UIActivityViewController directly from a transparent embedded UIViewController.
///
/// Wrapping UIActivityViewController in a SwiftUI .sheet creates a nested sheet that
/// interferes with the annotator's own bottom sheet on dismissal — UIKit's sheet teardown
/// propagates up and removes the bottom panel. Embedding a transparent UIViewController
/// here and calling vc.present(_:animated:) from within UIKit keeps the two presentation
/// stacks independent. completionWithItemsHandler resets isPresented so the state is clean.
private struct ActivitySharePresenter: UIViewControllerRepresentable {
    let url: URL
    @Binding var isPresented: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {
        guard isPresented else { return }
        // Find the topmost presented VC in the key window so UIActivityViewController
        // has a real, window-attached presenter. The embedded zero-size VC from
        // .background() is too low in the hierarchy on iOS 26 — present() returns
        // silently without showing the sheet.
        guard let presenter = Self.topPresenter() else { return }

        // Swallowed-tap hardening: the annotator's bottom sheet is always presented.
        // If the topmost VC already has a presentedViewController it may be:
        //   (A) UIActivityViewController — already open; this is a re-entrant update,
        //       nothing to do (completionHandler resets isPresented on close).
        //   (B) Some other VC mid-transition (sheet animating in/out) — the naive
        //       guard would make the tap a silent no-op with isPresented stuck true.
        //       Fix: retry on the next runloop so the transition settles first.
        if let existing = presenter.presentedViewController {
            if existing is UIActivityViewController {
                // Already showing — ignore duplicate update.
                return
            }
            // Mid-transition: retry after the current run-loop pass completes.
            DispatchQueue.main.async {
                guard isPresented else { return }
                Self.presentActivity(url: url, from: presenter, isPresented: $isPresented)
            }
            return
        }

        Self.presentActivity(url: url, from: presenter, isPresented: $isPresented)
    }

    /// Creates and presents UIActivityViewController from `presenter`. Separated so
    /// both the direct and retry paths share the same popover-anchor logic.
    private static func presentActivity(url: URL, from presenter: UIViewController, isPresented: Binding<Bool>) {
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.completionWithItemsHandler = { _, _, _, _ in
            isPresented.wrappedValue = false
        }
        // iPad: anchor popover to the top-right of the presenter's view.
        if let popover = activity.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.maxX - 44,
                y: presenter.view.safeAreaInsets.top,
                width: 44,
                height: 44
            )
        }
        presenter.present(activity, animated: true)
    }

    /// Walks the presented-VC chain from the key window's rootViewController to
    /// find the topmost visible controller. Skips VCs that are still mid-transition
    /// (isBeingPresented or isBeingDismissed) to avoid presenting into an unstable
    /// hierarchy — the retry path in updateUIViewController handles those cases.
    private static func topPresenter() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let root = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            return nil
        }
        var top: UIViewController = root
        while let next = top.presentedViewController,
              !next.isBeingDismissed {
            top = next
        }
        return top
    }

    final class Coordinator: NSObject {}
}

// MARK: - Adaptive instance list View extension

private extension View {
    /// Attaches the instance list as a bottom sheet (compact) or right rail (regular).
    /// `selectedDetent` is driven by the caller so the sheet can be collapsed when the
    /// keypoint picker (safeAreaInset) is active, preventing the sheet from covering it.
    func adaptiveInstanceList<Header: View>(
        store: AnnotationStore,
        selectedId: Binding<Int?>,
        selectedDetent: Binding<PresentationDetent>,
        @ViewBuilder toolbarHeader: @escaping () -> Header
    ) -> some View {
        self.modifier(AdaptiveInstanceListModifier(store: store, selectedId: selectedId, selectedDetent: selectedDetent, toolbarHeader: toolbarHeader))
    }
}

private struct AdaptiveInstanceListModifier<Header: View>: ViewModifier {
    let store: AnnotationStore
    @Binding var selectedId: Int?
    @Binding var selectedDetent: PresentationDetent
    let toolbarHeader: () -> Header

    @State private var isSheetShowing = true

    func body(content: Content) -> some View {
        Layout.AdaptiveAnchor(
            compact: {
                content
                    .sheet(isPresented: $isSheetShowing) {
                        VStack(spacing: 0) {
                            toolbarHeader()
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
                        }
                        // .height(36): handle-only strip when keypoint picker active; picker gets ~200pt of screen.
                        .presentationDetents([.height(36), .fraction(0.33), .fraction(0.85)], selection: $selectedDetent)
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
