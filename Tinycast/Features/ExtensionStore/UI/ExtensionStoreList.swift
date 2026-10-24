import SwiftUI

struct ExtensionStoreList: View {
    @Environment(\.metrics) private var metrics
    let rows: [ExtensionStoreRow]
    let selectedID: ExtensionStoreRow.ID?
    let installed: ExtensionStoreInstallState.Installed
    /// Progress per manifest name.
    let installing: [String: String]
    let scroll: ScrollIntent
    let onSelect: (ExtensionStoreRow) -> Void
    let onActivate: (ExtensionStoreRow) -> Void
    let onActions: (ExtensionStoreRow) -> Void

    private enum Item: Identifiable {
        case header(ExtensionStoreSection)
        case row(ExtensionStoreRow)

        var id: String {
            switch self {
            case .header(let section): "header-" + section.key
            case .row(let row): row.id
            }
        }
    }

    /// A header wherever the section changes; headers take no selection index.
    private var items: [Item] {
        var items: [Item] = []
        var section: ExtensionStoreSection?
        for row in rows {
            if row.section != section { items.append(.header(row.section)) }
            section = row.section
            items.append(.row(row))
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
                        case .header(let section):
                            SectionHeader(title: section.title, isFirst: item.id == items.first?.id)
                        case .row(let row):
                            ExtensionStoreRowView(
                                row: row, selected: row.id == selectedID, installed: installed,
                                progress: row.entry.flatMap { installing[$0.name] }
                            )
                            .selectionFrame(row.id == selectedID)
                            .contentShape(Rectangle())
                            .onRightClick { onActions(row) }
                            .onRowClick(select: { onSelect(row) }, activate: { onActivate(row) })
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
            .scrollFollowsSelection(scroll, row: selectedID, atOrigin: firstRowSelected, proxy: proxy)
        }
    }

    /// "12k", the store's own way of counting installs.
    static func downloads(_ count: Int) -> String {
        ExtensionListing.abbreviate(count)
    }

    /// The day only; this year's dates drop the year.
    static func day(_ date: Date) -> String {
        Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

private struct ExtensionStoreRowView: View {
    @Environment(\.metrics) private var metrics
    let row: ExtensionStoreRow
    let selected: Bool
    let installed: ExtensionStoreInstallState.Installed
    let progress: String?
    @State private var hovered = false

    /// Selection wins over hover when a row is both; otherwise hover shows its fainter layer.
    private var fill: Color {
        if selected { return Theme.Colors.selection }
        if hovered { return Theme.Colors.rowHover }
        return .clear
    }

    var body: some View {
        HStack(spacing: metrics.spacing.lg) {
            leading
                .frame(width: metrics.size.resultRowIcon, height: metrics.size.resultRowIcon)
            VStack(alignment: .leading, spacing: metrics.spacing.xxs) {
                Text(verbatim: title)
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
            trailing
        }
        .padding(.horizontal, metrics.spacing.md)
        .padding(.vertical, metrics.spacing.sm)
        .background(RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous).fill(fill))
        .armedHover($hovered)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var leading: some View {
        switch row.item {
        case .entry(let entry):
            ExtensionStoreIcon(entry: entry, side: metrics.size.resultRowIcon)
        case .browse(let browse, _):
            Image(systemName: Self.symbol(of: browse))
                .font(metrics.typography.rowTitle)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
    }

    private var title: String {
        switch row.item {
        case .entry(let entry): entry.title
        case .browse(.category(let name), _): name
        case .browse: String(localized: "Show All")
        }
    }

    /// The author, installs and last update; nothing for a list row, whose count sits on the right.
    private var subtitle: String? {
        guard let entry = row.entry else { return nil }
        var parts = [entry.author]
        if entry.downloads > 0 { parts.append("↓ " + ExtensionStoreList.downloads(entry.downloads)) }
        if let updated = entry.updatedAt { parts.append(ExtensionStoreList.day(updated)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder private var trailing: some View {
        switch row.item {
        case .entry(let entry):
            if let progress {
                HStack(spacing: metrics.spacing.sm) {
                    ProgressView().controlSize(.mini)
                    Text(verbatim: progress)
                }
                .font(metrics.typography.keyCap)
                .foregroundStyle(Theme.Colors.textTertiary)
            } else {
                ExtensionStoreBadge(state: ExtensionStoreInstallState.of(entry, in: installed))
            }
        case .browse(_, let count):
            Text(verbatim: count.formatted())
                .font(metrics.typography.keyCap)
                .foregroundStyle(Theme.Colors.textTertiary)
        }
    }

    static func symbol(of browse: ExtensionStoreBrowse) -> String {
        switch browse {
        case .category: "square.grid.2x2"
        default: "list.bullet"
        }
    }
}

/// Installed or Update, beside a row and in the preview; nothing for an extension not installed.
struct ExtensionStoreBadge: View {
    @Environment(\.metrics) private var metrics
    let state: ExtensionStoreInstallState

    var body: some View {
        switch state {
        case .available:
            EmptyView()
        case .installed:
            badge(String(localized: "Installed"), symbol: "checkmark.circle.fill", tint: Theme.Colors.success)
        case .updateAvailable:
            badge(String(localized: "Update"), symbol: "arrow.down.circle.fill", tint: Theme.Colors.accent)
        }
    }

    private func badge(_ title: String, symbol: String, tint: Color) -> some View {
        Label {
            Text(verbatim: title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(metrics.typography.keyCap)
        .foregroundStyle(Theme.Colors.textSecondary)
        .lineLimit(1)
        .fixedSize()
    }
}
