import SwiftUI

/// A Claude Code or Codex session's facts, its last turns and the exact command that resumes it.
struct AgentSessionPreview: View {
    @Environment(\.metrics) private var metrics
    let session: AgentSession
    let live: AgentLiveEntry?
    let codexHistory: URL
    /// Dropped with the selection, so only one preview is ever held.
    @State private var messages: [ChatMessage]?

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.md) {
            header
            transcript
            if let command = AgentResumeCommand.command(for: session, action: .resume) {
                Text(verbatim: command)
                    .font(metrics.typography.inlineCode)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.horizontal, metrics.spacing.lg)
                    .padding(.bottom, metrics.spacing.md)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: session.id) {
            messages = nil
            let turns = await AgentSessionsScanner.previewTurns(for: session, codexHistory: codexHistory)
            guard !Task.isCancelled else { return }
            messages = (turns ?? []).map { turn in
                ChatMessage(
                    role: turn.role == .user ? .user : .assistant, text: turn.text,
                    sentAt: turn.date ?? session.updatedAt)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.xxs) {
            Text(verbatim: AgentSessionsList.title(of: session))
                .font(metrics.typography.panelTitle)
                .lineLimit(2)
            ForEach(detailLines, id: \.self) { line in
                Text(verbatim: line)
                    .font(metrics.typography.keyCap)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let status = live?.status, status.isLive {
                Text(verbatim: statusLine(status))
                    .font(metrics.typography.keyCap)
                    .foregroundStyle(AgentSessionsList.chipColor(status))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(metrics.spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous).fill(Theme.Colors.cardFill)
        )
        .padding([.horizontal, .top], metrics.spacing.md)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var transcript: some View {
        if let messages, !messages.isEmpty {
            ChatTranscriptView(messages: messages, status: nil, usage: nil, surface: .palette)
        } else if messages != nil {
            Text("Preview unavailable. Resume the session to read it.")
                .font(metrics.typography.keyCap)
                .foregroundStyle(Theme.Colors.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var detailLines: [String] {
        var lines: [String] = []
        let place = [
            session.directory.map { ($0 as NSString).abbreviatingWithTildeInPath }, session.branch
        ].compactMap { $0 }
        if !place.isEmpty { lines.append(place.joined(separator: " · ")) }
        lines.append(session.source.productName + " · " + hostName)
        let started = String(localized: "Started \(session.createdAt.formatted(date: .abbreviated, time: .shortened))")
        let active = String(localized: "Last active \(session.updatedAt.formatted(date: .abbreviated, time: .shortened))")
        lines.append(started + " · " + active)
        return lines
    }

    private var hostName: String {
        switch session.host {
        case .terminal: String(localized: "Terminal session")
        case .claudeApp: String(localized: "Claude app")
        case .codexApp: String(localized: "Codex app")
        case .editor: String(localized: "Editor")
        case .automated: String(localized: "Automated run")
        case .tinycast: session.agentName.map { String(localized: "Agent: \($0)") } ?? AgentSource.tinycast.productName
        }
    }

    private func statusLine(_ status: AgentLiveStatus) -> String {
        guard case .waiting(let reason?) = status else { return AgentSessionsList.chipTitle(status) }
        return AgentSessionsList.chipTitle(status) + " · " + reason
    }
}
