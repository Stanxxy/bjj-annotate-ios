import SwiftUI

/// iOS-16-compatible empty state view (replaces `ContentUnavailableView` which requires iOS 17+).
///
/// Used in ProjectListView, ProjectGridView, and InstanceList. Renders a centered VStack with
/// a large system image, a bold title, and a description text.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let description: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text(description)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
    }
}
