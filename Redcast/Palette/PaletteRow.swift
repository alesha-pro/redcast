import SwiftUI

/// A list row's fill, shape and hover in one place, so no list answers a selection differently.
private struct PaletteRowChrome: ViewModifier {
    let selected: Bool
    let cornerRadius: CGFloat?
    @Environment(\.metrics) private var metrics
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius ?? metrics.radius.row, style: .continuous)
                    .fill(fill)
            )
            .armedHover($hovered, animation: Theme.Motion.hover)
    }

    /// Selection wins over hover when a row is both; it is never eased, so held arrows stay crisp.
    private var fill: Color {
        if selected { return Theme.Colors.selection }
        return hovered ? Theme.Colors.rowHover : .clear
    }
}

extension View {
    /// Goes after the row's own padding; `cornerRadius` is for a row that is drawn as a card.
    func paletteRow(selected: Bool, cornerRadius: CGFloat? = nil) -> some View {
        modifier(PaletteRowChrome(selected: selected, cornerRadius: cornerRadius))
    }
}
