import SwiftUI

/// What an empty chat shows on either surface, and why it cannot answer when it cannot.
struct AIEmptyState: View {

    @Environment(\.metrics) private var metrics
    let message: String?
    let canConfigure: Bool
    let onConfigure: () -> Void
    /// Fork: the window's starters, each handed to the composer to finish; nil leaves them out.
    var onStart: ((String) -> Void)?

    /// Wide enough for two lines of explanation, as `EmptyResults` keeps its caption.
    private static let detailWidth: CGFloat = 360

    var body: some View {
        VStack(spacing: metrics.spacing.lg) {
            GlyphTile(symbol: "sparkles", hue: GlyphCategory.ai.hue, size: metrics.size.dialogSymbolContainer)
            VStack(spacing: metrics.spacing.xs) {
                Text("Ask anything")
                    .font(metrics.typography.panelTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)
                if let message {
                    Text(message)
                        .font(metrics.typography.rowTrailing)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .multilineTextAlignment(.center)
                } else {
                    hints
                }
            }
            .frame(maxWidth: metrics.scaled(Self.detailWidth))
            if message != nil {
                if canConfigure {
                    Button("Configure AI", action: onConfigure)
                        .buttonStyle(.modalAction(.standard, fillsWidth: false))
                        .padding(.top, metrics.spacing.xs)
                }
            } else if let onStart {
                AIStarterChips(onStart: onStart)
                    .frame(maxWidth: metrics.scaled(Self.detailWidth * 2))
                    .padding(.top, metrics.spacing.sm)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, metrics.spacing.xxl)
    }

    /// The composer's two keys, the second only where the composer is a multi-line field.
    private var hints: some View {
        HStack(spacing: metrics.spacing.md) {
            hint("Send a message", keys: ["↵"])
            if onStart != nil { hint("New line", keys: ["⇧", "↵"]) }
        }
        .font(metrics.typography.rowTrailing)
        .foregroundStyle(Theme.Colors.textTertiary)
    }

    private func hint(_ title: LocalizedStringKey, keys: [String]) -> some View {
        HStack(spacing: metrics.spacing.sm) {
            Text(title)
            HStack(spacing: metrics.spacing.xxs) {
                ForEach(keys, id: \.self) { KeyCapChip(text: $0) }
            }
            .accessibilityHidden(true)
        }
    }
}

/// Fork: an empty chat's first words, in the reply chips' capsules, left for the reader to finish.
private struct AIStarterChips: View {
    @Environment(\.metrics) private var metrics
    let onStart: (String) -> Void

    private var starters: [(symbol: String, title: String)] {
        [
            ("text.bubble", String(localized: "Explain simply")),
            ("list.bullet.rectangle", String(localized: "Summarize")),
            ("pencil.line", String(localized: "Help me write")),
            ("lightbulb", String(localized: "Brainstorm ideas"))
        ]
    }

    var body: some View {
        ChatFlowLayout(spacing: metrics.spacing.sm) {
            ForEach(starters, id: \.title) { starter in
                Button {
                    onStart(
                        String(
                            localized: "\(starter.title): ",
                            comment: "A starter's words left in the chat composer for the reader to finish"))
                } label: {
                    HStack(spacing: metrics.spacing.sm) {
                        Image(systemName: starter.symbol)
                            .font(metrics.typography.keyCap)
                            .foregroundStyle(Theme.Colors.textSecondary)
                        Text(verbatim: starter.title)
                            .lineLimit(1)
                    }
                    .font(metrics.typography.rowTrailing)
                    .chatChip()
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggested")
    }
}
