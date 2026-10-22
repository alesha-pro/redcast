import Foundation

/// An agent run by its own CLI over the Agent Client Protocol, on the user's own login.
struct AgentRuntime: Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case claudeCode
        case codex
        case gemini
        case openCode
        case goose
        case hermes
        case custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .claudeCode: "Claude Code"
            case .codex: "Codex"
            case .gemini: "Gemini CLI"
            case .openCode: "OpenCode"
            case .goose: "Goose"
            case .hermes: "Hermes"
            case .custom: String(localized: "Custom ACP command")
            }
        }
    }

    var kind: Kind
    /// A bare name is found the way Terminal would find it; an absolute path is used as written.
    var command: String
    var arguments: [String]

    /// Claude Code and Codex speak ACP through Zed's adapters, fetched by `npx` on first use.
    static func preset(_ kind: Kind) -> Self {
        switch kind {
        case .claudeCode:
            Self(kind: kind, command: "npx", arguments: ["-y", "@agentclientprotocol/claude-agent-acp"])
        case .codex:
            Self(kind: kind, command: "npx", arguments: ["-y", "@agentclientprotocol/codex-acp"])
        case .gemini: Self(kind: kind, command: "gemini", arguments: ["--acp"])
        case .openCode: Self(kind: kind, command: "opencode", arguments: ["acp"])
        case .goose: Self(kind: kind, command: "goose", arguments: ["acp"])
        case .hermes: Self(kind: kind, command: "hermes", arguments: ["acp"])
        case .custom: Self(kind: kind, command: "", arguments: [])
        }
    }

    var commandLine: String {
        ([command] + arguments.map(Self.quoted)).joined(separator: " ")
    }

    /// Splits on spaces, keeping a quoted run whole; enough for an arguments field.
    static func arguments(parsing line: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        for character in line {
            if let open = quote {
                if character == open {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
                hasToken = true
            } else if character == " " || character == "\t" {
                if hasToken { arguments.append(current) }
                current = ""
                hasToken = false
            } else {
                current.append(character)
                hasToken = true
            }
        }
        if hasToken { arguments.append(current) }
        return arguments
    }

    private static func quoted(_ argument: String) -> String {
        argument.contains(" ") || argument.isEmpty ? "\"\(argument)\"" : argument
    }
}
