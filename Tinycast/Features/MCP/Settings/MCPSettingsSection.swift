import SwiftUI

struct MCPSettingsSection: View {
    @Environment(MCPCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var appSettings
    @Environment(MCPSettingsStore.self) private var store
    @Environment(AppCore.self) private var core
    @State private var editor: MCPServerEditorTarget?
    @State private var removalError: String?

    var body: some View {
        @Bindable var appSettings = appSettings
        Section {
            Toggle(isOn: $appSettings.mcpEnabled) {
                SettingsRowTitle(.aiMCPServers, "Enable MCP servers")
            }
            Group {
                if store.servers.isEmpty {
                    Text("No MCP servers yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.servers) { server in
                        MCPServerRow(
                            server: server, status: coordinator.status(of: server.id),
                            onEdit: { editor = MCPServerEditorTarget(server: server, isNew: false) },
                            onRemove: { Task { await confirmRemoval(of: server) } })
                    }
                }
                Button {
                    editor = MCPServerEditorTarget(server: MCPServer(), isNew: true)
                } label: {
                    Label {
                        SettingsRowTitle(.aiMCPServers, "Add MCP Server")
                    } icon: {
                        Image(systemName: "plus")
                            .foregroundStyle(.primary)
                    }
                }
            }
            .settingsEnabled(appSettings.mcpEnabled)
            if let removalError {
                Label(removalError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.Colors.warningInk)
            }
        } header: {
            SettingsSectionHeader(.aiMCPServers)
        } footer: {
            Text("Type @slug to address one server. A chat asks before its first tool call.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .settingsEditorPanel(item: $editor) { target in
            MCPServerEditor(target: target, onSave: save, onCancel: { editor = nil })
        }
    }

    private func confirmRemoval(of server: MCPServer) async {
        guard
            await core.confirm(
                title: String(localized: "Remove \(server.title)?"),
                message: String(
                    localized: "Its tools stop being offered, and its stored credentials are deleted."),
                symbol: "wrench.and.screwdriver", confirmTitle: String(localized: "Remove"))
        else { return }
        remove(server)
    }

    /// A returned message is shown in the panel; nil closes it.
    private func save(_ server: MCPServer, _ secrets: MCPSecretStore.Secrets) -> String? {
        do {
            try coordinator.save(server, secrets: secrets)
        } catch {
            return String(localized: "The credentials could not be saved to your login Keychain.")
        }
        editor = nil
        return nil
    }

    private func remove(_ server: MCPServer) {
        do {
            try coordinator.remove(server.id)
            removalError = nil
        } catch {
            removalError = String(
                localized: """
                    \(server.title) was kept: its credentials could not be removed from your login \
                    Keychain.
                    """)
        }
    }
}

private struct MCPServerRow: View {
    let server: MCPServer
    let status: MCPServerStatus
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        SettingsRow(title: server.title, subtitle: subtitle) {
            Image(systemName: "wrench.and.screwdriver")
                .foregroundStyle(.primary)
        } trailing: {
            Button(action: onEdit) { Image(systemName: "pencil") }
                .settingsControl(.rowIcon)
                .help("Edit \(server.title)")
                .accessibilityLabel("Edit \(server.title)")
            Button(action: onRemove) {
                Image(systemName: "trash").foregroundStyle(Theme.Colors.destructive)
            }
            .settingsControl(.rowIcon)
            .help("Remove \(server.title)")
            .accessibilityLabel("Remove \(server.title)")
        }
    }

    /// The slug leads, because it is the half a reader has to type into the composer.
    private var subtitle: String {
        let state = server.isEnabled ? status.label : String(localized: "Disabled")
        return "@\(server.slug) · \(state) · \(server.transport.summary)"
    }
}
