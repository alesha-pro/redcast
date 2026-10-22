import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The ⌘K menu's Change Alias and Change Shortcut rows, and the alias typed into one in place.
@MainActor
@Observable
final class InlineEntryEditor {
    /// The entry whose alias the menu is editing, keyed like `AliasStore`; nil when none is.
    private(set) var aliasKey: String?
    private(set) var draft = InlineAliasDraft(saved: nil)
    /// Only a recording this menu started is this menu's to stop.
    @ObservationIgnored private var recording: HotKeyAction?
    /// The menu an edit began in; a menu hidden without closing must not hand it to the next one.
    @ObservationIgnored private var presentation: UUID?

    func menuItems(for app: AppEntry, core: AppCore) -> [PopoverMenuItem] {
        let key = app.preferenceKey
        var alias = PopoverMenuItem(
            title: String(localized: "Change Alias"), systemImage: "character.cursor.ibeam",
            startsSection: true
        ) {
            self.beginAlias(key: key, core: core)
        }
        alias.trailingAccessory = { AnyView(MenuAliasBox(key: key)) }
        alias.keepsMenuOpen = true
        guard let action = Self.hotKeyAction(for: app) else { return [alias] }
        var shortcut = PopoverMenuItem(
            title: String(localized: "Change Shortcut"), systemImage: "command"
        ) {
            self.record(action, core: core)
        }
        shortcut.trailingAccessory = { AnyView(ShortcutRecorder(action: action)) }
        shortcut.keepsMenuOpen = true
        return [alias, shortcut]
    }

    /// `AppEntry.hotKeyAction` leaves extension commands out; their binding is keyed by entry ID.
    static func hotKeyAction(for app: AppEntry) -> HotKeyAction? {
        if let action = app.hotKeyAction { return action }
        return app.kind == .extensionCommand ? .extensionCommand(entryID: app.id) : nil
    }

    func editingKey(in palette: PaletteState) -> String? {
        presentation == palette.menuPresentationToken ? aliasKey : nil
    }

    /// While an alias is edited every plain key is its, ahead of the menu's own search field.
    func handleMenuKey(_ event: NSEvent, core: AppCore) -> Bool {
        guard aliasKey != nil else { return false }
        guard let key = editingKey(in: core.palette) else {
            end(core: core)
            return false
        }
        guard event.modifierFlags.isDisjoint(with: [.command, .control]) else { return false }
        let input: InlineAliasDraft.Key =
            switch Int(event.keyCode) {
            case kVK_Escape: .cancel
            case kVK_Return, kVK_ANSI_KeypadEnter: .commit
            case kVK_Delete: .deleteBackward
            default: .text(event.characters ?? "")
            }
        switch draft.apply(input) {
        case .editing:
            break
        case .cancelled:
            end(core: core)
        case .committed(let alias):
            core.aliases.setAlias(alias, for: key)
            end(core: core)
        }
        return true
    }

    /// Called as the menu closes, so neither edit outlives the menu it started in.
    func end(core: AppCore) {
        guard aliasKey != nil || recording != nil else { return }
        aliasKey = nil
        presentation = nil
        if let recording, core.hotKeys.recordingAction == recording {
            core.hotKeys.recordingAction = nil
        }
        recording = nil
    }

    private func beginAlias(key: String, core: AppCore) {
        end(core: core)
        draft = InlineAliasDraft(saved: core.aliases.alias(for: key))
        presentation = core.palette.menuPresentationToken
        aliasKey = key
    }

    private func record(_ action: HotKeyAction, core: AppCore) {
        end(core: core)
        recording = action
        core.hotKeys.recordingAction = action
    }
}

/// The saved alias, or the live draft with a caret while its row is being edited.
private struct MenuAliasBox: View {
    let key: String
    @Environment(AppCore.self) private var core
    @Environment(AliasStore.self) private var aliases
    @Environment(\.metrics) private var metrics

    private var editor: InlineEntryEditor { core.inlineEntryEditor }
    private var isEditing: Bool { editor.editingKey(in: core.palette) == key }
    private var value: String { isEditing ? editor.draft.text : aliases.alias(for: key) ?? "" }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.radius.menuRow, style: .continuous)
        HStack(spacing: 1) {
            Text(value.isEmpty ? String(localized: "Add Alias") : value)
                .font(metrics.typography.keyCap)
                .foregroundStyle(ink)
                .lineLimit(1)
                .truncationMode(.tail)
            if isEditing {
                Rectangle()
                    .fill(Theme.Colors.textSecondary)
                    .frame(width: 1.5, height: metrics.scaled(12))
            }
        }
        .frame(width: metrics.scaled(112), height: metrics.scaled(20))
        .background(shape.fill(Theme.Colors.cardFill))
        .overlay(
            shape.strokeBorder(
                isEditing ? Theme.Colors.textTertiary : Theme.Colors.cardStroke, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Change Alias"))
        .accessibilityValue(value)
    }

    /// Faded until edited, so a committed alias reads as settled.
    private var ink: Color {
        if value.isEmpty { return Theme.Colors.textTertiary }
        return isEditing ? Theme.Colors.textPrimary : Theme.Colors.textSecondary
    }
}
