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

    init(
        imageURL: URL,
        store: AnnotationStore? = nil,
        tool: AnnotatorTool = .box,
        rejectionToastVisible: Binding<Bool> = .constant(false)
    ) {
        self.imageURL = imageURL
        self.store = store
        self.tool = tool
        self._rejectionToastVisible = rejectionToastVisible
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

    /// Single-finger drag dispatches to either the box-tool path (active tool
    /// is `.box`) or the pan path (any other tool). Box drags stay view-local
    /// per R-UI-2 and only touch the store on `.onEnded`.
    private func combinedDragGesture(viewSize: CGSize, imageSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                switch tool {
                case .box:
                    let startImg = transform.viewToImage(viewPoint: value.startLocation, viewSize: viewSize, imageSize: imageSize)
                    let curImg = transform.viewToImage(viewPoint: value.location, viewSize: viewSize, imageSize: imageSize)
                    if dragStage == nil {
                        dragStage = BoxDragStage(startImagePoint: startImg, currentImagePoint: curImg)
                    } else {
                        dragStage?.currentImagePoint = curImg
                    }
                case .select, .keypoints:
                    transform.apply(panTranslation: value.translation, viewSize: viewSize, imageSize: imageSize)
                }
            }
            .onEnded { value in
                switch tool {
                case .box:
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
                            _ = store.upsertBox(BBoxIntent(rect: bbox))
                        }
                    case .rejectTooSmall:
                        rejectionToastVisible = true
                    }
                case .select, .keypoints:
                    transform.commitPan()
                }
            }
    }
}
