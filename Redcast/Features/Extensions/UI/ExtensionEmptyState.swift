import SwiftUI

/// An extension's own "nothing here", so a restyle of the palette's `EmptyResults` cannot reach it.
struct ExtensionEmptyState: View {
    let text: String
    var description: String?
    var systemImage = "magnifyingglass"
    /// An extension's own `List.EmptyView` icon, drawn in place of the glyph.
    var icon: ExtensionImage.Resolved?
    /// Work still running takes a spinner: a glyph would say the command already came back empty.
    var isLoading = false
    @Environment(\.metrics) private var metrics

    /// AppKit's regular spinner, scaled into the glyph's slot so the two weigh the same.
    private static let regularSpinner: CGFloat = 32
    /// Wide enough for two lines of explanation, narrow enough to stay a caption under the tile.
    private static let descriptionWidth: CGFloat = 360

    var body: some View {
        VStack(spacing: metrics.spacing.lg) {
            tile
            VStack(spacing: metrics.spacing.xs) {
                Text(text)
                    .font(metrics.typography.rowTitle.weight(.medium))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                if let description {
                    Text(description)
                        .font(metrics.typography.rowTrailing)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: metrics.scaled(Self.descriptionWidth))
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, metrics.spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tile: some View {
        Group {
            if isLoading {
                ProgressView()
                    .controlSize(.regular)
                    .scaleEffect(metrics.size.dialogSymbol / Self.regularSpinner)
            } else if let icon {
                ExtensionIconView(resolved: icon, size: metrics.size.dialogSymbolContainer)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: metrics.size.dialogSymbol))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .frame(width: metrics.size.dialogSymbolContainer, height: metrics.size.dialogSymbolContainer)
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.dialogSymbol, style: .continuous)
                .fill(Theme.Colors.controlSurface)
        )
        .accessibilityHidden(true)
    }
}
