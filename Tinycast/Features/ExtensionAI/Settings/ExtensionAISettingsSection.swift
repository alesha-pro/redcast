import SwiftUI

/// Settings → Extensions → AI: the switch, the model extensions use, and each extension's answer.
struct ExtensionAISettingsSection: View {
    @Environment(AppCore.self) private var core

    var body: some View {
        let coordinator = core.extensionAICoordinator
        let store = coordinator.settings
        Section {
            Toggle(isOn: Binding(get: { store.isEnabled }, set: { coordinator.setEnabled($0) })) {
                SettingsRowTitle(.extensionsAI, "Allow extensions to use AI")
                Text("Raycast extensions that ask AI answer with your own model. Each one asks you first.")
            }
            if store.isEnabled {
                if !core.settings.aiEnabled {
                    Label("Turn on AI in Settings → AI first.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                AIModelSelectionRows(
                    selection: store.model, inheritedTitle: String(localized: "Same as AI Chat"),
                    select: store.select, modelLabel: { Text("Model") },
                    effortLabel: { Text("Reasoning effort") })
                ForEach(store.grants.keys.sorted(), id: \.self) { name in
                    Toggle(
                        title(of: name),
                        isOn: Binding(
                            get: { store.grants[name] == true }, set: { store.setGrant($0, for: name) }))
                }
                if !store.grants.isEmpty {
                    Button("Ask Again") { store.forgetAll() }
                }
            }
        } header: {
            SettingsSectionHeader(.extensionsAI)
        } footer: {
            Text(
                """
                Up to 10 requests a minute and 100 an hour per extension. Background refreshes can't use \
                AI, and a menu-bar command can use it only from an item you click.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onAppear { coordinator.repairModel() }
    }

    private func title(of extensionName: String) -> String {
        core.extensions.installed.first { $0.manifest.name == extensionName }?.title ?? extensionName
    }
}
