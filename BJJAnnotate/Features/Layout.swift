import SwiftUI

/// Size-class-driven layout helpers. R-UI-1 mandate: ALL adaptive layout in
/// BJJAnnotate must branch on `@Environment(\.horizontalSizeClass)`, NEVER on
/// the UIKit device-idiom flag. The device-idiom signal does not reflect
/// runtime size class changes (Slide Over, Split View, Stage Manager) and would
/// lock us into a Phase-1 bug on iPad multitasking. The companion grep gate
/// `UIDeviceUserInterfaceIdiomBanTests` enforces this at CI time.
///
/// Use via `Layout.AdaptiveAnchor { compact in ... }` or by reading
/// `\.horizontalSizeClass` directly in a view's body.
enum Layout {

    /// Renders one of two view builders depending on the ambient size class.
    /// `compactBranch` is used when `horizontalSizeClass == .compact` (iPhone
    /// portrait, iPad in Slide Over). `regularBranch` is used otherwise.
    ///
    /// Example (T19 Instance list — bottom sheet vs. right rail):
    /// ```
    /// Layout.AdaptiveAnchor(
    ///     compact: { InstanceListSheet(...) },
    ///     regular: { InstanceListRail(...) }
    /// )
    /// ```
    struct AdaptiveAnchor<Compact: View, Regular: View>: View {
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass

        private let compactBuilder: () -> Compact
        private let regularBuilder: () -> Regular

        init(
            @ViewBuilder compact: @escaping () -> Compact,
            @ViewBuilder regular: @escaping () -> Regular
        ) {
            self.compactBuilder = compact
            self.regularBuilder = regular
        }

        var body: some View {
            if horizontalSizeClass == .compact {
                compactBuilder()
            } else {
                regularBuilder()
            }
        }
    }
}
