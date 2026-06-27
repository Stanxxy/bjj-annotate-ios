import SwiftUI

// MARK: - FrameNav (pure boundary logic — extracted for unit testability)

/// Pure frame-navigation boundary helpers.
///
/// Extracted from `AnnotatorView` so tests can exercise boundary logic without
/// spinning a SwiftUI view. All functions are pure (no side-effects).
enum FrameNav {
    /// Returns the 1-based index of `url` in `list`, or nil if not found.
    ///
    /// Tries exact URL match first; falls back to `lastPathComponent` match to
    /// handle symlink vs. resolved-path divergence — mirrors the same strategy
    /// used in `AnnotatorLifecycleContext.imageId(for:in:)`.
    static func frameIndex(for url: URL, in list: [URL]) -> Int? {
        if let idx = list.firstIndex(of: url) { return idx + 1 }
        let name = url.lastPathComponent
        if let idx = list.firstIndex(where: { $0.lastPathComponent == name }) { return idx + 1 }
        return nil
    }

    /// `true` when Prev must be disabled: index is 1 (first frame) or the list
    /// is empty / the index is unknown.
    static func isPrevDisabled(frameIndex: Int?, frameCount: Int) -> Bool {
        guard let idx = frameIndex, frameCount > 0 else { return true }
        return idx <= 1
    }

    /// `true` when Next must be disabled: index equals `frameCount` (last frame)
    /// or the list is empty / the index is unknown.
    static func isNextDisabled(frameIndex: Int?, frameCount: Int) -> Bool {
        guard let idx = frameIndex, frameCount > 0 else { return true }
        return idx >= frameCount
    }

    // MARK: - Per-frame state reset (Contract 3)

    /// The post-reset state returned by `applyPerFrameReset`.
    ///
    /// `isViewLocked` is intentionally absent — it persists across frame switches
    /// and must never be included here.
    struct PerFrameResetState {
        var tool: AnnotatorTool
        var selectedInstanceId: Int?
        var activeKeypointIndex: Int
        var sheetDetent: PresentationDetent
    }

    /// Pure per-frame state reset. Returns the post-switch state given the prior state.
    ///
    /// Contract (NON-NEGOTIABLE):
    ///   - `tool`: `.keypoints` → `.select`; all other tools persist.
    ///   - `selectedInstanceId` → `nil`.
    ///   - `activeKeypointIndex` → 1 (reset to first keypoint).
    ///   - `sheetDetent` → `.fraction(0.33)` (un-collapse).
    ///   - `isViewLocked` is NOT in the output — it persists across frame switches.
    static func applyPerFrameReset(
        tool: AnnotatorTool,
        selectedInstanceId: Int?,
        activeKeypointIndex: Int,
        sheetDetent: PresentationDetent
    ) -> PerFrameResetState {
        return PerFrameResetState(
            tool: tool == .keypoints ? .select : tool,
            selectedInstanceId: nil,
            activeKeypointIndex: 1,
            sheetDetent: .fraction(0.33)
        )
    }

    // MARK: - Generation guard (m4 — stale-load rejection testability)

    /// Returns `true` when a `loadContext` completion is still current and should
    /// be applied; `false` when `contextLoadTrigger` has advanced past the stamp
    /// captured at task start (meaning the task is stale and must be discarded).
    ///
    /// Extracted from `loadContext()` so unit tests can drive the guard decision
    /// without a SwiftUI harness. The two post-await guard sites in `loadContext`
    /// both route through this function — deleting it would break the build.
    static func shouldApplyLoad(myTrigger: UUID, current: UUID) -> Bool {
        myTrigger == current
    }

    // MARK: - Switch-frame ordered execution (M2 — ordering testability)

    /// Executes frame-switch steps in the guaranteed ordering:
    ///   1. flush → 2. resetState → 3. tearDownContext → 4. activateNew
    ///
    /// Extracted as a pure sequencer so unit tests can inject spy closures and
    /// verify the call order. Reordering the closures inside `switchFrame` would
    /// be detectable because the test drives the SAME function with spies.
    static func executeSwitchFrameOrdered(
        flush: () -> Void,
        resetState: () -> Void,
        tearDownContext: () -> Void,
        activateNew: () -> Void
    ) {
        flush()
        resetState()
        tearDownContext()
        activateNew()
    }
}

