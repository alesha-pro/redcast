import AppKit
import Foundation

/// Every hotkey and alias the app knows, read live from the stores that own them.
@MainActor
enum ShortcutsInventory {
    struct Row: Identifiable {
        var entry: ShortcutEntry
        /// What the icon and alias field are drawn from; nil for the global actions.
        var app: AppEntry?
        var action: HotKeyAction?
        var symbol: String?

        var id: String { entry.id }
    }

    static func rows(core: AppCore) -> [Row] {
        var rows: [Row] = [
            global(.togglePalette, name: String(localized: "Show Launcher"), symbol: "command", core: core),
            global(
                .dictation, name: String(localized: "Dictation"), symbol: "mic",
                disabled: !core.settings.dictationEnabled, core: core)
        ]
        var seen = Set<String>()
        func add(_ app: AppEntry, disabled: Bool, keyword: String? = nil) {
            guard seen.insert(app.id).inserted else { return }
            rows.append(row(app, disabled: disabled, keyword: keyword, core: core))
        }
        let settings = core.settings
        for app in CommandCatalog.all {
            let command = CommandCatalog.command(for: app)
            let featureOff = app.kind == .quickAction && !settings.quickActionsEnabled
            add(app, disabled: featureOff || command.map { !core.appIndex.isCommandEnabled($0) } ?? false)
        }
        for command in core.customCommands.commands {
            add(AppEntry(command), disabled: !command.isEnabled || !settings.customCommandsEnabled)
        }
        for quicklink in core.quicklinks.quicklinks {
            add(AppEntry(quicklink), disabled: !quicklink.isEnabled || !settings.quicklinksEnabled)
        }
        for action in core.customQuickActions.actions {
            add(AppEntry(action), disabled: !settings.quickActionsEnabled)
        }
        for record in core.snippetsStore.snippets {
            let app = AppEntry(
                id: record.entryID, name: record.snippet.name, url: record.fileURL, bundleID: nil,
                kind: .snippet, alternateTitles: [])
            add(app, disabled: !record.snippet.isEnabled, keyword: record.snippet.keyword)
        }
        for agent in core.agentStore.agents {
            let handle = core.agentCoordinator.handle(of: agent.id) ?? agent.name
            add(AppEntry(agent, handle: handle), disabled: !settings.aiEnabled)
        }
        let extensions = core.extensions
        for owner in extensions.installed {
            for command in owner.manifest.commands {
                let reference = ExtensionCommandRef(
                    extensionName: owner.manifest.name, commandName: command.name)
                guard let app = extensions.launcherEntry(forEntryID: reference.entryID) else { continue }
                add(app, disabled: !extensions.isEnabled)
            }
        }
        for app in core.appleShortcutCoordinator.entries {
            add(app, disabled: !settings.appleShortcutsEnabled)
        }
        let windowsOff = !settings.windowManagementEnabled
        for command in WindowCommandCatalog.all { add(AppEntry(command), disabled: windowsOff) }
        for size in core.customWindowSizes.sizes { add(AppEntry(size), disabled: windowsOff) }
        for layout in core.windowLayouts.layouts { add(AppEntry(layout), disabled: windowsOff) }
        for room in core.rooms.rooms { add(AppEntry(room), disabled: windowsOff) }
        for app in core.appIndex.apps where !seen.contains(app.id) {
            // Apps, panes and system actions only matter here once something is bound to them.
            let bound = InlineEntryEditor.hotKeyAction(for: app).flatMap(core.hotKeys.binding(for:)) != nil
            guard app.kind == .systemAction || bound || core.aliases.alias(for: app.preferenceKey) != nil
            else { continue }
            add(app, disabled: false)
        }
        return rows
    }

    /// Rows whose shortcut the runtime gate refuses count as disabled, whatever their feature says.
    private static func row(_ app: AppEntry, disabled: Bool, keyword: String?, core: AppCore) -> Row {
        let action = InlineEntryEditor.hotKeyAction(for: app)
        let binding = action.flatMap(core.hotKeys.binding(for:))
        let gated = action.map { core.hotKeys.allowsAction?($0) == false } ?? false
        let entry = ShortcutEntry(
            id: app.id, name: app.name, kindLabel: app.kindLabel, aliasKey: app.preferenceKey,
            alias: core.aliases.alias(for: app.preferenceKey), keyword: keyword?.nilIfBlank, binding: binding,
            bindingText: binding.map { $0.keycaps.joined() } ?? "", isDisabled: disabled || gated)
        return Row(entry: entry, app: app, action: action)
    }

    private static func global(
        _ action: HotKeyAction, name: String, symbol: String, disabled: Bool = false, core: AppCore
    ) -> Row {
        let binding = core.hotKeys.binding(for: action)
        let entry = ShortcutEntry(
            id: action.defaultsKey, name: name, kindLabel: String(localized: "Global"), binding: binding,
            bindingText: binding.map { $0.keycaps.joined() } ?? "", isDisabled: disabled)
        return Row(entry: entry, action: action, symbol: symbol)
    }

    /// Read on each open of the pane, so a change in System Settings shows the next time.
    static func systemShortcuts() -> [SystemShortcut] {
        let symbolic = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys")
        return SystemShortcutCatalog.shortcuts(symbolicHotKeys: symbolic)
    }
}

extension String {
    fileprivate var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
