import AppKit
import SwiftUI

/// Fork: hosted by `settingsPickerPanel`, which dismisses it; the name is upstream's.
struct AppPickerPopover: View {
    /// Bundle IDs to leave out — the ones already chosen.
    var excluded: Set<String> = []
    let onSelect: (String) -> Void

    @Environment(AppIndex.self) private var appIndex
    @State private var query = ""

    private var candidates: [AppEntry] {
        (query.isEmpty ? appIndex.apps : appIndex.matches(query))
            .filter { $0.kind == .application }
            .filter { $0.bundleID.map { !excluded.contains($0) } ?? false }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search apps…", text: $query)
                .settingsEditorTextField()
                .padding(Theme.Spacing.md)
            ScrollView {
                LazyVStack(spacing: Theme.Spacing.xxs) {
                    ForEach(candidates) { app in
                        row(title: app.name, icon: app.icon) {
                            if let id = app.bundleID { onSelect(id) }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.bottom, Theme.Spacing.md)
            }
            .overflowFade(includingTop: true)
        }
        .frame(width: Theme.Size.settingsAppPicker.width, height: Theme.Size.settingsAppPicker.height)
        .settingsEditorPanelSurface()
    }

    private func row(title: String, icon: NSImage, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.lg) {
                Image(nsImage: icon).resizable()
                    .frame(width: Theme.Size.settingsRowIcon, height: Theme.Size.settingsRowIcon)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.sm)
        }
        .settingsControl(.pickerRow(isSelected: false))
    }
}

/// Bundle ID → something showable: the index, then LaunchServices, then a placeholder.
@MainActor
enum AppPresentation {
    static func resolve(bundleID: String, in appIndex: AppIndex) -> (name: String, icon: NSImage) {
        IconCache.observeStyle()
        if let app = appIndex.apps.first(where: { $0.bundleID == bundleID }) {
            return (app.name, app.icon)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return (url.deletingPathExtension().lastPathComponent, IconCache.icon(forFile: url.path))
        }
        return (bundleID, NSWorkspace.shared.icon(for: .applicationBundle))
    }
}
