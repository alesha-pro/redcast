import SwiftUI

struct WindowSwitchList: View {

    @Environment(\.metrics) private var metrics
    let entries: [WindowSwitchEntry]
    let selectedID: WindowSwitchEntry.ID?
    let scroll: ScrollIntent
    let onActivate: (WindowSwitchEntry) -> Void

    private var firstRowSelected: Bool {
        selectedID != nil && selectedID == entries.first?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        WindowSwitchRow(entry: entry, selected: entry.id == selectedID)
                            .selectionFrame(entry.id == selectedID)
                            .contentShape(Rectangle())
                            .onTapGesture { onActivate(entry) }
                    }
                }
                .padding(.horizontal, metrics.spacing.md)
                .padding(.vertical, metrics.spacing.md)
                .hideNativeScrollers()
                .scrollOriginAnchor()
            }
            .edgeDissolve()
            .thinScrollbar()
            .scrollFollowsSelection(
                scroll, row: selectedID, atOrigin: firstRowSelected, proxy: proxy)
        }
    }
}

private struct WindowSwitchRow: View {

    @Environment(\.metrics) private var metrics
    let entry: WindowSwitchEntry
    let selected: Bool

    private var trailing: String {
        entry.isMinimized ? String(localized: "\(entry.appName) · Minimized") : entry.appName
    }

    var body: some View {
        HStack(spacing: metrics.spacing.lg) {
            Group {
                if let iconURL = entry.iconURL {
                    EntryIconView(source: .file(stamp: entry.iconStamp), fileURL: iconURL)
                } else {
                    EntryIconView(source: .symbol("macwindow"))
                }
            }
            .frame(width: metrics.size.resultRowIcon, height: metrics.size.resultRowIcon)
            .opacity(entry.isMinimized ? Theme.Opacity.minimized : 1)
            Text(entry.displayTitle)
                .font(metrics.typography.rowTitle)
                .foregroundStyle(entry.isMinimized ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: metrics.spacing.md)
            Text(trailing)
                .font(metrics.typography.rowTrailing)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, metrics.spacing.md)
        .padding(.vertical, metrics.spacing.sm)
        .paletteRow(selected: selected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.displayTitle)
        .accessibilityValue(trailing)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
