import SwiftUI

/// What a palette screen shows in place of rows: nothing found, work in progress, or a failure.
struct EmptyResults: View {
    /// The one thing left to do from here, drawn as a button that prints its own shortcut.
    struct Action {
        let title: String
        var keyCaps: [String] = []
        let perform: @MainActor () -> Void
    }

    let text: String
    var detail: String?
    var systemImage = "magnifyingglass"
    /// Work still running takes a spinner: a glyph would say the search already came back empty.
    var isLoading = false
    var action: Action?
    @Environment(\.metrics) private var metrics

    /// Wide enough for two lines of explanation, narrow enough to stay a caption under the tile.
    private static let detailWidth: CGFloat = 360
    /// AppKit's regular spinner, which is scaled into the glyph's slot so the two weigh the same.
    private static let regularSpinner: CGFloat = 32

    var body: some View {
        VStack(spacing: metrics.spacing.lg) {
            tile
            VStack(spacing: metrics.spacing.xs) {
                Text(text)
                    .font(metrics.typography.rowTitle.weight(.medium))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                if let detail {
                    Text(detail)
                        .font(metrics.typography.rowTrailing)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: metrics.scaled(Self.detailWidth))
            .accessibilityElement(children: .combine)
            if let action { button(action) }
        }
        .padding(.horizontal, metrics.spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The dialog's subject tile, so both surfaces name what they are about in one shape.
    private var tile: some View {
        Group {
            if isLoading {
                ProgressView()
                    .controlSize(.regular)
                    .scaleEffect(metrics.size.dialogSymbol / Self.regularSpinner)
            } else {
                SymbolImage(name: systemImage, size: metrics.size.dialogSymbol)
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

    private func button(_ action: Action) -> some View {
        Button(action: action.perform) {
            HStack(spacing: metrics.spacing.sm) {
                Text(action.title)
                HStack(spacing: metrics.spacing.xxs) {
                    ForEach(action.keyCaps, id: \.self) { KeyCapChip(text: $0, style: .outline) }
                }
                .accessibilityHidden(true)
            }
        }
        .buttonStyle(.modalAction(.standard, fillsWidth: false))
        .padding(.top, metrics.spacing.xs)
    }
}
