import SwiftUI

private struct ArmedHover: ViewModifier {
    @Environment(PaletteState.self) private var palette
    @Binding var hovered: Bool
    let animation: Animation?

    func body(content: Content) -> some View {
        content
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active: point(palette.hoverHighlightArmed)
                case .ended: point(false)
                }
            }
            // Disarming under a still pointer fires no hover phase, so the drop clears the row.
            .onChange(of: palette.hoverDisarmToken) { hovered = false }
    }

    /// Only the pointer's own changes ease; a key's disarm lands at once, leaving no ghost.
    private func point(_ lit: Bool) {
        guard lit != hovered else { return }
        if let animation {
            withAnimation(animation) { hovered = lit }
        } else {
            hovered = lit
        }
    }
}

extension View {
    /// Row hover, lit only while the pointer moves; independent of the keyboard selection.
    func armedHover(_ hovered: Binding<Bool>, animation: Animation? = nil) -> some View {
        modifier(ArmedHover(hovered: hovered, animation: animation))
    }
}
