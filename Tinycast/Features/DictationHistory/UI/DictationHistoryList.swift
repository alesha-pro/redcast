import SwiftUI

struct DictationHistoryList: View {
    @Environment(\.metrics) private var metrics
    let rows: [DictationHistoryEntry]
    let selectedID: DictationHistoryEntry.ID?
    let scroll: ScrollIntent
    let onSelect: (DictationHistoryEntry) -> Void
    let onActivate: (DictationHistoryEntry) -> Void
    let onActions: (DictationHistoryEntry) -> Void

    private enum Item: Identifiable {
        case header(String)
        case entry(DictationHistoryEntry)

        var id: String {
            switch self {
            case .header(let title): "header-" + title
            case .entry(let entry): entry.id.uuidString
            }
        }
    }

    /// Newest first, a header per date bucket, as Clipboard History reads.
    private var items: [Item] {
        var items: [Item] = []
        var bucket: DateBucket?
        for entry in rows {
            let current = DateBucket(for: entry.date)
            if current != bucket { items.append(.header(current.title)) }
            bucket = current
            items.append(.entry(entry))
        }
        return items
    }

    private var firstRowSelected: Bool {
        selectedID != nil && selectedID == rows.first?.id
    }

    var body: some View {
        let items = items
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        switch item {
                        case .header(let title):
                            SectionHeader(title: title, isFirst: item.id == items.first?.id)
                        case .entry(let entry):
                            DictationHistoryRow(entry: entry, selected: entry.id == selectedID)
                                .selectionFrame(entry.id == selectedID)
                                .contentShape(Rectangle())
                                .onRightClick { onActions(entry) }
                                .onRowClick(select: { onSelect(entry) }, activate: { onActivate(entry) })
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

    /// One line of the text, collapsed: a multi-line dictation stays a clean title.
    static func title(of entry: DictationHistoryEntry, limit: Int = 200) -> String {
        let words = entry.text.prefix(limit * 4).split(whereSeparator: \.isWhitespace)
        return String(words.joined(separator: " ").prefix(limit))
    }

    static func symbol(of kind: DictationHistoryEntry.Kind) -> String {
        switch kind {
        case .dictation: "waveform"
        case .ask: CommandID.askByVoice.sfSymbol
        case .edit: CommandID.editByVoice.sfSymbol
        }
    }

    static func kindName(_ kind: DictationHistoryEntry.Kind) -> String {
        switch kind {
        case .dictation: String(localized: "Dictation")
        case .ask: CommandID.askByVoice.name
        case .edit: CommandID.editByVoice.name
        }
    }
}

private struct DictationHistoryRow: View {
    @Environment(\.metrics) private var metrics
    let entry: DictationHistoryEntry
    let selected: Bool
    @State private var hovered = false

    /// Selection wins over hover when a row is both; otherwise hover shows its fainter layer.
    private var fill: Color {
        if selected { return Theme.Colors.selection }
        if hovered { return Theme.Colors.rowHover }
        return .clear
    }

    var body: some View {
        IconCache.observeStyle()
        return HStack(spacing: metrics.spacing.lg) {
            Image(
                nsImage: IconCache.symbolIcon(
                    named: DictationHistoryList.symbol(of: entry.kind), tint: ColorfulIcons.tint(.voice))
            )
            .resizable()
            .frame(width: metrics.size.resultRowIcon, height: metrics.size.resultRowIcon)
            VStack(alignment: .leading, spacing: metrics.spacing.xxs) {
                Text(verbatim: DictationHistoryList.title(of: entry))
                    .font(metrics.typography.rowTitle)
                    .lineLimit(1)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(metrics.typography.keyCap)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Text(verbatim: time)
                .font(metrics.typography.keyCap)
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .padding(.horizontal, metrics.spacing.md)
        .padding(.vertical, metrics.spacing.sm)
        .background(RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous).fill(fill))
        .armedHover($hovered)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// An Ask or an edit says so first; the app and the mode follow.
    private var subtitle: String? {
        let kind = entry.kind == .dictation ? nil : DictationHistoryList.kindName(entry.kind)
        let parts = [kind, entry.appName, entry.mode].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var time: String {
        Calendar.current.isDateInToday(entry.date)
            ? entry.date.formatted(date: .omitted, time: .shortened)
            : entry.date.formatted(.dateTime.month(.abbreviated).day())
    }
}
