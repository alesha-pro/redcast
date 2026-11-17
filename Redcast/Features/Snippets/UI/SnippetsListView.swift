import SwiftUI

struct SnippetsList: View {

    @Environment(\.metrics) private var metrics
    let results: [StoredSnippet]
    let selectedID: StoredSnippet.ID?
    let scroll: ScrollIntent
    let onSelect: (StoredSnippet) -> Void
    let onActivate: () -> Void
    let onActions: (StoredSnippet) -> Void

    private var firstRowSelected: Bool {
        selectedID != nil && selectedID == results.first?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { record in
                        SnippetRow(record: record, selected: record.id == selectedID)
                            .selectionFrame(record.id == selectedID)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(record) }
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded {
                                    onSelect(record)
                                    onActivate()
                                }
                            )
                            .onRightClick { onActions(record) }
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
                scroll, row: selectedID, atOrigin: firstRowSelected, proxy: proxy)
        }
    }
}

private struct SnippetRow: View {

    @Environment(\.metrics) private var metrics
    @Environment(HotKeyManager.self) private var hotKeys
    let record: StoredSnippet
    let selected: Bool

    var body: some View {
        IconCache.observeStyle()
        return HStack(spacing: metrics.spacing.lg) {
            // Fork: the launcher's snippet tile while Colourful Icons is on.
            Image(nsImage: IconCache.symbolIcon(named: "curlybraces", tint: ColorfulIcons.tint(.snippets)))
                .resizable()
                .frame(width: metrics.size.resultRowIcon, height: metrics.size.resultRowIcon)
            Text(record.snippet.name)
                .font(metrics.typography.rowTitle)
                .lineLimit(1)
            Spacer(minLength: metrics.spacing.lg)
            TagChips(tags: record.snippet.tags)  // Fork: Tags
            if let keyword = record.snippet.keyword, !keyword.isEmpty {
                Text(keyword)
                    .font(metrics.typography.keyCap)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(1)
            }
            if let keycaps = hotKeys.binding(for: .snippet(id: record.id))?.keycaps {
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

struct SnippetPreview: View {
    @Environment(\.metrics) private var metrics
    let record: StoredSnippet?

    var body: some View {
        if let record {
            VStack(alignment: .leading, spacing: 0) {
                // The raw template: expanding here would read the clipboard on every arrow key.
                ScrollView {
                    Text(record.snippet.text)
                        .font(metrics.typography.code)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(metrics.spacing.lg)
                }
                .previewStage(filled: true)
                .padding(.top, metrics.spacing.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                SnippetInfoSection(record: record)
            }
            .padding(.horizontal, metrics.spacing.xl)
        } else {
            Color.clear
        }
    }
}

/// The "Information" block; everything in it is already in memory, so nothing is gathered off-main.
private struct SnippetInfoSection: View {
    @Environment(\.metrics) private var metrics
    @Environment(HotKeyManager.self) private var hotKeys
    let record: StoredSnippet

    private var rows: [PreviewInfoRow] {
        var rows = [PreviewInfoRow(String(localized: "Name"), record.snippet.name)]
        if let keyword = record.snippet.keyword, !keyword.isEmpty {
            rows.append(PreviewInfoRow(String(localized: "Keyword"), keyword))
        }
        if let keycaps = hotKeys.binding(for: .snippet(id: record.id))?.keycaps {
            rows.append(PreviewInfoRow(String(localized: "Shortcut"), keycaps: keycaps))
        }
        rows.append(PreviewInfoRow(String(localized: "File"), record.fileURL.lastPathComponent))
        rows.append(
            PreviewInfoRow(String(localized: "Characters"), record.snippet.text.count.formatted()))
        return rows
    }

    var body: some View {
        PreviewInfoSection(rows: rows)
            .padding(.vertical, metrics.spacing.md)
    }
}
