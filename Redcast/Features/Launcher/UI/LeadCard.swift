import SwiftUI

/// The card's surface over the shared row chrome, so no card answers a selection differently.
private struct LeadCardChrome: ViewModifier {
    @Environment(\.metrics) private var metrics
    let selected: Bool

    func body(content: Content) -> some View {
        content
            .background(shape.fill(Theme.Colors.cardFill))
            .overlay {
                shape.strokeBorder(Theme.Colors.cardStroke, lineWidth: Theme.Size.hairline)
                    .allowsHitTesting(false)
            }
            .paletteRow(selected: selected, cornerRadius: metrics.radius.card)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: metrics.radius.card, style: .continuous)
    }
}

extension View {
    /// Padding stays each card's own: a meeting card is deliberately shorter than an answer.
    func leadCard(selected: Bool) -> some View {
        modifier(LeadCardChrome(selected: selected))
    }
}

struct LeadCardColumn: View {
    @Environment(\.metrics) private var metrics
    let text: AttributedString
    let badge: String?
    var weight: Font.Weight = .medium

    var body: some View {
        VStack(spacing: metrics.spacing.md) {
            Text(text)
                .font(metrics.typography.calcResult.weight(weight))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let badge { LeadCardBadge(text: badge) }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, metrics.spacing.md)
    }
}

private struct LeadCardBadge: View {
    @Environment(\.metrics) private var metrics
    let text: String

    var body: some View {
        Text(text)
            .font(metrics.typography.keyCap)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(.secondary)
            .padding(.horizontal, metrics.spacing.sm)
            .padding(.vertical, metrics.spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: metrics.radius.keyCap, style: .continuous)
                    .fill(Theme.Colors.controlSurface)
            )
    }
}
