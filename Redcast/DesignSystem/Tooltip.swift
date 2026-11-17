import SwiftUI

private enum TooltipLabel {
    case text(String)
    case keyCaps([String])
}

/// A hover label in Redcast's own vocabulary, replacing a system `.help()` tooltip.
private struct TooltipModifier: ViewModifier {
    let label: TooltipLabel?
    let alignment: HorizontalAlignment
    let edge: VerticalEdge
    var dismissOnPress = false
    @Environment(\.metrics) private var metrics
    @State private var hovered = false
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .onHover {
                hovered = label != nil && $0
                if !hovered { visible = false }
            }
            .task(id: hovered) {
                guard hovered else { return }
                try? await Task.sleep(for: .seconds(Theme.Duration.tooltipDelay))
                guard !Task.isCancelled, hovered else { return }
                withAnimation(.easeOut(duration: Theme.Duration.tooltip)) { visible = true }
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0).onEnded { _ in
                    hovered = false
                    visible = false
                }, isEnabled: dismissOnPress
            )
            .overlay(alignment: Alignment(horizontal: alignment, vertical: side)) {
                if let label, visible { tile(label) }
            }
    }

    private var side: VerticalAlignment { edge == .top ? .top : .bottom }

    private func tile(_ label: TooltipLabel) -> some View {
        let shape = RoundedRectangle(cornerRadius: metrics.radius.tooltip, style: .continuous)
        return chip(label)
            .padding(metrics.spacing.xs)
            // Matte on purpose: it floats over the palette's glass, and glass does not stack.
            .background {
                shape.fill(Theme.Colors.tooltipSurface)
                shape.strokeBorder(Theme.Colors.cardStroke, lineWidth: Theme.Size.hairline)
            }
            .shadow(Theme.Shadow.card)
            .fixedSize()
            // A zero-height frame on the control's edge, so a label of any height hangs off it.
            .frame(height: 0, alignment: edge == .top ? .bottom : .top)
            .offset(y: edge == .top ? -metrics.spacing.sm : metrics.spacing.sm)
            .transition(.opacity)
            .allowsHitTesting(false)
    }

    @ViewBuilder private func chip(_ label: TooltipLabel) -> some View {
        switch label {
        case .text(let text):
            Text(text)
                .font(metrics.typography.tooltip)
                .foregroundStyle(Color.primary)
                .padding(.horizontal, metrics.spacing.xs)
                .frame(minHeight: metrics.size.keyCap)
        case .keyCaps(let caps):
            HStack(spacing: metrics.spacing.xxs) {
                ForEach(caps, id: \.self) { KeyCapChip(text: $0, style: .outline) }
            }
        }
    }
}

extension View {
    /// Align it against a side edge, and hang it `.bottom` from a control at the window's top.
    func tooltip(
        _ text: String?, alignment: HorizontalAlignment = .center, edge: VerticalEdge = .top,
        dismissOnPress: Bool = false
    ) -> some View {
        modifier(
            TooltipModifier(
                label: text.map(TooltipLabel.text), alignment: alignment, edge: edge,
                dismissOnPress: dismissOnPress))
    }

    func tooltip(keyCaps: [String]) -> some View {
        modifier(
            TooltipModifier(
                label: keyCaps.isEmpty ? nil : .keyCaps(keyCaps), alignment: .center, edge: .top))
    }
}
