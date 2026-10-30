import AppKit
import SwiftUI

/// Fork: a table, as `List` can't draw a neutral selection; `docs/ui.md` has the reasoning.
struct SettingsSidebarTable: NSViewRepresentable {
    struct Row {
        /// Nil for the gap between two groups: never selectable, and its title is only VoiceOver's.
        let id: AnyHashable?
        let title: String
        var height = Theme.Size.settingsSidebarRow
        var content: (() -> AnyView)?
    }

    let rows: [Row]
    let selection: AnyHashable?
    /// A results list picks its first row on the field's ↓, and re-picks the selected row.
    var isResultsList = false
    var accessibilityLabel: String?
    let onPick: (AnyHashable) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = SidebarTableView()
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.focusRingType = .none
        table.allowsEmptySelection = true
        // A floating gap row would pin itself under the field and turn the soft edge into a line.
        table.floatsGroupRows = false
        table.addTableColumn(NSTableColumn(identifier: .init("row")))
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.action = #selector(Coordinator.rowClicked(_:))

        let scrollView = SidebarScrollView()
        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        context.coordinator.table = table
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(with: self)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopFollowingField()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: SidebarTableView?
        private var parent: SettingsSidebarTable?
        private var rows: [Row] = []
        private var isSyncing = false
        private var pickedByThisClick = false
        private var fieldMonitor: Any?

        func update(with parent: SettingsSidebarTable) {
            self.parent = parent
            guard let table else { return }
            let changed =
                rows.map(\.id) != parent.rows.map(\.id) || rows.map(\.title) != parent.rows.map(\.title)
            if changed {
                rows = parent.rows
                table.reloadData()
            }
            table.setAccessibilityLabel(parent.accessibilityLabel)
            sync(selection: parent.selection, in: table)
            followField()
        }

        private func sync(selection: AnyHashable?, in table: SidebarTableView) {
            let row = selection.flatMap { id in rows.firstIndex { $0.id == id } } ?? -1
            guard row != table.selectedRow else {
                table.placePill(animated: false)
                return
            }
            isSyncing = true
            if row >= 0 {
                table.selectRowIndexes([row], byExtendingSelection: false)
                table.scrollRowToVisible(row)
            } else {
                table.deselectAll(nil)
            }
            isSyncing = false
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            rows[row].height
        }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            rows[row].id == nil
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            rows[row].id != nil
        }

        /// A click on empty space or ⌘-click must not unmark the pane that is still showing.
        func tableView(
            _ tableView: NSTableView,
            selectionIndexesForProposedSelection proposed: IndexSet
        ) -> IndexSet {
            proposed.isEmpty && !isSyncing ? tableView.selectedRowIndexes : proposed
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            rows[row].id == nil ? NSTableRowView() : SidebarRowView()
        }

        func tableView(
            _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
        ) -> NSView? {
            let model = rows[row]
            guard let content = model.content else {
                let gap = NSView()
                gap.setAccessibilityElement(true)
                gap.setAccessibilityRole(.staticText)
                gap.setAccessibilityLabel(model.title)
                return gap
            }
            let host = NSHostingView(rootView: content())
            host.sizingOptions = []
            return host
        }

        func tableView(
            _ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int
        ) -> String? {
            rows[row].id == nil ? nil : rows[row].title
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table else { return }
            table.placePill(animated: true)
            guard !isSyncing, table.selectedRow >= 0, let id = rows[table.selectedRow].id else { return }
            pickedByThisClick = NSApp.currentEvent.map { Self.mouseEvents.contains($0.type) } ?? false
            parent?.onPick(id)
        }

        /// A result re-picked after Esc must scroll its pane again, which no selection change says.
        @objc func rowClicked(_ sender: NSTableView) {
            defer { pickedByThisClick = false }
            guard !pickedByThisClick, parent?.isResultsList == true,
                sender.clickedRow >= 0, let id = rows[sender.clickedRow].id
            else { return }
            parent?.onPick(id)
        }

        /// The field lives in its own hosting view, so no SwiftUI handler ever sees its keys.
        private func followField() {
            guard fieldMonitor == nil else { return }
            fieldMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let table, event.window === table.window,
                    event.modifierFlags.isDisjoint(with: Self.editingModifiers),
                    let editor = table.window?.firstResponder as? NSTextView,
                    editor.isFieldEditor, !editor.hasMarkedText(), isInSidebar(editor, table)
                else { return event }
                switch event.keyCode {
                case Self.downArrow:
                    table.window?.makeFirstResponder(table)
                    if parent?.isResultsList == true, table.numberOfRows > 0 {
                        table.selectRowIndexes([0], byExtendingSelection: false)
                    }
                    return nil
                case Self.escape where parent?.isResultsList != true:
                    table.window?.makeFirstResponder(table)
                    return nil
                default:
                    return event
                }
            }
        }

        /// A pane's field shares the field editor; a long query only ever widens it rightward.
        private func isInSidebar(_ editor: NSView, _ table: NSView) -> Bool {
            editor.convert(editor.bounds, to: nil).minX < table.convert(table.bounds, to: nil).maxX
        }

        func stopFollowingField() {
            if let fieldMonitor { NSEvent.removeMonitor(fieldMonitor) }
            fieldMonitor = nil
        }

        private static let downArrow: UInt16 = 125
        private static let escape: UInt16 = 53
        private static let editingModifiers: NSEvent.ModifierFlags = [.shift, .command, .option, .control]
        private static let mouseEvents: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseUp]
    }
}

