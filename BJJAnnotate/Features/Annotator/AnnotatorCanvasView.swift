import SwiftUI

/// T14 — pinch / pan / double-tap-to-fit canvas surface. Image is rendered
/// `scaledToFit` inside a black background. The canvas owns:
///   - `CanvasTransform` (zoom + offset) — pure value-type, fully unit-tested.
///   - Magnification + DragGesture (two-finger pan) recognizers.
///   - Double-tap gesture (reset).
///
/// T15 (next dispatch) extends this view with the box-tool DragGesture + the
/// view-local drag-stage. T16 adds resize handles. T17–T20 add chips, picker,
/// instance list, and conflict banner.
///
/// Two gesture recognizers run concurrently:
///   - `MagnificationGesture` (pinch zoom).
///   - `DragGesture(minimumDistance: 0).simultaneously(with: ...)` — uses two
///     fingers for pan because the single-finger drag is reserved for the
///     box-tool in T15. Until T15 lands, single-finger drag is a no-op.
///
/// Pan + zoom commits happen on `.onEnded`. The view is host-agnostic — it
/// reads `imageSize` from the decoded UIImage so the math in
/// `CanvasTransform.viewToImage(...)` does not depend on the view geometry.
struct AnnotatorCanvasView: View {
    let imageURL: URL

    @State private var transform: CanvasTransform = CanvasTransform()
    @State private var liveMagnification: CGFloat = 1.0
    @State private var liveDragTranslation: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let uiImage = UIImage(contentsOfFile: imageURL.path) {
                    canvasContent(uiImage: uiImage, viewSize: geo.size)
                } else {
                    // Decode failure path. T22 will distinguish "missing" vs.
                    // "decode error"; for T14 we render the canvas blank and let
                    // the caller (`AnnotatorView`) decide on the surrounding UI.
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
        Image(uiImage: uiImage)
            .resizable()
            .scaledToFit()
            .scaleEffect(transform.zoom)
            .offset(x: transform.offset.width, y: transform.offset.height)
            .accessibilityLabel(imageURL.lastPathComponent)
            .accessibilityIdentifier("Annotator.Image")
            .gesture(
                pinchGesture(viewSize: viewSize, imageSize: imageSize)
                    .simultaneously(with: panGesture(viewSize: viewSize, imageSize: imageSize))
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    transform.doubleTapToFit()
                }
            }
    }

    // MARK: - Gestures

    private func pinchGesture(viewSize: CGSize, imageSize: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                liveMagnification = value
                transform.apply(pinch: value)
            }
            .onEnded { _ in
                transform.commitZoom()
                liveMagnification = 1.0
            }
    }

    /// Two-finger pan. SwiftUI's `DragGesture` doesn't natively expose touch
    /// count; we differentiate "draw" (single finger, T15) from "pan" (two
    /// fingers) at runtime via the upcoming `UIGestureRecognizerRepresentable`.
    /// For T14 (pre-box-tool), the drag gesture pans unconditionally so the
    /// pan path is exercisable end-to-end.
    private func panGesture(viewSize: CGSize, imageSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                liveDragTranslation = value.translation
                transform.apply(
                    panTranslation: value.translation,
                    viewSize: viewSize,
                    imageSize: imageSize
                )
            }
            .onEnded { _ in
                transform.commitPan()
                liveDragTranslation = .zero
            }
    }
}
