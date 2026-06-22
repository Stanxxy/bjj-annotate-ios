import SwiftUI

/// Pure Canvas overlay that draws COCO skeleton lines for the selected athlete instance.
///
/// Design constraints (evaluator gate):
/// - Pure `Canvas { ctx, size in ... }` — no @State, no store references.
/// - Drawn UNDER keypoint dots (z-order managed by caller via ZStack).
/// - Line color logic:
///   - Both endpoints left-side → cyan
///   - Both endpoints right-side → orange
///   - Cross-body or center → white
/// - If either endpoint is `.occluded` → 40% opacity on the line.
/// - If either endpoint is `.notLabeled` → skip line entirely.
struct SkeletonLayer: View {

    let annotations: [CocoAnnotation]
    let selectedInstanceId: Int?
    let transform: CanvasTransform
    let imageSize: CGSize
    let viewSize: CGSize

    /// COCO standard skeleton edges — pairs of 1-based keypoint indices.
    private static let skeleton: [[Int]] = [
        [16, 14], [14, 12], [17, 15], [15, 13],
        [12, 13], [6, 12],  [7, 13],  [6, 7],
        [6, 8],   [7, 9],   [8, 10],  [9, 11],
        [2, 3],   [1, 2],   [1, 3],   [2, 4],   [3, 5],
    ]

    var body: some View {
        Canvas { ctx, _ in
            guard let id = selectedInstanceId,
                  let ann = annotations.first(where: { $0.id == id }),
                  ann.category_id != ClassCategory.ref.rawValue,
                  let kps = ann.keypoints, kps.count == 51 else { return }

            // Build a lookup from 1-based index → (point, visibility).
            var pts = [Int: (CGPoint, KPVisibility)]()
            for kpDef in KeypointDefinition.all {
                let off = kpDef.cocoArrayOffset
                let vis = KPVisibility(rawValue: Int(kps[off + 2])) ?? .notLabeled
                let imgPt = CGPoint(x: kps[off], y: kps[off + 1])
                pts[kpDef.index] = (imageToView(imgPt), vis)
            }

            for edge in Self.skeleton {
                guard edge.count == 2 else { continue }
                let aIdx = edge[0], bIdx = edge[1]
                guard let (aPt, aVis) = pts[aIdx],
                      let (bPt, bVis) = pts[bIdx] else { continue }

                // Skip if either endpoint is not placed.
                guard aVis != .notLabeled, bVis != .notLabeled else { continue }

                // Determine line color from endpoint sides.
                let aSide = KeypointDefinition.all.first(where: { $0.index == aIdx })?.side ?? .center
                let bSide = KeypointDefinition.all.first(where: { $0.index == bIdx })?.side ?? .center
                let baseColor: Color
                if aSide == .left && bSide == .left {
                    baseColor = KeypointPalette.left
                } else if aSide == .right && bSide == .right {
                    baseColor = KeypointPalette.right
                } else {
                    baseColor = KeypointPalette.center
                }

                // Dim the line if either endpoint is occluded.
                let opacity: Double = (aVis == .occluded || bVis == .occluded) ? 0.4 : 1.0

                var linePath = Path()
                linePath.move(to: aPt)
                linePath.addLine(to: bPt)
                ctx.stroke(linePath, with: .color(baseColor.opacity(opacity)), lineWidth: 2)
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
