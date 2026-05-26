import SwiftUI
import UIKit

/// Square thumbnail cell with placeholder, snap-replace (no fade — Designer pack
/// §State 2b performance affordance), and the file name as VoiceOver label.
struct ThumbnailCell: View {
    let url: URL
    var cache: ThumbnailCache
    @State private var image: UIImage? = nil
    @State private var didAttempt = false

    var body: some View {
        ZStack {
            Color(.tertiarySystemFill)
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .clipped()
        .accessibilityLabel(url.lastPathComponent)
        .accessibilityIdentifier("ProjectGrid.Cell.\(url.lastPathComponent)")
        .task {
            // Snap-replace; no animation per Designer pack §State 2b.
            guard !didAttempt else { return }
            didAttempt = true
            let loaded = await cache.image(for: url)
            self.image = loaded
        }
    }
}
