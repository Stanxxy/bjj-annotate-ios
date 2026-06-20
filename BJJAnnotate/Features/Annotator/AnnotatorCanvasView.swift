import SwiftUI

/// Annotator canvas: image + pinch / pan / double-tap-to-fit + box-tool drag.
///
/// T14 landed pinch / pan / double-tap-to-fit (AC #22).
/// T15 adds the box-tool drag pipeline (AC #15–#17, #19–#20, #25).
///
/// Gesture dispatch:
///   - In `.box` tool mode, a single-finger DragGesture writes to view-local
///     `dragStage` on every onChanged event and commits on onEnded via
///     `BoxIntake.intake(...)` + `store.upsertBox(...)`. The store is NEVER
///     touched during drag progress (R-UI-2 contract).
///   - MagnificationGesture (pinch) always pans/zooms — runs simultaneously
///     with the single-finger drag because users expect pinch-to-zoom to work
///     regardless of tool.
///   - Double-tap always resets to fit (1.0× / zero offset).
///
/// T16 will fold a `.select` tool that hit-tests boxes and renders 8 resize
/// handles; the gesture wiring stays here.
struct AnnotatorCanvasView: View {
    let imageURL: URL
    /// Optional store. When nil (T14 standalone preview), the canvas degrades
    /// to view-only: pinch / pan / double-tap still work, but a `.box` drag
    /// stages a preview rect and commits nothing on end.
    var store: AnnotationStore? = nil
    /// Currently-active tool. Owned by the parent `AnnotatorView` so the
    /// toolbar / chips remain a single source of truth.
    var tool: AnnotatorTool = .box
    /// Locked toast surface — populated when a sub-4px drag is rejected so the
    /// parent view can render `LockedCopy.boxTooSmallToast`.
    @Binding var rejectionToastVisible: Bool

    @State private var transform: CanvasTransform = CanvasTransform()
    @State private var dragStage: BoxDragStage? = nil
    /// Currently-selected annotation id (T16). Bound to `AnnotatorView.selectedInstanceId`
    /// so that canvas draws/selects propagate up to the class-chip row and instance list.
    @Binding var selectedInstanceId: Int?
    /// Active resize/move during a `.select`-mode drag. View-local; commits to
    /// store on `.onEnded` only (same R-UI-2 contract as `.box` mode).
    @State private var selectStage: SelectStage? = nil

    private enum SelectStage: Equatable {
        case resize(instanceId: Int, handle: BoxHandle, originalRect: BBox, liveRect: BBox)
        case move(instanceId: Int, originalRect: BBox, liveRect: BBox)
    }

    init(
        imageURL: URL,
        store: AnnotationStore? = nil,
        tool: AnnotatorTool = .box,
        rejectionToastVisible: Binding<Bool> = .constant(false),
        selectedInstanceId: Binding<Int?> = .constant(nil)
    ) {
        self.imageURL = imageURL
        self.store = store
        self.tool = tool
        self._rejectionToastVisible = rejectionToastVisible
        self._selectedInstanceId = selectedInstanceId
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let uiImage = UIImage(contentsOfFile: imageURL.path) {
                    canvasContent(uiImage: uiImage, viewSize: geo.size)
                } else {
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .contentShape(Rectangle())
            .accessibilityIdentifier("Annotator.Canvas")
        }
    }

    @ViewBuilder
    private func canvasContent(uiImage: UIImage, viewSize: CGSize) -> some View {
        let imageSize = CGSize(width: uiImage.size.width, height: uiImage.size.height)
        ZStack {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .scaleEffect(transform.zoom)
                .offset(x: transform.offset.width, y: transform.offset.height)
                .accessibilityLabel(imageURL.lastPathComponent)
                .accessibilityIdentifier("Annotator.Image")

            // Existing annotations overlay (T16 — render all boxes, highlight selection).
            if let store = store {
                ForEach(store.annotationsForCurrentImage, id: \.id) { ann in
                    annotationOverlay(annotation: ann, viewSize: viewSize, imageSize: imageSize)
                }
                // Handles for the selected box.
                if let id = selectedInstanceId,
                   let ann = store.coco.annotations.first(where: { $0.id == id }) {
                    handlesOverlay(rect: liveRect(for: ann), viewSize: viewSize, imageSize: imageSize)
                }
            }

            // Drag-stage preview rectangle — view-local, never in the store.
            if let stage = dragStage {
                dragPreview(stage: stage, viewSize: viewSize, imageSize: imageSize)
            }
        }
        .gesture(
            pinchGesture()
                .simultaneously(with: combinedDragGesture(viewSize: viewSize, imageSize: imageSize))
        )
        .onTapGesture(count: 2) {
            withAnimation(.easeInOut(duration: 0.2)) {
                transform.doubleTapToFit()
            }
        }
    }

