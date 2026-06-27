import SwiftUI

extension View {
    /// `.presentationBackgroundInteraction(.enabled)` requires iOS 16.4+.
    /// This modifier applies it when available and silently skips it on earlier OS.
    @ViewBuilder
    func presentationBackgroundInteractionIfAvailable() -> some View {
        if #available(iOS 16.4, *) {
            self.presentationBackgroundInteraction(.enabled)
        } else {
            self
        }
    }
}
