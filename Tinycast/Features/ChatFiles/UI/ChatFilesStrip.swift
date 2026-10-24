import AppKit
import SwiftUI

extension EnvironmentValues {
    /// A finished reply's existing files, which its text links; nil leaves the text as it was.
    @Entry var chatFileLinks: ChatFileLinks?
    /// Where a transcript's relative paths resolve when no agent's folder says, as a session's cwd.
    @Entry var chatFilesDirectory: String?
}

extension View {
    /// A reply's file links in its text and its Files strip under it, both once it has finished.
    func chatFiles(for message: ChatMessage) -> some View {
        modifier(ChatFilesReply(message: message))
    }
}

/// Resolved when the reply finishes or comes into view, never per token, and kept with the view.
private struct ChatFilesReply: ViewModifier {
    @Environment(\.metrics) private var metrics
    @Environment(\.agentChatBadge) private var agent
    @Environment(\.chatFilesDirectory) private var directory
    let message: ChatMessage
    @State private var links = ChatFileLinks.empty

    private var request: ChatFileRequest? {
        guard message.role == .assistant, message.state != .streaming else { return nil }
        return ChatFileRequest(
            reply: message.text, directory: directory ?? agent?.directory, home: NSHomeDirectory(),
            toolTitles: message.toolUses.map(\.title),
            diffPaths: message.toolUses.flatMap { $0.content?.diffs.map(\.path) ?? [] })
    }

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: metrics.spacing.lg) {
            content.environment(\.chatFileLinks, links.byMention.isEmpty ? nil : links)
            if !links.files.isEmpty { ChatFilesStrip(files: links.files) }
        }
        .task(id: request) {
            guard let request else {
                links = .empty
                return
            }
            let resolved = await ChatFileSystem.resolve(request)
            guard !Task.isCancelled else { return }
            links = resolved
        }
    }
}

/// Under the reply, as its Sources are: what it named or wrote, one chip each.
private struct ChatFilesStrip: View {
    @Environment(\.metrics) private var metrics
    let files: [ChatFileItem]
    @State private var expanded = false

    var body: some View {
        let strip = ChatFileLinks.strip(files, expanded: expanded)
        VStack(alignment: .leading, spacing: metrics.spacing.sm) {
            Text("Files")
                .font(metrics.typography.rowTrailing.weight(.semibold))
                .foregroundStyle(Theme.Colors.textTertiary)
            ChatFlowLayout(spacing: metrics.spacing.sm) {
                ForEach(strip.shown) { file in
                    ChatFileChip(file: file)
                }
                if strip.hidden > 0 {
                    moreChip(Text(verbatim: "+\(strip.hidden)"), help: String(localized: "Show All"))
                } else if expanded {
                    moreChip(Text("Show Less"), help: String(localized: "Show Less"))
                }
            }
        }
        .padding(.top, metrics.spacing.xs)
    }

    private func moreChip(_ label: Text, help: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: Theme.Duration.chatFooter)) { expanded.toggle() }
        } label: {
            label
                .font(metrics.typography.rowTrailing)
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.textSecondary)
                .chatChip()
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Click opens or reveals, Space or the eye previews, right click offers the rest.
private struct ChatFileChip: View {
    @Environment(\.metrics) private var metrics
    let file: ChatFileItem
    @State private var hovered = false

    private var path: String { (file.path as NSString).abbreviatingWithTildeInPath }

    var body: some View {
        HStack(spacing: metrics.spacing.sm) {
            Button {
                ChatFileActions.activate(file.path)
            } label: {
                HStack(spacing: metrics.spacing.md) {
                    ChatFileThumbnail(file: file)
                    Text(verbatim: file.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: Theme.Size.chatSourceTitle, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onKeyPress(.space) {
                ChatFileActions.quickLook(file.path)
                return .handled
            }
            .help(path)
            .accessibilityLabel(Text(verbatim: file.name))
            .accessibilityHint(Text(verbatim: path))
            .accessibilityAction(named: Text("Quick Look")) {
                ChatFileActions.quickLook(file.path)
            }
            Button {
                ChatFileActions.quickLook(file.path)
            } label: {
                Image(systemName: "eye")
                    .font(metrics.typography.keyCap)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .frame(width: metrics.size.chatMessageAction, height: metrics.size.chatMessageAction)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Quick Look")
            .accessibilityHidden(true)
            // Laid out at rest and only faded in, so a hover cannot reflow the strip.
            .opacity(hovered ? 1 : 0)
        }
        .font(metrics.typography.rowTrailing)
        .chatChip(leadsWithBadge: true)
        .onHover { hovered = $0 }
        .onRightClick { ChatFileActions.popUpMenu(for: file.path) }
    }
}

/// An image's own picture, any other item's Finder icon; both from the shared caches, lazily.
private struct ChatFileThumbnail: View {
    @Environment(\.metrics) private var metrics
    @Environment(\.displayScale) private var scale
    let file: ChatFileItem
    @State private var image: NSImage?

    var body: some View {
        let side = metrics.size.chatSourceBadge
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: file.kind == .image ? .fill : .fit)
            } else {
                Image(systemName: ChatFileLinker.symbol(file.kind))
                    .font(metrics.typography.keyCap)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: metrics.radius.thumbnail, style: .continuous))
        .task(id: file) {
            let url = URL(fileURLWithPath: file.path)
            let loaded =
                file.kind == .image
                ? await FilePreviewThumbnail.loadAsync(url, maxPixel: side * scale)
                : await IconCache.loadAsync(forFile: file.path, size: IconSize(points: side, scale: scale))
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