    /// Returns the live rect for an annotation — if the user is mid-drag on a
    /// `.select` resize/move, returns the staged rect; otherwise the committed
    /// rect from the store.
    private func liveRect(for ann: CocoAnnotation) -> BBox {
        if case .resize(let id, _, _, let live) = selectStage, id == ann.id {
            return live
        }
        if case .move(let id, _, let live) = selectStage, id == ann.id {
            return live
        }
        return BBox(x: ann.bbox[0], y: ann.bbox[1], w: ann.bbox[2], h: ann.bbox[3])
    }

    /// Renders one annotation rectangle, color-coded by athlete-id or referee.
    private func annotationOverlay(annotation ann: CocoAnnotation, viewSize: CGSize, imageSize: CGSize) -> some View {
        let rect = liveRect(for: ann)
        let viewRect = imageRectToView(rect: rect, viewSize: viewSize, imageSize: imageSize)
        let isSelected = (selectedInstanceId == ann.id)
        return Rectangle()
            .strokeBorder(lineWidth: isSelected ? 3 : 2)
            .foregroundStyle(strokeColor(for: ann))
            .frame(width: viewRect.width, height: viewRect.height)
            .position(x: viewRect.midX, y: viewRect.midY)
            .accessibilityIdentifier("Annotator.Box.\(ann.id)")
            .allowsHitTesting(false)
    }

    private func strokeColor(for ann: CocoAnnotation) -> Color {
        // Referee (category 3) renders system gray (Designer §2.4).
        if ann.category_id == ClassCategory.ref.rawValue { return .secondary }
        guard let aid = ann.attributes.athlete_id,
              let hex = AthletePalette.hex(forAthleteId: aid) else {
            return .white
        }
        return Color(hex: hex) ?? .white
    }

