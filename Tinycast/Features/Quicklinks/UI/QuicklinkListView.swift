import AppKit
import SwiftUI

struct QuicklinkList: View {
    @Environment(\.metrics) private var metrics
    let results: [Quicklink]
    let selectedID: Quicklink.ID?
    /// Changes only when the list should scroll, so mouse selection never yanks the position.
    let scroll: ScrollIntent
    let onSelect: (Quicklink) -> Void
    let onActivate: () -> Void
    let onActions: (Quicklink) -> Void

    private enum Row: Identifiable {
        case header(String)
        case item(Quicklink)
        var id: String {
            switch self {
            case .header(let title): return "header-" + title
            case .item(let quicklink): return quicklink.id.uuidString
            }
        }
    }

    /// Whether the selection sits on flat index 0, whose section header should stay visible.
    private var firstRowSelected: Bool {
        selectedID != nil && selectedID == results.first?.id
    }

    /// The store publishes pinned-first, so this emits a header on the one boundary.
    private var rows: [Row] {
        var rows: [Row] = []
        var currentTitle: String?
        for quicklink in results {
            let title = quicklink.isPinned ? String(localized: "Pinned") : String(localized: "Quicklinks")
            if title != currentTitle {
                rows.append(.header(title))
                currentTitle = title
            }
            rows.append(.item(quicklink))
        }
        return rows
    }

    var body: some View {
        let rows = rows
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        switch row {
                        case .header(let title):
                            SectionHeader(title: title, isFirst: row.id == rows.first?.id)
                        case .item(let quicklink):
                            QuicklinkRow(
                                quicklink: quicklink, selected: quicklink.id == selectedID
                            )
                            .selectionFrame(quicklink.id == selectedID)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(quicklink) }
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded {
                                    onSelect(quicklink)
                                    onActivate()
                                }
                            )
                            .onRightClick { onActions(quicklink) }
                        }
                    }
                }
                .padding(.horizontal, metrics.spacing.md)
                .padding(.top, metrics.spacing.xs)
                .padding(.bottom, metrics.spacing.md)
                .hideNativeScrollers()
                .scrollOriginAnchor()
            }
            .edgeDissolve()
            .thinScrollbar()
            .scrollFollowsSelection(
                scroll, row: selectedID?.uuidString, atOrigin: firstRowSelected, proxy: proxy)
        }
    }
}

private struct QuicklinkRow: View {

    @Environment(\.metrics) private var metrics
    let quicklink: Quicklink
    let selected: Bool
    @Environment(HotKeyManager.self) private var hotKeys

    var body: some View {
        IconCache.observeStyle()
        return HStack(spacing: metrics.spacing.lg) {
            // Fork: the launcher's quicklink tile while Colourful Icons is on.
            Image(
                nsImage: IconCache.symbolIcon(named: quicklink.symbol, tint: ColorfulIcons.tint(.quicklinks)))
                .resizable()
                .frame(width: metrics.size.resultRowIcon, height: metrics.size.resultRowIcon)
            VStack(alignment: .leading, spacing: metrics.spacing.xxs) {
                Text(quicklink.name)
                    .font(metrics.typography.rowTitle)
                    .lineLimit(1)
                Text(quicklink.link)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: metrics.spacing.lg)
            TagChips(tags: quicklink.tags)  // Fork: Tags
            if !quicklink.showsInRootSearch {
                Image(systemName: "eye.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            if let keycaps = hotKeys.binding(for: .quicklink(id: quicklink.id))?.keycaps {
                HStack(spacing: metrics.spacing.xxs) {
                    ForEach(Array(keycaps.enumerated()), id: \.offset) { _, cap in
                        KeyCapChip(text: cap, style: .outline)
                    }
                }
            }
        }
        .padding(.horizontal, metrics.spacing.md)
        .padding(.vertical, metrics.spacing.sm)
        .paletteRow(selected: selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

struct QuicklinkPreview: View {
    @Environment(\.metrics) private var metrics
    let quicklink: Quicklink?

    var body: some View {
        if let quicklink {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                SymbolImage(name: quicklink.symbol, size: Self.glyphSize)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, metrics.spacing.xl)
                Spacer(minLength: 0)
                QuicklinkInfoSection(quicklink: quicklink)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, metrics.spacing.xl)
        } else {
            Color.clear
        }
    }

    /// Large enough to read as artwork, not as an oversized row icon.
    private static let glyphSize: CGFloat = 64
}

/// The "Information" block; everything in it is already in memory, so nothing is gathered off-main.
private struct QuicklinkInfoSection: View {
    @Environment(\.metrics) private var metrics
    let quicklink: Quicklink
    @Environment(HotKeyManager.self) private var hotKeys
    @Environment(AppIndex.self) private var appIndex

    /// Relative day plus exact time; shared, `DateFormatter` being expensive to build.
    @MainActor private static let createdFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private var rows: [PreviewInfoRow] {
        var rows = [
            PreviewInfoRow(String(localized: "Name"), quicklink.name),
            PreviewInfoRow(String(localized: "Link"), quicklink.link)
        ]
        if let bundleID = quicklink.openWithBundleID {
            rows.append(
                PreviewInfoRow(
                    String(localized: "Open With"),
                    AppPresentation.resolve(bundleID: bundleID, in: appIndex).name))
        }
        if let keycaps = hotKeys.binding(for: .quicklink(id: quicklink.id))?.keycaps {
            rows.append(PreviewInfoRow(String(localized: "Shortcut"), keycaps: keycaps))
        }
        rows.append(
            PreviewInfoRow(
                String(localized: "Created"), Self.createdFormatter.string(from: quicklink.createdAt)))
        return rows
    }

    var body: some View {
        PreviewInfoSection(rows: rows)
            .padding(.vertical, metrics.spacing.md)
    }
}
