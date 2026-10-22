import SwiftUI

/// The reviewed diff: nothing is written before Turn On or Turn Off, and a moved file is re-read.
struct AgentHooksPanel: View {
    @Environment(\.settingsEditorDismiss) private var dismiss
    @Environment(AppCore.self) private var core
    @State private var plan: AgentSessionsCoordinator.LiveStatusPlan
    @State private var applying = false
    @State private var failure: String?
    let onFinish: () -> Void

    init(plan: AgentSessionsCoordinator.LiveStatusPlan, onFinish: @escaping () -> Void) {
        _plan = State(initialValue: plan)
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            SettingsEditorHeader(
                title: plan.turningOn ? "Turn On Live Status" : "Turn Off Live Status",
                subtitle: plan.turningOn
                    ? """
                    Live status adds small hooks to Claude Code and Codex that tell Tinycast when an agent \
                    finishes or waits for you. You see every change before it is written, and the original \
                    file is backed up.
                    """ : nil)
            if let notice = plan.notice {
                Text(verbatim: notice)
                    .font(.callout)
                    .foregroundStyle(Theme.Colors.warning)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    ForEach(plan.changes, id: \.target) { change in
                        AgentHookChangeView(
                            change: change, url: plan.snapshots[change.target]?.url, backups: plan.backups)
                    }
                    ForEach(plan.problems, id: \.self) { problem in
                        Text(verbatim: problem)
                            .font(.callout)
                            .foregroundStyle(Theme.Colors.destructive)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 560)
            if let failure {
                Text(verbatim: failure)
                    .font(.callout)
                    .foregroundStyle(Theme.Colors.destructive)
            }
            HStack(spacing: Theme.Spacing.md) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.modalAction(.cancel))
                    .keyboardShortcut(.cancelAction)
                Button(plan.turningOn ? "Turn On" : "Turn Off", action: apply)
                    .buttonStyle(.modalAction(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled((plan.turningOn && plan.changes.isEmpty) || applying)
            }
        }
        .padding(Theme.Spacing.dialogInset)
        .frame(width: Theme.Size.editorSheetWidth)
        .settingsEditorPanelSurface()
    }

    private func apply() {
        applying = true
        Task {
            let result = await core.agentSessionsCoordinator.apply(plan)
            applying = false
            switch result {
            case .done:
                onFinish()
                dismiss()
            case .changed(let fresh):
                plan = fresh
            case .failed(let message):
                failure = message
            }
        }
    }
}

private struct AgentHookChangeView: View {
    let change: AgentHookFileFormat.Change
    let url: URL?
    let backups: URL

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                Text(verbatim: path(url))
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Spacing.md)
                Text(verb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(change.removedLines.enumerated()), id: \.offset) { _, line in
                    diffLine("−", line, color: Theme.Colors.destructive)
                }
                ForEach(Array(change.addedLines.enumerated()), id: \.offset) { _, line in
                    diffLine("+", line, color: Theme.Colors.success)
                }
            }
            .padding(Theme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.thumbnail, style: .continuous)
                    .fill(Theme.Colors.cardFill))
            if change.before != nil {
                Text("Backup: \(path(backups))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if change.target == .codex, change.after != nil {
                Text("Codex runs new hooks only after you trust them: type /hooks in Codex once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var verb: LocalizedStringKey {
        if change.before == nil { return "Will create" }
        if change.after == nil { return "Will remove" }
        return "Will change"
    }

    private func diffLine(_ mark: String, _ line: String, color: Color) -> some View {
        Text(verbatim: mark + " " + line)
            .font(.caption.monospaced())
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func path(_ url: URL?) -> String {
        guard let url else { return change.target.fileName }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }
}