// MARK: - AnnotatorView

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
    /// Entry-point URL passed at navigation push. Immutable — only used to seed
    /// `currentImageURL` via the custom init. All body references use `currentImageURL`.
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
    @StateObject private var keypointPickerVM = KeypointPickerViewModel()
    // Collapsed floor raised to .height(88) when the keypoint picker is active so
    // the frame-nav row (above the tool row) stays visible and tappable.
    @State private var sheetDetent: PresentationDetent = .fraction(0.33)
    @State private var isPresentingShareSheet: Bool = false
    /// View-lock flag. When true ALL single-finger drags route to pan; keypoint
    /// taps are suppressed. Layered OVER `tool` — the enum stays closed (3 cases)
    /// and the selected box remains highlighted but immutable.
    @State private var isViewLocked: Bool = false

    // I1: per-project lifecycle context. nil while loading on appear.
    @State private var context: AnnotatorLifecycleContext? = nil
    @State private var isLoadingContext: Bool = false

    // MARK: - Frame navigation state

    /// Mutable current-frame URL. All body references use this — never `imageURL`.
    /// Initialized from `imageURL` via the custom init below.
    @State private var currentImageURL: URL
    /// Stable sorted frame list captured once at first load (when `frameList.isEmpty`
    /// in `loadContext()`). Preserved across frame switches; not cleared in
    /// `switchFrame(to:)` so the nav row stays accurate during the loading state.
    @State private var frameList: [URL] = []
    /// Bumped on every `switchFrame(to:)` call to re-drive `.task(id:) { loadContext() }`.
    /// Acts as a generation counter to discard stale async completions.
    @State private var contextLoadTrigger: UUID = UUID()

    private let flushBridge = LifecycleFlushBridge()

    // MARK: - Init

    /// Custom init required to seed `currentImageURL` (a `@State` with no compile-time
    /// default) from the pushed `imageURL`.
    init(imageURL: URL, folderURL: URL, conflictWatcher: ProjectAnnotationConflictWatcher? = nil) {
        self.imageURL = imageURL
        self.folderURL = folderURL
        self.conflictWatcher = conflictWatcher
        _currentImageURL = State(initialValue: imageURL)
    }

    // MARK: - Computed helpers

    /// 1-based index of `currentImageURL` in the stable `frameList`, or nil while
    /// the list is still being captured.
    private var currentFrameIndex: Int? {
        FrameNav.frameIndex(for: currentImageURL, in: frameList)
    }

    var body: some View {
        Group {
            switch AnnotatorImagePresence.evaluate(imageURL: currentImageURL) {
            case .imagePresent:
                imageBody
            case .missing:
                missingImageBody
            }
        }
        .navigationTitle(currentImageURL.lastPathComponent)
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
        // id: contextLoadTrigger — SwiftUI cancels the old task and re-fires
        // loadContext() each time switchFrame(to:) bumps the trigger UUID.
        .task(id: contextLoadTrigger) {
            await loadContext()
        }
        // I2: lifecycle flush bridge wired inside wiredAnnotatorBody after context loads.
    }

    // MARK: - Context loading

    private func loadContext() async {
        // Generation stamp: if switchFrame(to:) fires while make() is in-flight,
        // the old task is cancelled and this stamp detects any stale completion.
        let myTrigger = contextLoadTrigger
        guard context == nil, !isLoadingContext else { return }
        isLoadingContext = true
        // defer ensures isLoadingContext is reset even on task cancellation.
        defer { isLoadingContext = false }

        // Capture the stable frame list ONCE (when this is the first loadContext call).
        // frameList is NOT cleared in switchFrame(to:), so this branch runs only once
        // per AnnotatorView lifetime regardless of how many frame switches occur.
        if frameList.isEmpty {
            let folder = ProjectFolder(url: folderURL)
            frameList = (try? folder.scanImages()) ?? []
        }

        do {
            let ctx = try await AnnotatorLifecycleContext.make(
                folderURL: folderURL,
                imageURL: currentImageURL
            )
            // Generation guard: discard stale results from a superseded switchFrame call.
            guard FrameNav.shouldApplyLoad(myTrigger: myTrigger, current: contextLoadTrigger) else { return }
            context = ctx
        } catch {
            // Error surfaces via store.lastError on the context; if make() throws
            // it means we can't even instantiate the coordinator (very rare OS error).
            // Nothing useful to show beyond the existing error banner.
            // Generation guard: don't apply error state from a superseded load.
            guard FrameNav.shouldApplyLoad(myTrigger: myTrigger, current: contextLoadTrigger) else { return }
        }
    }

    // MARK: - Frame switch (non-navigating, in-place reload)

    /// Switch the annotator to a different frame without pushing to RootView.path.
    ///
    /// Flush contract (NON-NEGOTIABLE): the OUTGOING context is flushed
    /// synchronously before any state teardown. NullWriteScheduler (decode-error)
    /// stores are safe — `flushSynchronously` is a no-op when there is no pending
    /// write in the coordinator.
    ///
    /// Back-stack contract: this mutates internal `@State` only; `RootView.path`
    /// is never modified. After any number of prev/next taps, one Back returns
    /// to the grid.
    ///
    /// Per-frame state reset (NON-NEGOTIABLE CONTRACT 3):
    ///   - selectedInstanceId → nil
    ///   - keypointPickerVM.activeKeypointIndex → 1 (reset to first keypoint)
    ///   - tool: .keypoints → .select; all other tools persist
    ///   - sheetDetent → .fraction(0.33) (un-collapse)
    ///   - isViewLocked persists intentionally
    private func switchFrame(to newURL: URL) {
        // Steps are sequenced through FrameNav.executeSwitchFrameOrdered so that
        // unit tests can inject spy closures and verify flush precedes teardown.
        FrameNav.executeSwitchFrameOrdered(
            flush: {
                if let ctx = context {
                    let didFlush = flushBridge.flushSynchronously(coordinator: ctx.coordinator)
                    if !didFlush {
                        // m1: flush timed out (5 s) — outgoing annotations may not be
                        // fully written to disk. Context is torn down per contract regardless.
                        print("[AnnotatorView] WARNING: flushSynchronously timed out before frame switch — outgoing annotations may not be fully persisted.")
                    }
                }
            },
            resetState: {
                // Pure reset via FrameNav.applyPerFrameReset (see Contract 3).
                let reset = FrameNav.applyPerFrameReset(
                    tool: tool,
                    selectedInstanceId: selectedInstanceId,
                    activeKeypointIndex: keypointPickerVM.activeKeypointIndex,
                    sheetDetent: sheetDetent
                )
                tool = reset.tool
                selectedInstanceId = reset.selectedInstanceId
                keypointPickerVM.activeKeypointIndex = reset.activeKeypointIndex
                sheetDetent = reset.sheetDetent
                // isViewLocked intentionally preserved across frames (NOT in reset output).
            },
            tearDownContext: {
                // isLoadingContext MUST be reset so the guard in loadContext() passes
                // when the new task starts. The old task's defer also resets it but may
                // race; an explicit reset here eliminates the race on the @MainActor.
                isLoadingContext = false
                context = nil
            },
            activateNew: {
                // Bump trigger to re-fire .task(id:) → loadContext().
                currentImageURL = newURL
                contextLoadTrigger = UUID()
            }
        )
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
            // ErrorBanner (I2: wired from store.lastError).
            // Both are @ObservedObject child views so they re-render reactively on
            // every @Published change — both appear-on-error and disappear-on-dismiss.
            conflictBannerIfNeeded(store: store)

            annotatorLayout(store: store, coordinator: coordinator)
        }
        // I2: lifecycle flush bridge wired to the coordinator.
        .flushOnWillResignActive(coordinator: coordinator, bridge: flushBridge)
        // I3: mirror conflict event to the project-level watcher.
        .onChange(of: store.lastConflict) { newConflict in
            if let event = newConflict {
                conflictWatcher?.receive(conflictEvent: event)
            }
        }
        // Surface store.lastError via ErrorBanner — an @ObservedObject child view
        // that re-renders on every lastError change (appear AND dismiss).
        .overlay(alignment: .top) {
            ErrorBanner(store: store)
        }
        // Hardware keyboard: left/right arrow → prev/next frame.
        // KeyArrowInterceptor uses UIKeyCommand (iOS 16-compatible).
        // Disabled boundaries are honored inside each closure.
        .background(
            KeyArrowInterceptor(
                onPrev: {
                    let idx = currentFrameIndex
                    guard !FrameNav.isPrevDisabled(frameIndex: idx, frameCount: frameList.count),
                          let i = idx else { return }
                    switchFrame(to: frameList[i - 2])
                },
                onNext: {
                    let idx = currentFrameIndex
                    guard !FrameNav.isNextDisabled(frameIndex: idx, frameCount: frameList.count),
                          let i = idx else { return }
                    switchFrame(to: frameList[i])
                }
            )
            .frame(width: 0, height: 0)
        )
    }

    @ViewBuilder
    private func conflictBannerIfNeeded(store: AnnotationStore) -> some View {
        ConflictBanner(store: store)
    }

    @ViewBuilder
    private func annotatorLayout(store: AnnotationStore, coordinator: CocoFileCoordinator) -> some View {
        Layout.AdaptiveAnchor(
            compact: {
                // iPhone portrait / Slide-Over: canvas + bottom sheet with tools+chips in header.
                compactAnnotatorLayout(store: store)
            },
            regular: {
                // iPad landscape (and portrait regular): left rail | canvas+keystrip | right rail.
                regularAnnotatorLayout(store: store)
            }
        )
        .accessibilityIdentifier("Annotator.WiredLayout")
    }

    // MARK: - Frame nav rows

    /// Compact (iPhone) frame-navigation row: full-width `[‹]  k / N  [›]`.
    ///
    /// Placed as the TOP row of the bottom-sheet header, above `toolSelectorRow`.
    /// Chevrons are ≥44×44pt per spec; disabled (greyed, non-tappable) at boundaries.
    @ViewBuilder
    private func frameNavRowCompact() -> some View {
        let idx = currentFrameIndex
        let n = frameList.count
        let prevDisabled = FrameNav.isPrevDisabled(frameIndex: idx, frameCount: n)
        let nextDisabled = FrameNav.isNextDisabled(frameIndex: idx, frameCount: n)
        // B1: When n > 0 but idx == nil (iCloud placeholder, frame absent from list),
        // render the unmapped state loudly — never a plausible-but-wrong number.
        let counterText: String = {
            guard n > 0 else { return "– / –" }
            guard let i = idx else { return "– / \(n)" }
            return "\(i) / \(n)"
        }()

        HStack(spacing: 0) {
            Button {
                if let i = idx, !prevDisabled {
                    switchFrame(to: frameList[i - 2])  // 0-based: prev is at index (i-1)-1 = i-2
                }
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 18, weight: .medium))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(prevDisabled)
            .foregroundStyle(prevDisabled ? Color.secondary : Color.primary)
            .accessibilityLabel(prevDisabled ? "Previous frame, unavailable" : "Previous frame")
            .accessibilityHint(prevDisabled ? "You are at the first frame." : "")
            .accessibilityIdentifier("FrameNav.Prev")

            Spacer()

            Text(counterText)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Color.primary)
                .accessibilityLabel({
                    guard n > 0 else { return "No frames" }
                    guard let i = idx else { return "Frame position unavailable, \(n) frames" }
                    return "Frame \(i) of \(n)"
                }())
                .accessibilityIdentifier("FrameNav.Counter")

            Spacer()

            Button {
                if let i = idx, !nextDisabled {
                    switchFrame(to: frameList[i])  // 0-based: next is at index (i+1)-1 = i
                }
            } label: {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 18, weight: .medium))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(nextDisabled)
            .foregroundStyle(nextDisabled ? Color.secondary : Color.primary)
            .accessibilityLabel(nextDisabled ? "Next frame, unavailable" : "Next frame")
            .accessibilityHint(nextDisabled ? "You are at the last frame." : "")
            .accessibilityIdentifier("FrameNav.Next")
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 44)
        .accessibilityIdentifier("FrameNav.Row")
    }

    /// Regular (iPad landscape) frame-navigation cluster: vertical `‹ / k / N / ›`
    /// at the top of the 72pt left rail, above Select/Box/Keypoints.
    ///
    /// Counter wraps to two lines to fit the narrow rail (k over / N).
    /// Each control is ≥44×44pt. Disabled at boundaries (greyed, non-tappable).
    @ViewBuilder
    private func frameNavClusterRegular() -> some View {
        let idx = currentFrameIndex
        let n = frameList.count
        let prevDisabled = FrameNav.isPrevDisabled(frameIndex: idx, frameCount: n)
        let nextDisabled = FrameNav.isNextDisabled(frameIndex: idx, frameCount: n)

        VStack(spacing: 4) {
            Button {
                if let i = idx, !prevDisabled {
                    switchFrame(to: frameList[i - 2])
                }
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 18, weight: .medium))
                    .frame(minWidth: 44, minHeight: 44)
                    // P0: explicit contentShape so the full 44×44 frame is tappable
                    // (without this the hit-target shrinks to ~18pt glyph bounds on iPad).
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(prevDisabled)
            .foregroundStyle(prevDisabled ? Color.secondary : Color.primary)
            .accessibilityLabel(prevDisabled ? "Previous frame, unavailable" : "Previous frame")
            .accessibilityHint(prevDisabled ? "You are at the first frame." : "")
            .accessibilityIdentifier("FrameNav.Prev")

            VStack(spacing: 0) {
                // B1: When n > 0 but idx == nil (iCloud placeholder), show "–" not "1".
                Text({
                    guard n > 0 else { return "–" }
                    guard let i = idx else { return "–" }
                    return "\(i)"
                }())
                Text(n > 0 ? "/ \(n)" : "/ –")
            }
            // P1b: .caption2 (11 pt) fails WCAG AA contrast in the narrow rail.
            // Bumped to .caption (12 pt) — still fits two lines at 4-digit counts
            // within the 64 pt-usable rail width.
            .font(.caption.monospacedDigit())
            .multilineTextAlignment(.center)
            .foregroundStyle(Color.secondary)
            .frame(maxWidth: .infinity)
            .accessibilityLabel({
                guard n > 0 else { return "No frames" }
                guard let i = idx else { return "Frame position unavailable, \(n) frames" }
                return "Frame \(i) of \(n)"
            }())
            .accessibilityIdentifier("FrameNav.Counter")

            Button {
                if let i = idx, !nextDisabled {
                    switchFrame(to: frameList[i])
                }
            } label: {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 18, weight: .medium))
                    .frame(minWidth: 44, minHeight: 44)
                    // P0: explicit contentShape so the full 44×44 frame is tappable.
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(nextDisabled)
            .foregroundStyle(nextDisabled ? Color.secondary : Color.primary)
            .accessibilityLabel(nextDisabled ? "Next frame, unavailable" : "Next frame")
            .accessibilityHint(nextDisabled ? "You are at the last frame." : "")
            .accessibilityIdentifier("FrameNav.Next")
        }
        .accessibilityIdentifier("FrameNav.Cluster")
    }

    // MARK: - Compact layout (iPhone / Slide-Over)

    @ViewBuilder
    private func compactAnnotatorLayout(store: AnnotationStore) -> some View {
        canvasRegion(store: store, showKeypointStrip: false)
            .adaptiveInstanceList(
                store: store,
                selectedId: $selectedInstanceId,
                selectedDetent: $sheetDetent,
                toolbarHeader: {
                    VStack(spacing: 0) {
                        // Frame-nav row is the TOP row — visible even at minimum detent (.height(88)).
                        frameNavRowCompact()
                        Divider()
                        toolSelectorRow(store: store)
                        classAndAthleteRow(store: store)
                    }
                    .background(.regularMaterial)
                }
            )
            // Collapse the sheet when the keypoint picker is active.
            // Floor raised from .height(36) to .height(88) so the frame-nav row
            // (the top row of the header) stays visible and tappable when collapsed.
            //
            // P2 / iOS 16.0–16.3 gap:
            // `presentationBackgroundInteractionIfAvailable()` (ViewExtensions.swift) skips
            // `.presentationBackgroundInteraction(.enabled)` on iOS < 16.4, so the 88 pt
            // collapsed sheet is OPAQUE-BLOCKING on iOS 16.0–16.3: taps on foot-level
            // keypoints below the 88 pt floor cannot reach the canvas through the sheet.
            // Users on 16.0–16.3 must manually drag the sheet further down.
            // iOS 16.4 is the effective floor for full keypoint passthrough.
            .onChange(of: tool == .keypoints && isAthleteSelected(store: store)) { isActive in
                withAnimation {
                    sheetDetent = isActive ? .height(88) : .fraction(0.33)
                }
            }
    }

    // MARK: - Regular layout (iPad landscape / regular size class)
    //
    // Structure:
    //   HStack [LEFT RAIL (64-80pt) | CANVAS + keystrip | RIGHT RAIL (~320pt)]
    //
    // R-UI-1: size class comes from Layout.AdaptiveAnchor; no UIDevice idiom check.

    @ViewBuilder
    private func regularAnnotatorLayout(store: AnnotationStore) -> some View {
        HStack(spacing: 0) {
            // LEFT RAIL: tool buttons + view-lock toggle, icon-only with VoiceOver labels.
            leftRail(store: store)
                .frame(width: 72)
                .background(Color(.secondarySystemBackground))

            Divider()

            // CANVAS region (hero): fills remaining width after rails; 16:9 image letterboxed.
            // Keypoint strip anchored below the canvas when active.
            VStack(spacing: 0) {
                canvasRegion(store: store, showKeypointStrip: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // KEYPOINT STRIP (regular only): 100-130pt horizontal-scroll strip of all 17 buttons.
                // Anchored BELOW the canvas so it never overlaps the 16:9 image.
                if tool == .keypoints && isAthleteSelected(store: store) {
                    Divider()
                    keypointStripRegular(store: store)
                        .frame(height: 120)
                        .background(Color(.secondarySystemBackground))
                        .accessibilityIdentifier("Annotator.KeypointStrip")
                }
            }

            Divider()

            // RIGHT RAIL: class chips + athlete picker + instance list + mirror button.
            rightRail(store: store)
                .frame(width: 320)
                .background(Color(.secondarySystemBackground))
        }
    }

    // MARK: - Left rail (regular)

    @ViewBuilder
    private func leftRail(store: AnnotationStore) -> some View {
        VStack(spacing: 8) {
            // Frame nav cluster at the very top of the rail — above all tools.
            frameNavClusterRegular()

            Divider()

            // Tool buttons — icon only, ≥44×44pt each.
            leftRailToolButton(.select, systemImage: "cursorarrow", label: "Select")
            leftRailToolButton(.box, systemImage: "square.dashed", label: "Box")
            leftRailKeypointsButton(store: store)

            Spacer()

            // View-lock toggle — warm amber fill when locked (not accent blue per spec).
            Button {
                isViewLocked.toggle()
            } label: {
                Image(systemName: isViewLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 20))
                    .frame(minWidth: 44, minHeight: 44)
                    .foregroundStyle(isViewLocked ? Color(red: 0.95, green: 0.65, blue: 0.0) : Color.secondary)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isViewLocked
                                ? Color(red: 0.95, green: 0.65, blue: 0.0).opacity(0.15)
                                : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isViewLocked ? "Pan locked — tap to unlock" : "Pan unlocked — tap to lock")
            .accessibilityIdentifier("Annotator.ViewLockButton")
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
    }

    private func leftRailToolButton(_ t: AnnotatorTool, systemImage: String, label: String) -> some View {
        let isSelected = tool == t
        return Button {
            tool = t
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .frame(minWidth: 44, minHeight: 44)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier("Annotator.Tool.\(label)")
    }

    @ViewBuilder
    private func leftRailKeypointsButton(store: AnnotationStore) -> some View {
        let isActive = tool == .keypoints
        let isEnabled = isAthleteSelected(store: store)
        Button {
            tool = .keypoints
        } label: {
            Image(systemName: "figure.arms.open")
                .font(.system(size: 20))
                .frame(minWidth: 44, minHeight: 44)
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
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
    }

    // MARK: - Right rail (regular)

    @ViewBuilder
    private func rightRail(store: AnnotationStore) -> some View {
        VStack(spacing: 0) {
            // Class chip row at top, ≥44pt tall.
            ClassChipRow(selectedInstanceId: selectedInstanceId, store: store)
                .padding(.vertical, 4)
                .frame(minHeight: 44)
                .onChange(of: selectedInstanceId) { _ in
                    if tool == .keypoints && !isAthleteSelected(store: store) {
                        tool = .select
                    }
                }

            Divider()

            // Athlete picker trigger ≥44pt.
            if !isRefSelected(store: store) {
                athletePickerTrigger(store: store)
                    .padding(.horizontal, 12)
            }

            Divider()

            // Instance list scrollable rows ≥44pt each.
            InstanceList(
                store: store,
                selectedInstanceId: selectedInstanceId,
                onSelect: { id in selectedInstanceId = id },
                onDelete: { id in
                    store.deleteInstance(instanceId: id)
                    if selectedInstanceId == id { selectedInstanceId = nil }
                }
            )
            .frame(maxHeight: .infinity)

            Divider()

            // Mirror L-R button fixed at bottom.
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
            .padding(12)
            .accessibilityIdentifier("KeypointPicker.MirrorButton")
        }
        .accessibilityIdentifier("Annotator.RightRail")
    }

    // MARK: - Keypoint strip (regular-only, horizontal scroll)
    //
    // 100-130pt tall strip of all 17 keypoints in groups: Head | Arms | Legs.
    // Auto-scrolls active keypoint into view. Mirror button fixed outside scroll.

    @ViewBuilder
    private func keypointStripRegular(store: AnnotationStore) -> some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        keypointStripGroup(title: "Head",
                                           defs: KeypointDefinition.headGroup,
                                           proxy: proxy,
                                           store: store)
                        Divider().frame(height: 80)
                        keypointStripGroup(title: "Arms",
                                           defs: KeypointDefinition.armsGroup,
                                           proxy: proxy,
                                           store: store)
                        Divider().frame(height: 80)
                        keypointStripGroup(title: "Legs",
                                           defs: KeypointDefinition.legsGroup,
                                           proxy: proxy,
                                           store: store)
                    }
                    .padding(.horizontal, 8)
                }
                .onChange(of: keypointPickerVM.activeKeypointIndex) { newIndex in
                    withAnimation { proxy.scrollTo("kp_\(newIndex)", anchor: .center) }
                }
                .onAppear {
                    proxy.scrollTo("kp_\(keypointPickerVM.activeKeypointIndex)", anchor: .center)
                }
            }

            Divider()

            // Mirror button fixed outside the scroll area.
            Button {
                if let id = selectedInstanceId {
                    store.mirrorKeypoints(instanceId: id)
                }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 18))
                    Text("Mirror")
                        .font(.caption2)
                }
                .frame(minWidth: 60, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(selectedInstanceId == nil)
            .padding(.horizontal, 8)
            .accessibilityIdentifier("Annotator.Strip.MirrorButton")
        }
    }

    @ViewBuilder
    private func keypointStripGroup(
        title: String,
        defs: [KeypointDefinition],
        proxy: ScrollViewProxy,
        store: AnnotationStore
    ) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            HStack(spacing: 4) {
                ForEach(defs, id: \.index) { kpDef in
                    keypointStripButton(kpDef: kpDef, store: store)
                        .id("kp_\(kpDef.index)")
                }
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func keypointStripButton(kpDef: KeypointDefinition, store: AnnotationStore) -> some View {
        let isActive = keypointPickerVM.activeKeypointIndex == kpDef.index
        let placed = isKeypointPlaced(kpDef.index, in: store)
        let kpColor = KeypointPalette.color(for: kpDef.side)

        Button {
            keypointPickerVM.activeKeypointIndex = kpDef.index
        } label: {
            VStack(spacing: 2) {
                Circle()
                    .fill(kpColor)
                    .frame(width: 10, height: 10)
                    .overlay(
                        placed ? Image(systemName: "checkmark").font(.system(size: 6)).foregroundStyle(.white) : nil
                    )
                Text(kpDef.abbreviation)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(minWidth: 44, minHeight: 60)
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
        .accessibilityLabel("\(kpDef.name)\(placed ? ", placed" : "")\(isActive ? ", active" : "")")
        .accessibilityIdentifier("Annotator.Strip.\(kpDef.index)")
    }

    private func isKeypointPlaced(_ index: Int, in store: AnnotationStore) -> Bool {
        guard let id = selectedInstanceId,
              let ann = store.annotationsForCurrentImage.first(where: { $0.id == id }),
              let kps = ann.keypoints, kps.count == 51 else { return false }
        return keypointPickerVM.isPlaced(index: index, in: kps)
    }

    /// `showKeypointStrip`: compact=true (vertical picker inset), regular=false (strip is external).
    private func canvasRegion(store: AnnotationStore, showKeypointStrip: Bool) -> some View {
        AnnotatorCanvasView(
            imageURL: currentImageURL,
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
        // Phase 2 (BUG2 fix / compact): vertical keypoint picker anchored below canvas
        // as a safeAreaInset. Regular branch uses the external keypoint strip instead.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showKeypointStrip && tool == .keypoints && isAthleteSelected(store: store) {
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
        .onChange(of: selectedInstanceId) { _ in
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
                store: store,
                selectedInstanceId: selectedInstanceId,
                onDismiss: {
                isPickerShowing = false
                }
            )
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

// MARK: - Hardware keyboard arrow-key interceptor

/// Transparent UIViewController that installs UIKeyCommand handlers for
/// left/right arrow keys (iOS 16-compatible — `onKeyPress` is iOS 17+).
///
/// Embedded as a zero-size `.background()` on `wiredAnnotatorBody` so it
/// is in the UIKit VC hierarchy and can become first responder. `becomeFirstResponder()`
/// is called in `viewDidAppear` so the VC enters the responder chain as soon as
/// the annotator is fully on screen.
///
/// Closures are stored directly on the VC and refreshed on every `updateUIViewController`
/// call so stale SwiftUI captures are never used.
///
/// M3 — SCOPE CLAIM (regular layout only):
/// Hardware-keyboard arrow navigation works reliably in REGULAR layout (iPad +
/// Magic Keyboard), where no bottom sheet is presented and `KeyArrowHostVC` can
/// hold first-responder status uncontested. In COMPACT layout the always-on bottom
/// sheet presents a UIKit VC that wins the responder chain; `becomeFirstResponder()`
/// on this zero-size background VC may be overridden. Compact + hardware keyboard
/// is an on-device gate — it is NOT claimed as a working configuration.
private struct KeyArrowInterceptor: UIViewControllerRepresentable {
    var onPrev: () -> Void
    var onNext: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> KeyArrowHostVC {
        let vc = KeyArrowHostVC()
        vc.onPrev = onPrev
        vc.onNext = onNext
        return vc
    }

    func updateUIViewController(_ vc: KeyArrowHostVC, context: Context) {
        // Refresh closures on every SwiftUI render so the VC always calls the
        // most up-to-date `switchFrame` / boundary logic from the view's body.
        vc.onPrev = onPrev
        vc.onNext = onNext
    }

    final class Coordinator: NSObject {}
}

/// `internal` (not `private`) so `@testable import BJJAnnotate` can access it
/// from unit tests to verify `keyCommands` wiring and `onPrev`/`onNext` closures.
final class KeyArrowHostVC: UIViewController {
    var onPrev: (() -> Void)?
    var onNext: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(
                input: UIKeyCommand.inputLeftArrow,
                modifierFlags: [],
                action: #selector(handlePrev)
            ),
            UIKeyCommand(
                input: UIKeyCommand.inputRightArrow,
                modifierFlags: [],
                action: #selector(handleNext)
            ),
        ]
    }

    @objc private func handlePrev() { onPrev?() }
    @objc private func handleNext() { onNext?() }
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
                                store: store,
                                selectedInstanceId: selectedId,
                                onSelect: { id in selectedId = id },
                                onDelete: { id in
                                    store.deleteInstance(instanceId: id)
                                    if selectedId == id { selectedId = nil }
                                }
                            )
                        }
                        // .height(88): minimum floor — keeps frame-nav row (44pt) + handle visible
                        // when keypoint picker is active; picker still gets ~200pt of screen.
                        .presentationDetents([.height(88), .fraction(0.33), .fraction(0.85)], selection: $selectedDetent)
                        .presentationBackgroundInteractionIfAvailable()
                        .interactiveDismissDisabled()
                    }
            },
            regular: {
                HStack(spacing: 0) {
                    content
                    Divider()
                    InstanceList(
                        store: store,
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
