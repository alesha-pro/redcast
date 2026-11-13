import AppKit
import SwiftUI

/// The Shortcuts list as a table in one `Form` row: every row listed, a screenful of them built.
struct ShortcutsOverviewTable: NSViewRepresentable {
    let rows: [ShortcutsInventory.Row]
    let issues: [String: [ShortcutIssue]]
    let aliases: AliasStore
    let hotKeys: HotKeyManager
    /// The open recorder's bounds in this view's space; nil while nothing is recording.
    @Binding var recorderFrame: CGRect?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let table = HostedRowsTableView()
        table.headerView = nil
        table.style = .plain
        table.rowHeight = LauncherItemsTable.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.focusRingType = .none
        table.refusesFirstResponder = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("shortcut"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.table = table
        let container = OverhangingTableView(
            table: table,
            topOverhang: LauncherItemsTable.tableOverhang + LauncherItemsTable.searchDividerHeight,
            bottomOverhang: LauncherItemsTable.tableOverhang)
        context.coordinator.container = container
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.show(self)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        let height = CGFloat(rows.count) * LauncherItemsTable.rowHeight
        return CGSize(
            width: proposal.width ?? nsView.frame.width,
            height: height - 2 * LauncherItemsTable.tableOverhang - LauncherItemsTable.searchDividerHeight)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        fileprivate weak var table: NSTableView?
        fileprivate weak var container: NSView?
        private var list: ShortcutsOverviewTable?
        private var shownIDs: [String] = []
        private weak var recorderOwner: ShortcutCellView?

        fileprivate func show(_ list: ShortcutsOverviewTable) {
            self.list = list
            guard let table else { return }
            let ids = list.rows.map(\.id)
            guard ids == shownIDs else {
                shownIDs = ids
                table.reloadData()
                return
            }
            // Same rows: refresh the visible cells in place, so a focused alias keeps its editor.
            let visible = table.rows(in: table.visibleRect)
            for row in visible.location..<visible.location + visible.length {
                let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                (cell as? ShortcutCellView)?.show(content(for: row, of: list))
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            list?.rows.count ?? 0
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let list else { return nil }
            let content = content(for: row, of: list)
            let reused = tableView.makeView(withIdentifier: ShortcutCellView.reuseID, owner: nil)
            let cell = reused as? ShortcutCellView ?? ShortcutCellView(content)
            cell.coordinator = self
            cell.show(content)
            return cell
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        fileprivate func recorderMoved(to frame: CGRect?, in cell: ShortcutCellView) {
            if let frame {
                recorderOwner = cell
                publish(frame)
            } else if recorderOwner === cell {
                recorderOwner = nil
                publish(nil)
            }
        }

        private func publish(_ frame: CGRect?) {
            guard let list, list.recorderFrame != frame else { return }
            list.recorderFrame = frame
        }

        private func content(for row: Int, of list: ShortcutsOverviewTable) -> ShortcutCell {
            let model = list.rows[row]
            return ShortcutCell(
                row: model, issues: list.issues[model.id] ?? [], showsDivider: row > 0,
                aliases: list.aliases, hotKeys: list.hotKeys)
        }
    }
}

/// A reused row: its hosted alias field and recorder survive, and only the entry changes hands.
private final class ShortcutCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("shortcutCell")
    weak var coordinator: ShortcutsOverviewTable.Coordinator?
    private let host: NSHostingView<ShortcutCell>

    init(_ content: ShortcutCell) {
        host = NSHostingView(rootView: content)
        super.init(frame: .zero)
        identifier = Self.reuseID
        // The table fixes the row height; a hosting view left to size itself would fight it.
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ content: ShortcutCell) {
        var content = content
        content.onRecorderFrame = { [weak self] frame in self?.recorderMoved(to: frame) }
        host.rootView = content
    }

    private func recorderMoved(to frame: CGRect?) {
        guard let coordinator, let container = coordinator.container else { return }
        coordinator.recorderMoved(to: frame.map { host.convert($0, to: container) }, in: self)
    }
}

/// What a cell hosts: the row, plus the hairline and environment a `Form` row would hand it.
private struct ShortcutCell: View {
    let row: ShortcutsInventory.Row
    let issues: [ShortcutIssue]
    let showsDivider: Bool
    let aliases: AliasStore
    let hotKeys: HotKeyManager
    var onRecorderFrame: @MainActor (CGRect?) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(showsDivider ? 1 : 0)
            ShortcutOverviewRow(row: row, issues: issues)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The recorder's anchor can't leave this hosting view; its bounds go out by hand.
        .overlayPreferenceValue(ShortcutRecorderAnchorKey.self) { anchor in
            GeometryReader { proxy in
                Color.clear.onChange(of: anchor.map { proxy[$0] }, initial: true) { _, frame in
                    onRecorderFrame(frame)
                }
            }
        }
        .environment(aliases)
        .environment(hotKeys)
        .motionScope()
    }
}

/// The columns every row below it keeps: name, kind, alias and hotkey, on the row's own widths.
struct ShortcutsColumnHeader: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Text("Name")
                .padding(.leading, SettingsListMetrics.iconSize + Theme.Spacing.lg)
            Spacer(minLength: Theme.Spacing.lg)
            Text("Kind")
                .frame(width: Theme.Size.shortcutsKindColumn, alignment: .trailing)
            fieldTitle("Alias")
            fieldTitle("Hotkey")
        }
        .font(Theme.Typography.sectionHeader)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// Inset as the field under it insets its text, so the title starts where the alias does.
    private func fieldTitle(_ title: LocalizedStringResource) -> some View {
        Text(title)
            .padding(.leading, Theme.Spacing.sm + 1)
            .frame(width: Theme.Size.shortcutRecorder, alignment: .leading)
    }
}

/// Icon, name, kind, alias and hotkey; the field and recorder are the ones every pane uses.
private struct ShortcutOverviewRow: View {
    let row: ShortcutsInventory.Row
    let issues: [ShortcutIssue]

    private var subtitle: String? {
        if !issues.isEmpty { return issues.map(\.text).joined(separator: " · ") }
        return row.entry.keyword.map { String(localized: "Keyword: \($0)") }
    }

    var body: some View {
        SettingsRow(
            title: row.entry.name, subtitle: subtitle,
            labelOpacity: row.entry.isDisabled ? Theme.Opacity.disabled : 1
        ) {
            icon
        } trailing: {
            if !issues.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Colors.warning)
                    .help(subtitle ?? "")
                    .accessibilityLabel(subtitle ?? "")
            }
            Text(row.entry.kindLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Theme.Size.shortcutsKindColumn, alignment: .trailing)
            if let key = row.entry.aliasKey {
                AliasField(key: key, name: row.entry.name)
            } else {
                column
            }
            if let action = row.action {
                ShortcutRecorder(action: action)
            } else {
                column
            }
        }
    }

    /// An empty cell at a field's size, so a row with no alias or hotkey keeps its columns.
    private var column: some View {
        Color.clear.frame(
            width: Theme.Size.shortcutRecorder, height: Theme.Size.settingsInlineControl)
    }

    @ViewBuilder
    private var icon: some View {
        if let app = row.app {
            AppIconView(app: app)
                .frame(width: SettingsListMetrics.iconSize, height: SettingsListMetrics.iconSize)
                .id(app.iconKey)
        } else {
            Image(systemName: row.symbol ?? "command")
                .foregroundStyle(.secondary)
                .frame(width: SettingsListMetrics.iconSize, height: SettingsListMetrics.iconSize)
        }
    }
}