    /// Renders 8 handle dots for the selected rect. Touch targets are
    /// 44pt squares per Designer §5; we render small visible dots and rely on
    /// the gesture hit-test's image-pixel radius for the 44pt-equivalent target.
    private func handlesOverlay(rect: BBox, viewSize: CGSize, imageSize: CGSize) -> some View {
        let viewRect = imageRectToView(rect: rect, viewSize: viewSize, imageSize: imageSize)
        let points: [(BoxHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: viewRect.minX, y: viewRect.minY)),
            (.topMid, CGPoint(x: viewRect.midX, y: viewRect.minY)),
            (.topRight, CGPoint(x: viewRect.maxX, y: viewRect.minY)),
            (.leftMid, CGPoint(x: viewRect.minX, y: viewRect.midY)),
            (.rightMid, CGPoint(x: viewRect.maxX, y: viewRect.midY)),
            (.bottomLeft, CGPoint(x: viewRect.minX, y: viewRect.maxY)),
            (.bottomMid, CGPoint(x: viewRect.midX, y: viewRect.maxY)),
            (.bottomRight, CGPoint(x: viewRect.maxX, y: viewRect.maxY)),
        ]
        return ZStack {
            ForEach(0..<points.count, id: \.self) { i in
                let (handle, p) = points[i]
                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .position(x: p.x, y: p.y)
                    .accessibilityIdentifier("Annotator.Handle.\(handle)")
                    .allowsHitTesting(false)
            }
        }
    }

    /// Converts an image-pixel rect to its view-coordinate rect under the
    /// current `transform`.
    private func imageRectToView(rect: BBox, viewSize: CGSize, imageSize: CGSize) -> CGRect {
        let baseScale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let renderedScale = baseScale * transform.zoom
        let renderedW = imageSize.width * renderedScale
        let renderedH = imageSize.height * renderedScale
        let originX = (viewSize.width - renderedW) / 2 + transform.offset.width
        let originY = (viewSize.height - renderedH) / 2 + transform.offset.height
        return CGRect(
            x: originX + rect.x * renderedScale,
            y: originY + rect.y * renderedScale,
            width: rect.w * renderedScale,
            height: rect.h * renderedScale
        )
    }

    // MARK: - Drag preview

    /// Renders the staged box as a dashed rectangle in view-coordinate space.
    /// Coordinates round-trip image-pixels → view-points via the inverse of
    /// `CanvasTransform.viewToImage(...)`.
    private func dragPreview(stage: BoxDragStage, viewSize: CGSize, imageSize: CGSize) -> some View {
        let baseScale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let renderedScale = baseScale * transform.zoom
        let renderedW = imageSize.width * renderedScale
        let renderedH = imageSize.height * renderedScale
        let originX = (viewSize.width - renderedW) / 2 + transform.offset.width
        let originY = (viewSize.height - renderedH) / 2 + transform.offset.height
        let rect = stage.previewRect
        let viewRect = CGRect(
            x: originX + rect.minX * renderedScale,
            y: originY + rect.minY * renderedScale,
            width: rect.width * renderedScale,
            height: rect.height * renderedScale
        )
        return Rectangle()
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .foregroundStyle(.white)
            .frame(width: viewRect.width, height: viewRect.height)
            .position(x: viewRect.midX, y: viewRect.midY)
            .accessibilityIdentifier("Annotator.DragPreview")
            .allowsHitTesting(false)
    }

    // MARK: - Gestures

    private func pinchGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                transform.apply(pinch: value)
            }
            .onEnded { _ in
                transform.commitZoom()
            }
    }

    /// Single-finger drag dispatches per active tool. View-local staging
    /// honors R-UI-2; the store is touched only on `.onEnded`.
    private func combinedDragGesture(viewSize: CGSize, imageSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                switch tool {
                case .box:
                    onBoxDragChanged(value: value, viewSize: viewSize, imageSize: imageSize)
                case .select:
                    onSelectDragChanged(value: value, viewSize: viewSize, imageSize: imageSize)
                case .keypoints:
                    transform.apply(panTranslation: value.translation, viewSize: viewSize, imageSize: imageSize)
                }
            }
            .onEnded { value in
                switch tool {
                case .box:
                    onBoxDragEnded(value: value, viewSize: viewSize, imageSize: imageSize)
                case .select:
                    onSelectDragEnded(viewSize: viewSize, imageSize: imageSize)
                case .keypoints:
                    transform.commitPan()
                }
            }
    }

    // MARK: - .box gesture path

    private func onBoxDragChanged(value: DragGesture.Value, viewSize: CGSize, imageSize: CGSize) {
        let startImg = transform.viewToImage(viewPoint: value.startLocation, viewSize: viewSize, imageSize: imageSize)
        let curImg = transform.viewToImage(viewPoint: value.location, viewSize: viewSize, imageSize: imageSize)
        if dragStage == nil {
            dragStage = BoxDragStage(startImagePoint: startImg, currentImagePoint: curImg)
        } else {
            dragStage?.currentImagePoint = curImg
        }
    }

    private func onBoxDragEnded(value: DragGesture.Value, viewSize: CGSize, imageSize: CGSize) {
        let stage = dragStage
        dragStage = nil
        guard let stage = stage else { return }
        let result = BoxIntake.intake(
            start: stage.startImagePoint,
            end: stage.currentImagePoint,
            imageSize: imageSize
        )
        switch result {
        case .commit(let bbox):
            rejectionToastVisible = false
            if let store = store {
                let id = store.upsertBox(BBoxIntent(rect: bbox))
                selectedInstanceId = id
            }
        case .rejectTooSmall:
            rejectionToastVisible = true
        }
    }

    // MARK: - .select gesture path

    /// Hit-test radius in image pixels — scales inverse to the current zoom so
    /// the on-screen target stays at the Designer §5 44pt minimum.
    private func handleHitRadius(viewSize: CGSize, imageSize: CGSize) -> CGFloat {
        let baseScale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let renderedScale = baseScale * transform.zoom
        guard renderedScale > 0 else { return 22 }
        return 22 / renderedScale  // 22 image pixels at base scale = ~44pt target
    }

    private func onSelectDragChanged(value: DragGesture.Value, viewSize: CGSize, imageSize: CGSize) {
        // First event of a drag: figure out what the user is interacting with.
        if selectStage == nil {
            guard let store = store else {
                transform.apply(panTranslation: value.translation, viewSize: viewSize, imageSize: imageSize)
                return
            }
            let startImg = transform.viewToImage(viewPoint: value.startLocation, viewSize: viewSize, imageSize: imageSize)
            let radius = handleHitRadius(viewSize: viewSize, imageSize: imageSize)

            // 1) If a box is already selected, prefer handle-hit on it.
            if let id = selectedInstanceId,
               let ann = store.coco.annotations.first(where: { $0.id == id }) {
                let rect = liveRect(for: ann)
                if let handle = BoxResize.hitTest(touchPoint: startImg, rect: rect, radius: radius) {
                    selectStage = .resize(instanceId: id, handle: handle, originalRect: rect, liveRect: rect)
                    return
                }
                let body = CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h)
                if body.contains(startImg) {
                    selectStage = .move(instanceId: id, originalRect: rect, liveRect: rect)
                    return
                }
            }
            // 2) Otherwise hit-test every box body to select a new one.
            for ann in store.annotationsForCurrentImage {
                let r = liveRect(for: ann)
                let body = CGRect(x: r.x, y: r.y, width: r.w, height: r.h)
                if body.contains(startImg) {
                    selectedInstanceId = ann.id
                    selectStage = .move(instanceId: ann.id, originalRect: r, liveRect: r)
                    return
                }
            }
            // 3) Empty space: deselect + pan (the canvas always pans on empty).
            selectedInstanceId = nil
            transform.apply(panTranslation: value.translation, viewSize: viewSize, imageSize: imageSize)
            return
        }

        // Continuation of an in-flight resize/move.
        let translationImg = imageTranslation(
            viewTranslation: value.translation,
            viewSize: viewSize,
            imageSize: imageSize
        )
        switch selectStage {
        case .resize(let id, let handle, let original, _):
            let newRect = BoxResize.apply(
                handle: handle,
                rect: original,
                translation: translationImg,
                imageSize: imageSize
            )
            selectStage = .resize(instanceId: id, handle: handle, originalRect: original, liveRect: newRect)
        case .move(let id, let original, _):
            let newRect = BoxResize.move(
                rect: original,
                translation: translationImg,
                imageSize: imageSize
            )
            selectStage = .move(instanceId: id, originalRect: original, liveRect: newRect)
        case .none:
            break
        }
    }

    private func onSelectDragEnded(viewSize: CGSize, imageSize: CGSize) {
        guard let stage = selectStage else {
            transform.commitPan()
            return
        }
        selectStage = nil
        switch stage {
        case .resize(let id, _, _, let live), .move(let id, _, let live):
            // Only commit if the rect passes the same sub-4px gate as a fresh draw.
            // (BoxIntake would re-check after clamp; resize already clamps.)
            if live.w >= Double(BoxIntake.minimumExtent), live.h >= Double(BoxIntake.minimumExtent) {
                store?.upsertBox(BBoxIntent(instanceId: id, rect: live))
            }
        }
    }

    /// Converts a view-translation delta to an image-pixel translation under
    /// the current zoom. Pan offset is irrelevant — translations are deltas.
    private func imageTranslation(viewTranslation: CGSize, viewSize: CGSize, imageSize: CGSize) -> CGSize {
        let baseScale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let renderedScale = baseScale * transform.zoom
        guard renderedScale > 0 else { return .zero }
        return CGSize(width: viewTranslation.width / renderedScale, height: viewTranslation.height / renderedScale)
    }
}

// MARK: - Color hex helper

extension Color {
    /// Parses a `#RRGGBB` hex string into a SwiftUI Color. Returns nil on
    /// malformed input. The 8 palette hexes live in `AthletePalette.hexes`
    /// (the only place hex literals are allowed); this helper just consumes
    /// the strings produced there.
    init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >> 8) & 0xFF) / 255.0
        let b = Double(v & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}
