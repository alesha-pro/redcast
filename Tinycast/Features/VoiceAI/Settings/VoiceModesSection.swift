import SwiftUI

/// The Dictation pane's modes: prompts a cloud transcript passes through, by default and per app.
struct VoiceModesSection: View {
    @Environment(AppCore.self) private var core
    @Environment(AppIndex.self) private var appIndex
    @State private var editing: VoiceModeEditRequest?
    @State private var pickingApp = false

    var body: some View {
        let modes = core.voiceSettings.modes
        Group {
            Section {
                Picker(selection: defaultBinding) {
                    Text("None").tag(UUID?.none)
                    ForEach(modes.all) { mode in
                        Text(verbatim: mode.name).tag(Optional(mode.id))
                    }
                } label: {
                    SettingsRowTitle(.dictationModes, "Default mode")
                    Text("For apps without a mode of their own.")
                }
                ForEach(modes.all) { mode in
                    modeRow(mode, inCycle: !modes.hidden.contains(mode.id))
                }
                Button {
                    editing = VoiceModeEditRequest(mode: nil)
                } label: {
                    SettingsRowTitle(.dictationModes, "Add Mode")
                }
            } header: {
                SettingsSectionHeader(.dictationModes)
            } footer: {
                Text(
                    """
                    A mode rewrites what you said before it is typed. Press Tab in the dictation \
                    capsule to switch modes; Tinycast remembers the choice for the app in front.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section {
                ForEach(modes.apps.keys.sorted(), id: \.self) { bundleID in
                    appRow(bundleID, modes: modes.all)
                }
                Button {
                    pickingApp = true
                } label: {
                    SettingsRowTitle(.dictationModesByApp, "Add Application…")
                }
                .popover(isPresented: $pickingApp, arrowEdge: .bottom) {
                    AppPickerPopover(excluded: Set(modes.apps.keys)) { bundleID in
                        core.voiceSettings.modes.apps[bundleID] = VoiceModeSettings.plain
                        pickingApp = false
                    }
                }
            } header: {
                SettingsSectionHeader(.dictationModesByApp)
            }
        }
        .settingsEditorPanel(item: $editing) { VoiceModeEditorPanel(request: $0) }
    }

    private func modeRow(_ mode: VoiceMode, inCycle: Bool) -> some View {
        SettingsRow(title: mode.name, subtitle: mode.instructions) {
            Image(systemName: VoiceModeCatalog.symbol(for: mode.id))
                .frame(width: Theme.Size.settingsRowIcon)
        } trailing: {
            Button {
                editing = VoiceModeEditRequest(mode: mode)
            } label: {
                SymbolImage(name: "pencil", size: Theme.Size.quickActionHeaderIcon)
            }
            .buttonStyle(.plain)
            .help("Edit \(mode.name)")
            .accessibilityLabel("Edit \(mode.name)")
            Toggle("", isOn: cycleBinding(mode.id, inCycle: inCycle))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help("Switch to it with Tab in the capsule")
                .accessibilityLabel("Switch to \(mode.name) with Tab")
        }
    }

    private func appRow(_ bundleID: String, modes: [VoiceMode]) -> some View {
        let (name, icon) = AppPresentation.resolve(bundleID: bundleID, in: appIndex)
        return LabeledContent {
            HStack(spacing: Theme.Spacing.md) {
                Picker("", selection: appBinding(bundleID)) {
                    Text("None").tag(VoiceModeSettings.plain)
                    ForEach(modes) { mode in
                        Text(verbatim: mode.name).tag(mode.id.uuidString)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Mode for \(name)")
                Button {
                    core.voiceSettings.modes.apps[bundleID] = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(name)")
            }
        } label: {
            Label {
                Text(verbatim: name).lineLimit(1)
            } icon: {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: SettingsListMetrics.iconSize, height: SettingsListMetrics.iconSize)
            }
        }
    }

    private var defaultBinding: Binding<UUID?> {
        Binding(
            get: { core.voiceSettings.modes.defaultMode },
            set: { core.voiceSettings.modes.defaultMode = $0 })
    }

    private func cycleBinding(_ id: UUID, inCycle: Bool) -> Binding<Bool> {
        Binding(
            get: { inCycle },
            set: { core.voiceSettings.modes.setHidden(!$0, id) })
    }

    /// A mode since deleted reads as None, the plain transcript it now types.
    private func appBinding(_ bundleID: String) -> Binding<String> {
        Binding(
            get: {
                let entry = core.voiceSettings.modes.apps[bundleID]
                return core.voiceSettings.modes.mode(id: entry.flatMap(UUID.init(uuidString:)))?.id.uuidString
                    ?? VoiceModeSettings.plain
            },
            set: { core.voiceSettings.modes.apps[bundleID] = $0 })
    }
}
