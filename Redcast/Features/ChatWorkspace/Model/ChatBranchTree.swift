import Foundation

/// Fork: one line of the sidebar: a chat, how deep it sits under its parent and the lines to it.
struct ChatTreeRow: Identifiable, Equatable, Sendable {
    /// One indent column: nothing, the line running past, or the rounded elbow into the last child.
    enum Guide: Equatable, Sendable {
        case blank, line, elbow
    }

    let chat: ChatConversation
    var guides: [Guide] = []
    /// Its branches in this section, folded or not; the disclosure shows only when there are some.
    var branches = 0
    var isFolded = false
    /// Set when the parent lives elsewhere, so the row says where it came from.
    var origin: ChatBranchOrigin?

    var id: UUID { chat.id }
    var depth: Int { guides.count }
}

/// Fork: the chat a branch was made from, as a branch outside its parent's section names it.
struct ChatBranchOrigin: Equatable, Sendable {
    let id: UUID
    let title: String
    /// Recently Deleted's chats are named but not opened.
    let opens: Bool
}

/// Fork: a section's chats as trees of branches; built from the summaries in memory, per change.
enum ChatBranchTree {
    /// Deeper branches line up under the third indent.
    static let indentCap = 3

    /// A root and its branches, less what a fold hides.
    struct Tree: Equatable, Sendable {
        let rows: [ChatTreeRow]
        /// The newest chat in it, which places the tree in the section and in Recent's days.
        let newest: ChatConversation
    }

    /// `chats` come newest first; a chat nests under its parent only when the parent is among them.
    static func trees(
        _ chats: [ChatConversation], parent: (UUID) -> UUID?, isFolded: (UUID) -> Bool,
        origin: (UUID) -> ChatBranchOrigin?
    ) -> [Tree] {
        let index = Dictionary(chats.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let candidate: [Int?] = chats.map { chat in parent(chat.id).flatMap { index[$0] } }
        var up = candidate
        for start in up.indices where up[start] != nil {
            var at = candidate[start]
            var steps = 0
            while let next = at, steps <= chats.count {
                if next == start {
                    up[start] = nil
                    break
                }
                at = candidate[next]
                steps += 1
            }
        }
        var children = [[Int]](repeating: [], count: chats.count)
        for (child, parent) in up.enumerated() {
            if let parent { children[parent].append(child) }
        }
        var newest = Array(chats.indices)
        func rank(_ node: Int) -> Int {
            for child in children[node] { newest[node] = min(newest[node], rank(child)) }
            return newest[node]
        }
        let roots = chats.indices.filter { up[$0] == nil }
        for root in roots { _ = rank(root) }
        for node in children.indices { children[node].sort { newest[$0] < newest[$1] } }

        func elsewhere(_ node: Int) -> ChatBranchOrigin? {
            guard up[node] == nil, let parent = parent(chats[node].id) else { return nil }
            return origin(parent)
        }
        return roots.sorted { newest[$0] < newest[$1] }.map { root in
            var rows: [ChatTreeRow] = []
            func walk(_ node: Int, path: [ChatTreeRow.Guide]) {
                let chat = chats[node]
                let folded = !children[node].isEmpty && isFolded(chat.id)
                rows.append(
                    ChatTreeRow(
                        chat: chat, guides: capped(path), branches: children[node].count, isFolded: folded,
                        origin: elsewhere(node)))
                guard !folded else { return }
                let passing = path.map { $0 == .elbow ? ChatTreeRow.Guide.blank : $0 }
                for (offset, child) in children[node].enumerated() {
                    walk(child, path: passing + [offset == children[node].count - 1 ? .elbow : .line])
                }
            }
            walk(root, path: [])
            return Tree(rows: rows, newest: chats[newest[root]])
        }
    }

    /// Flat, as search lists them, each branch still saying where it came from.
    static func flatRows(_ chats: [ChatConversation], origin: (UUID) -> ChatBranchOrigin?) -> [ChatTreeRow] {
        chats.map { ChatTreeRow(chat: $0, origin: origin($0.id)) }
    }

    /// Past the cap a row keeps the first columns and its own, so it reads as the last level's child.
    static func capped(_ path: [ChatTreeRow.Guide]) -> [ChatTreeRow.Guide] {
        guard path.count > indentCap, let own = path.last else { return path }
        return Array(path.prefix(indentCap - 1)) + [own]
    }
}
