import SwiftUI

/// Per-image annotation surface.
///
/// Phase 1 scope summary:
///   T13 (this commit): minimal skeleton — image render + back action + zero-image
///       guard. AC #8 (tap thumbnail to push), AC #39 (image deleted while
///       suspended).
///   T14–T22 (deferred to follow-up dispatch): canvas gestures, box tool, class
///       chips, athlete picker, instance list, conflict banner, lifecycle flush.
///       Each of those tasks expands this skeleton incrementally per the AIP.
///
/// The view requires the image URL up front so re-entry after deletion shows the
/// locked "no longer available" copy without an extra round-trip.
struct AnnotatorView: View {
    let imageURL: URL

    var body: some View {
        Group {
            if FileManager.default.fileExists(atPath: imageURL.path) {
                imageBody
            } else {
                // AC #39 zero-image guard.
                missingImageBody
            }
        }
        .navigationTitle(imageURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("Annotator.Root")
    }

    private var imageBody: some View {
        // T14 will replace this with AnnotatorCanvasView (zoom/pan/draw). For T13
        // the skeleton renders the image as-is so navigation can be verified.
        Group {
            if let uiImage = UIImage(contentsOfFile: imageURL.path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel(imageURL.lastPathComponent)
                    .accessibilityIdentifier("Annotator.Image")
            } else {
                // File exists on disk but UIImage decode failed. Treat as missing
                // for now — T14 will distinguish decode failure vs. missing.
                missingImageBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var missingImageBody: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(LockedCopy.imageNoLongerAvailable)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier("Annotator.MissingImage")
    }
}
