import SwiftUI

extension View {
    /// Fork: an ACP call's diff or output, folded under its transcript row until it is clicked.
    func toolContent(_ content: ChatToolContent?) -> some View {
        modifier(ChatToolContentFold(toolContent: content))
    }
}

/// Collapsed by default, and the expansion is the row's own, so nothing outlives the transcript.
private struct ChatToolContentFold: ViewModifier {
    let toolContent: ChatToolContent?
    @State private var isExpanded = false

    func body(content row: Content) -> some View {
        if let toolContent {
            ChatToolDisclosure(row: row, toolContent: toolContent, isExpanded: $isExpanded)
        } else {
            row
        }
    }
}

/// Only a call with something to unfold reads the metrics; most rows have nothing.
private struct ChatToolDisclosure<Row: View>: View {
    @Environment(\.metrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let row: Row
    let toolContent: ChatToolContent
    @Binding var isExpanded: Bool

    var body: some View {
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
    }
}

/// Soft-wrapped like a code block, and carded like one: a header row over monospaced lines.
private struct ChatToolContentView: View {
    @Environment(\.metrics) private var metrics
    let content: ChatToolContent

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.radius.codeBlock, style: .continuous)
        VStack(alignment: .leading, spacing: metrics.spacing.md) {
            ForEach(Array(content.diffs.enumerated()), id: \.offset) { index, diff in
                // Hunks of one file follow each other, so the path heads only the first.
                let heads = index == 0 || content.diffs[index - 1].path != diff.path
                if heads || !diff.lines.isEmpty {
                    VStack(alignment: .leading, spacing: metrics.spacing.sm / 2) {
                        if heads { header(diff.path) }
                        if !diff.lines.isEmpty {
                            Text(Self.styled(ChatToolContent.lines(of: diff), gutter: "  "))
                        }
                    }
                }
            }
            if content.omittedDiffs > 0 {
                Text("\(content.omittedDiffs) more changes not shown")
                    .font(metrics.typography.keyCap)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            if content.output != nil {
                VStack(alignment: .leading, spacing: metrics.spacing.sm / 2) {
                    header(String(localized: "Output"), copying: Self.plainText(content.outputLines))
                    Text(Self.styled(content.outputLines, gutter: ""))
                }
            }
        }
        .font(metrics.typography.code)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A code block's own insets, so the header, its rule and the first line sit alike in both.
        .padding(.horizontal, metrics.spacing.xl)
        .padding(.top, metrics.spacing.md)
        .padding(.bottom, metrics.spacing.lg)
        .background(shape.fill(Theme.Colors.cardFill))
        .overlay(shape.strokeBorder(Theme.Colors.cardStroke))
    }

    /// A code block's own header: what follows on the leading edge, its copy on the trailing one.
    private func header(_ title: String, copying text: String? = nil) -> some View {
        HStack(spacing: metrics.spacing.md) {
            Text(verbatim: title)
                .font(metrics.typography.keyCap)
                .foregroundStyle(Theme.Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: metrics.spacing.md)
            if let text { ChatCopyButton(text: text, label: String(localized: "Copy Output")) }
        }
        .frame(minHeight: metrics.size.chatMessageAction)
        .padding(.bottom, metrics.spacing.sm / 2)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Colors.cardStroke).frame(height: Theme.Size.hairline)
        }
    }

    /// One string per block, so the lines wrap and select as text; a cut sits in a diff's gutter.
    private static func styled(_ lines: [ChatToolContent.Line], gutter: String) -> AttributedString {
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
                run = AttributedString(gutter + String(localized: "\(count) lines not shown"))
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
