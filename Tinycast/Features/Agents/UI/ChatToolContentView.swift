import SwiftUI

extension View {
    /// Fork: an ACP call's diff or output, folded under its transcript row until it is clicked.
    func toolContent(_ content: ChatToolContent?) -> some View {
        modifier(ChatToolContentFold(toolContent: content))
    }
}

/// Collapsed by default, and the expansion is the row's own, so nothing outlives the transcript.
private struct ChatToolContentFold: ViewModifier {
    @Environment(\.metrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let toolContent: ChatToolContent?
    @State private var isExpanded = false

    func body(content row: Content) -> some View {
        if let toolContent {
            VStack(alignment: .leading, spacing: metrics.spacing.sm) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: metrics.spacing.sm) {
                        row
                        Image(systemName: "chevron.down")
                            .font(metrics.typography.disclosure)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .animation(
                                reduceMotion ? nil : Theme.MenuMotion.chevronAnimation,
                                value: isExpanded)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                if isExpanded {
                    ChatToolContentView(content: toolContent)
                        .transition(.opacity)
                }
            }
            .animation(
                reduceMotion ? nil : .easeOut(duration: Theme.Duration.chatFooter), value: isExpanded)
        } else {
            row
        }
    }
}

/// Soft-wrapped like a code block: a second scroll view would fight the transcript's own.
private struct ChatToolContentView: View {
    @Environment(\.metrics) private var metrics
    let content: ChatToolContent

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.md) {
            ForEach(Array(content.diffs.enumerated()), id: \.offset) { index, diff in
                // Hunks of one file follow each other, so the path heads only the first.
                if index == 0 || content.diffs[index - 1].path != diff.path {
                    Text(verbatim: diff.path)
                        .font(metrics.typography.keyCap)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !diff.lines.isEmpty {
                    Text(Self.styled(ChatToolContent.lines(of: diff)))
                }
            }
            if content.omittedDiffs > 0 {
                Text("\(content.omittedDiffs) more changes not shown")
                    .font(metrics.typography.keyCap)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            if content.output != nil {
                HStack(alignment: .top, spacing: metrics.spacing.md) {
                    Text(Self.styled(content.outputLines))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ChatCopyButton(
                        text: Self.plainText(content.outputLines), label: String(localized: "Copy Output"))
                }
            }
        }
        .font(metrics.typography.code)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, metrics.spacing.xl)
        .padding(.vertical, metrics.spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.card, style: .continuous)
                .fill(Theme.Colors.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.radius.card, style: .continuous)
                .stroke(Theme.Colors.cardStroke))
    }

    /// One string per block, so the lines wrap and select as text rather than as rows of views.
    private static func styled(_ lines: [ChatToolContent.Line]) -> AttributedString {
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            var run: AttributedString
            switch line {
            case .removed(let text):
                run = AttributedString("- " + text)
                run.foregroundColor = Theme.Colors.destructive
            case .added(let text):
                run = AttributedString("+ " + text)
                run.foregroundColor = Theme.Colors.success
            case .context(let text):
                run = AttributedString("  " + text)
                run.foregroundColor = Theme.Colors.textSecondary
            case .text(let text):
                run = AttributedString(text)
            case .cut(let count):
                run = AttributedString(String(localized: "\(count) lines not shown"))
                run.foregroundColor = Theme.Colors.textTertiary
            }
            result.append(run)
        }
        return result
    }

    private static func plainText(_ lines: [ChatToolContent.Line]) -> String {
        lines.map { line in
            switch line {
            case .text(let text), .context(let text): text
            case .removed(let text): "-" + text
            case .added(let text): "+" + text
            case .cut(let count): String(localized: "\(count) lines not shown")
            }
        }.joined(separator: "\n")
    }
}
