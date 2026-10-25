import Foundation

/// Fork: the sidebar's multi-selection, in memory only: ⌘ toggles a row, ⇧ takes the range.
struct ChatSelection: Equatable, Sendable {
    enum Click: Sendable {
        /// Clears the selection; the row opens.
        case plain
        case toggle
        case extend
    }

    private(set) var ids: Set<UUID> = []
    private(set) var anchor: UUID?
    /// Every row the list showed when it was made; once those change, it goes.
    private var contents: Set<UUID> = []

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }
    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    /// `order` is the clicked row's list; a first ⌘ or ⇧ click starts from `open`. True: open it.
    @discardableResult
    mutating func click(
        _ id: UUID, _ click: Click, in order: [UUID], open: UUID? = nil, contents: Set<UUID>
    ) -> Bool {
        guard click != .plain, order.contains(id) else {
            self = ChatSelection()
            return click == .plain
        }
        if !ids.isSubset(of: order) || contents != self.contents {
            ids = []
            anchor = nil
        }
        self.contents = contents
        let start = ids.isEmpty ? open.flatMap { order.contains($0) ? $0 : nil } : nil
        switch click {
        case .toggle:
            if let start, start != id { ids = [start] }
            if ids.remove(id) == nil { ids.insert(id) }
            anchor = id
        case .extend:
            let from = anchor.flatMap { order.contains($0) ? $0 : nil } ?? start ?? id
            anchor = from
            ids = Self.range(from: from, to: id, in: order)
        case .plain:
            break
        }
        return false
    }

    /// ⌘A: every row the list shows.
    mutating func selectAll(_ order: [UUID], contents: Set<UUID>) {
        ids = Set(order)
        anchor = order.first
        self.contents = contents
    }

    mutating func clear() { self = ChatSelection() }

    /// Called as the list changes: a filter, a search or a chat coming or going clears it.
    mutating func reconcile(contents: Set<UUID>) {
        if !ids.isEmpty, contents != self.contents { clear() }
    }

    /// The selected rows in the list's order, so a bulk action and a drag keep what is on screen.
    func ordered(in order: [UUID]) -> [UUID] { order.filter(ids.contains) }

    static func range(from: UUID, to: UUID, in order: [UUID]) -> Set<UUID> {
        guard let start = order.firstIndex(of: from), let end = order.firstIndex(of: to) else { return [to] }
        return Set(order[min(start, end)...max(start, end)])
    }
}
