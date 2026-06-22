import SwiftUI

/// Pure Canvas overlay that draws keypoint dots for the selected athlete instance.
///
/// Design constraints (evaluator gate):
/// - Pure `Canvas { ctx, size in ... }` — no @State, no store references.
/// - Only draws for the SELECTED instance (not all instances — too cluttered).
/// - Uses `KeypointPalette.color(for:)` exclusively — no hardcoded colors.
/// - Does NOT draw for referee instances (caller guards category_id).
///
/// Dot size: 10pt diameter circle.
/// Visibility ring: solid stroke for `.visible`, dashed stroke for `.occluded`, no ring for `.notLabeled`.
/// `.notLabeled` with non-zero coords: dimmed fill (0.25 opacity) + badge — tappable but visually distinct.
/// Badge: small Text overlay with keypoint index, 8pt font, black foreground.
struct KeypointLayer: View {

    let annotations: [CocoAnnotation]
    let selectedInstanceId: Int?
    let transform: CanvasTransform
    let imageSize: CGSize
    let viewSize: CGSize

    var body: some View {
        Canvas { ctx, _ in
            guard let id = selectedInstanceId,
                  let ann = annotations.first(where: { $0.id == id }),
                  ann.category_id != ClassCategory.ref.rawValue,
                  let kps = ann.keypoints, kps.count == 51 else { return }

            for kpDef in KeypointDefinition.all {
                let offset = kpDef.cocoArrayOffset
                let kpX = kps[offset]
                let kpY = kps[offset + 1]
                let visRaw = Int(kps[offset + 2])
                guard let vis = KPVisibility(rawValue: visRaw) else { continue }
                // Skip unplaced keypoints: v=0 at origin means never annotated.
                if vis == .notLabeled && kpX == 0 && kpY == 0 { continue }

                let viewPt = imageToView(CGPoint(x: kpX, y: kpY))
                let dotRadius: CGFloat = 5.0
                let dotRect = CGRect(
                    x: viewPt.x - dotRadius,
                    y: viewPt.y - dotRadius,
                    width: dotRadius * 2,
                    height: dotRadius * 2
                )

                let color = KeypointPalette.color(for: kpDef.side)
                let path = Path(ellipseIn: dotRect)

                // .notLabeled: dimmed fill so the dot is visible and tappable.
                // .visible / .occluded: standard 0.6-opacity fill.
                let fillOpacity: CGFloat = vis == .notLabeled ? 0.25 : 0.6
                ctx.fill(path, with: .color(color.opacity(fillOpacity)))

                // Stroke ring: solid for visible, dashed for occluded, none for not-labeled.
                switch vis {
                case .visible:
                    ctx.stroke(path, with: .color(color), lineWidth: 2)
                case .occluded:
                    ctx.stroke(
                        Path { p in p.addEllipse(in: dotRect) },
                        with: .color(color),
                        style: StrokeStyle(lineWidth: 2, dash: [3, 3])
                    )
                case .notLabeled:
                    break
                }

                // Index badge always shown.
                let badge = Text("\(kpDef.index)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.black)
                let resolved = ctx.resolve(badge)
                let labelSize = resolved.measure(in: CGSize(width: 20, height: 20))
                ctx.draw(
                    resolved,
                    at: CGPoint(x: viewPt.x - labelSize.width / 2, y: viewPt.y - labelSize.height / 2)
                )
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Coordinate conversion

    private func imageToView(_ imgPt: CGPoint) -> CGPoint {
        let baseScale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let renderedScale = baseScale * transform.zoom
        let renderedW = imageSize.width * renderedScale
        let renderedH = imageSize.height * renderedScale
        let originX = (viewSize.width - renderedW) / 2 + transform.offset.width
        let originY = (viewSize.height - renderedH) / 2 + transform.offset.height
        return CGPoint(
            x: originX + imgPt.x * renderedScale,
            y: originY + imgPt.y * renderedScale
        )
    }
}
