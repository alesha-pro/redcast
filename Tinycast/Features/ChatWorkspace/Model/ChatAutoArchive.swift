import Foundation

/// Fork: Settings → AI → Chat Window → Archive inactive chats; applied as history loads.
enum ChatAutoArchive: Int, CaseIterable, Identifiable, Sendable {
    case never = 0
    case week = 7
    case month = 30
    case quarter = 90

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .never: String(localized: "auto-archive-never", defaultValue: "Never")
        case .week: String(localized: "After a week")
        case .month: String(localized: "After a month")
        case .quarter: String(localized: "After three months")
        }
    }

    /// Unpinned chats idle past the span; one still open or answering is the caller's to spare.
    func chatsToArchive(
        _ conversations: [ChatConversation], workspace: ChatWorkspace, now: Date, sparing: Set<UUID>
    ) -> [UUID] {
        guard self != .never else { return [] }
        let cutoff = now.addingTimeInterval(-Double(rawValue) * 24 * 60 * 60)
        return conversations.compactMap { chat in
            guard !chat.isPinned, chat.updatedAt < cutoff, !sparing.contains(chat.id),
                !workspace.isArchived(chat.id), !workspace.isTrashed(chat.id)
            else { return nil }
            return chat.id
        }
    }
}

/// Fork: what a tool row's call does, read from its title and origin, for its glyph and colour.
enum ChatToolKind: Equatable, Sendable {
    case web, files, terminal, notes, memory, agent, mcp, other

    static func of(title: String, origin: String) -> ChatToolKind {
        let name = title.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { name.contains($0) } }
        if has(["web", "search", "page", "fetch", "url", "http"]) { return .web }
        if has(["command", "terminal", "shell", "bash", "run_"]) { return .terminal }
        if has(["file", "folder", "directory", "path", "read_", "write", "edit", "list_"]) { return .files }
        if has(["note"]) { return .notes }
        if has(["memory", "remember"]) { return .memory }
        if has(["delegate", "agent", "plan"]) { return .agent }
        return origin.isEmpty ? .other : .mcp
    }

    var symbol: String {
        switch self {
        case .web: "globe"
        case .files: "doc.text"
        case .terminal: "terminal"
        case .notes: "note.text"
        case .memory: "brain"
        case .agent: "person.2"
        case .mcp: "puzzlepiece.extension"
        case .other: "wrench.and.screwdriver"
        }
    }

    /// Web blue, files purple, terminal green, notes yellow, MCP orange.
    var hue: RaycastHue {
        switch self {
        case .web: .blue
        case .files: .purple
        case .terminal: .green
        case .notes: .yellow
        case .memory: .magenta
        case .agent: .red
        case .mcp: .orange
        case .other: .gray
        }
    }
}

/// Fork: a code block's language badge in a colour of its own, as an editor's tab would wear.
enum CodeLanguageHue {
    static func hue(for language: String?) -> RaycastHue {
        switch language?.lowercased() ?? "" {
        case "swift", "rust", "rs", "java", "kotlin", "kt", "html", "xml": .orange
        case "python", "py", "go", "golang", "c", "cpp", "c++", "objc", "objective-c", "css", "scss": .blue
        case "javascript", "js", "jsx", "json", "yaml", "yml", "toml", "ini", "lua": .yellow
        case "typescript", "ts", "tsx", "csharp", "c#", "cs", "php", "sql": .purple
        case "sh", "bash", "zsh", "shell", "console", "dockerfile", "docker", "diff": .green
        case "ruby", "rb", "latex", "tex": .red
        case "": .gray
        default: .magenta
        }
    }
}

/// Fork: each model maker's mark in a colour of its own, matching the CLIs' where they overlap.
enum ChatBrandHue {
    static func hue(forAsset name: String) -> RaycastHue? {
        switch name {
        case "AIBrandClaude", "AIBrandMistral": .orange
        case "AIBrandOpenAI", "AIBrandPerplexity": .green
        case "AIBrandGemini", "AIBrandDeepSeek", "AIBrandMeta", "AIBrandZAI": .blue
        case "AIBrandOpenCode", "AIBrandQwen", "AIBrandOpenRouter": .purple
        case "AIBrandMiniMax": .red
        case "AIBrandKimi": .magenta
        default: nil
        }
    }
}
