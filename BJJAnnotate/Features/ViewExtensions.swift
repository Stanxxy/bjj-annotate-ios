import SwiftUI

extension View {
    /// `.presentationBackgroundInteraction(.enabled)` requires iOS 16.4+.
    /// This modifier applies it when available and silently skips it on earlier OS.
    ///
    /// P2 / iOS 16.0–16.3 gap:
    /// On iOS 16.0–16.3 the `else { self }` branch is taken, meaning the bottom
    /// sheet does NOT pass touches through to the canvas below it. In compact
    /// (iPhone) layout this makes the 88 pt collapsed sheet opaque-blocking:
    /// foot-level keypoints below the sheet floor are unreachable without the
    /// user manually dragging the sheet further down.
    /// iOS 16.4 is the effective floor for full keypoint passthrough in compact mode.
    @ViewBuilder
    func presentationBackgroundInteractionIfAvailable() -> some View {
        if #available(iOS 16.4, *) {
            self.presentationBackgroundInteraction(.enabled)
        } else {
            // iOS 16.0–16.3: passthrough not available. Sheet is opaque-blocking.
            // See note above and AnnotatorView.compactAnnotatorLayout for user impact.
            self
        }
    }
}