/// Keeps the selection in view while the window settles: its final insets arrive after mounting.
private final class SidebarScrollView: NSScrollView {
    private var followsSelection = true

    override func tile() {
        super.tile()
        guard followsSelection, let table = documentView as? NSTableView, table.selectedRow >= 0
        else { return }
        table.scrollRowToVisible(table.selectedRow)
    }

    override func scrollWheel(with event: NSEvent) {
        followsSelection = false
        super.scrollWheel(with: event)
    }
}

/// Holds the one pill that slides between rows, so a stalled pane build can't freeze it.
final class SidebarTableView: NSTableView {
    private let pill = SidebarSelectionPill()

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        pill.isFocused = true
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        pill.isFocused = false
        return resigned
    }

    override func tile() {
        super.tile()
        placePill(animated: false)
    }

    func placePill(animated: Bool) {
        if pill.superview !== self { addSubview(pill, positioned: .below, relativeTo: nil) }
        guard selectedRow >= 0 else {
            pill.isHidden = true
            return
        }
        let target = rect(ofRow: selectedRow).insetBy(
            dx: Theme.Size.settingsSidebarRowInset, dy: 0)
        let wasHidden = pill.isHidden
        pill.isHidden = false
        pill.move(to: target, animated: animated && !wasHidden)
    }
}

private final class SidebarSelectionPill: NSView {
    var isFocused = false {
        didSet { needsDisplay = true }
    }

    override var wantsUpdateLayer: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = Theme.Radius.settingsSidebarSelection
        layer?.borderWidth = 0.5
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func updateLayer() {
        let fill = isFocused ? Theme.Colors.sidebarSelectionFocused : Theme.Colors.sidebarSelection
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor(fill).cgColor
            layer?.borderColor = NSColor(Theme.Colors.sidebarSelectionEdge).cgColor
        }
    }

    /// Core Animation runs this in the render server, so the pane built next can't stutter it.
    func move(to target: NSRect, animated: Bool) {
        let from = layer?.presentation()?.position
        let distance = abs(target.minY - frame.minY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = target
        CATransaction.commit()
        guard animated, distance > 0, let from, let layer,
            Motion.duration(Theme.Duration.sidebarSelection) > 0,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else { return }
        let slide = CASpringAnimation(
            perceptualDuration: Theme.Duration.sidebarSelection, bounce: 0)
        slide.keyPath = "position"
        slide.fromValue = from
        slide.toValue = layer.position
        slide.isRemovedOnCompletion = true
        layer.add(slide, forKey: "slide")
    }
}

/// Only a hover wash: the selection is the table's one pill, not a per-row drawing.
private final class SidebarRowView: NSTableRowView {
    private let wash = CALayer()
    private var tracking: NSTrackingArea?

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        wash.cornerCurve = .continuous
        wash.cornerRadius = Theme.Radius.settingsSidebarSelection
        wash.opacity = 0
        layer?.addSublayer(wash)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wash.frame = bounds.insetBy(dx: Theme.Size.settingsSidebarRowInset, dy: 0)
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
        // A row scrolled out from under a still pointer gets no exit event.
        guard let window, !bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        else { return }
        setWash(visible: false, duration: 0)
    }

    override func mouseEntered(with event: NSEvent) {
        setWash(visible: !isSelected, duration: Motion.duration(Theme.Duration.hover))
    }

    override func mouseExited(with event: NSEvent) {
        setWash(visible: false, duration: Motion.duration(Theme.Duration.hover))
    }

    override var isSelected: Bool {
        didSet { if isSelected { setWash(visible: false, duration: 0) } }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setWash(visible: false, duration: 0)
    }

    private func setWash(visible: Bool, duration: TimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(duration == 0)
        CATransaction.setAnimationDuration(duration)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            wash.backgroundColor = NSColor(Theme.Colors.sidebarHover).cgColor
        }
        wash.opacity = visible ? 1 : 0
        CATransaction.commit()
    }
}
