import SwiftUI

/// Tinycast's own menu-bar item. It carries no feature state, so no feature can hide or reshape it.
struct MenuBarLabel: View {
    let appName: String

    var body: some View {
        // Fork: Redcast's own mark, the command key whose top-right loop is an ember.
        Image("RedcastMenuBarIcon")
            .accessibilityLabel(appName)
    }
}

struct MenuBarMenu: View {
    let appName: String

    var body: some View {
        Button("Open \(appName)") {
            AppCore.shared.paletteCoordinator.showPalette(mode: .launcher)
        }
        // Read through Observation, so switching the feature off takes the row with it.
        if AppCore.shared.settings.clipboardEnabled {
            Button("Clipboard History") {
                AppCore.shared.paletteCoordinator.showPalette(mode: .clipboard)
            }
        }
        Divider()
        // Fork: no update check (the fork never updates itself) and no upstream donation row.
        Button("Settings…") { AppCore.shared.settingsCoordinator.showSettings() }
            .keyboardShortcut(",")
        Divider()
        // No ⌘Q: the app menu binds it to Close Settings, and two contradictory ⌘Qs is a lie.
        Button("Quit \(appName)") { NSApp.terminate(nil) }
    }
}
