import SwiftUI

/// Under the Web search toggle: which engines answer, and the button that edits them.
struct WebSearchEnginesRow: View {
    @Environment(AppCore.self) private var core
    @State private var presented = false

    var body: some View {
        let store = core.webSearch
        SettingsRow(title: "Search engines", subtitle: store.summary, anchor: .aiChat) {
            Button("Manage…") { presented = true }
        }
        .settingsEditorPanel(isPresented: $presented) {
            WebSearchEnginesPanel(configuration: store.configuration, onDone: { presented = false })
        }
    }
}
