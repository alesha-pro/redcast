import Foundation

enum AgentSource: String, Codable, Sendable, CaseIterable {
    case claude, codex, gemini
    case openCode = "opencode"
    case tinycast

    /// Product names, never translated.
    var productName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .openCode: "OpenCode"
        case .tinycast: "Tinycast"
        }
    }
}

/// Where a session ran; decides Open in App, HUDs and the Automated filter.
enum AgentSessionHost: String, Codable, Sendable {
    case terminal, claudeApp, codexApp, editor, automated, tinycast
}

enum AgentSessionTitleOrigin: String, Codable, Sendable { case named, generated, prompt, untitled }

struct AgentSession: Identifiable, Equatable, Sendable {
    let source: AgentSource
    let sessionID: String
    var id: String { source.rawValue + ":" + sessionID }
    var title: String
    var titleOrigin: AgentSessionTitleOrigin
    var firstPrompt: String
    var lastPrompt: String
    var directory: String?
    var branch: String?
    var createdAt: Date
    var updatedAt: Date
    var host: AgentSessionHost
    var transcriptPath: String?
    var isArchived: Bool
    /// The agent a Tinycast chat is bound to, shown in its subtitle.
    var agentName: String?
    var isAutomated: Bool { host == .automated }

    init(
        source: AgentSource, sessionID: String, title: String,
        titleOrigin: AgentSessionTitleOrigin, firstPrompt: String = "", lastPrompt: String = "",
        directory: String? = nil, branch: String? = nil, createdAt: Date, updatedAt: Date,
        host: AgentSessionHost, transcriptPath: String? = nil, isArchived: Bool = false,
        agentName: String? = nil
    ) {
        self.source = source
        self.sessionID = sessionID
        self.title = title
        self.titleOrigin = titleOrigin
        self.firstPrompt = firstPrompt
        self.lastPrompt = lastPrompt
        self.directory = directory
        self.branch = branch
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.host = host
        self.transcriptPath = transcriptPath
        self.isArchived = isArchived
        self.agentName = agentName
    }

    /// The folder's own name, which is what a person calls a project.
    var folderName: String? {
        guard let directory, !directory.isEmpty else { return nil }
        let name = (directory as NSString).lastPathComponent
        return name.isEmpty ? directory : name
    }
}

struct SessionTurn: Equatable, Sendable {
    enum Role: Sendable { case user, assistant }
    let role: Role
    /// At most `AgentSessionText.turnLimit` bytes, cut on a scalar boundary with "…".
    let text: String
    let date: Date?
}

enum AgentLiveStatus: Equatable, Sendable {
    case working, waiting(reason: String?), idle, finished, failed, ended

    /// Worth a row in Live and a chip; an ended session is history again.
    var isLive: Bool { self != .ended }

    /// Live order: waiting first, then working, then the rest.
    var rank: Int {
        switch self {
        case .waiting: 0
        case .working: 1
        case .failed: 2
        case .finished: 3
        case .idle: 4
        case .ended: 5
        }
    }
}

struct AgentLiveEntry: Equatable, Sendable {
    let sessionID: String
    let status: AgentLiveStatus
    let pid: Int32?
    /// `claude attach` short id.
    let backgroundID: String?
    let directory: String?
    var startedAt: Date?
    /// Resolved from `pid` off-main, so a row never walks processes while it renders.
    var hostBundleID: String?
    var tty: String?
}

/// The one way prompts, titles and previews are cut, so every source reads alike.
enum AgentSessionText {
    static let promptLimit = 300
    static let titleLimit = 120
    static let promptTitleLimit = 80
    static let turnLimit = 4 * 1_024

    /// Whitespace collapsed to single spaces, then cut to `limit` characters.
    static func oneLine(_ text: String, limit: Int = promptLimit) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }

    /// A prompt as a title: one line, cut back to a word boundary when it runs long.
    static func promptTitle(_ text: String, limit: Int = promptTitleLimit) -> String {
        let line = oneLine(text, limit: .max)
        guard line.count > limit else { return line }
        let head = line.prefix(limit - 1)
        guard let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) > limit / 2
        else { return String(head) + "…" }
        return String(head[..<space]) + "…"
    }

    /// A JSON value that is a string with something other than whitespace in it.
    static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }

    /// Cut to `bytes` of UTF-8 on a scalar boundary, so a preview never splits a character.
    static func bounded(_ text: String, bytes: Int = turnLimit) -> String {
        guard text.utf8.count > bytes else { return text }
        var used = 0
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let size = String(scalar).utf8.count
            guard used + size <= bytes - 3 else { break }
            used += size
            scalars.append(scalar)
        }
        return String(scalars) + "…"
    }
}
