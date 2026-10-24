import Foundation

/// The fork's sections of a `.tinycast`, beside upstream's categories, each under `full/`.
enum FullBackupSection: String, CaseIterable, Codable, Identifiable, Sendable {
    case agents
    case mcpServers
    case ai
    case voice
    case quickActions
    case extensions
    case more
    case chatHistory

    var id: Self { self }

    /// Bumped when a section's payload changes shape; a reader skips a version it doesn't know.
    var version: Int { 1 }

    struct Descriptor: Sendable {
        let label: String
        let symbol: String
        /// Replace removes what the file lacks; sections without it always merge or overwrite.
        let replaces: Bool
        let exportsByDefault: Bool
    }

    var descriptor: Descriptor {
        switch self {
        case .agents:
            return .init(
                label: String(localized: "Agents"), symbol: "person.crop.circle", replaces: true,
                exportsByDefault: true)
        case .mcpServers:
            return .init(
                label: String(localized: "MCP Servers"), symbol: "server.rack", replaces: true,
                exportsByDefault: true)
        case .ai:
            return .init(
                label: String(localized: "AI Connections"), symbol: "sparkles", replaces: true,
                exportsByDefault: true)
        case .voice:
            return .init(
                label: String(localized: "Voice & Dictation"), symbol: "waveform", replaces: false,
                exportsByDefault: true)
        case .quickActions:
            return .init(
                label: String(localized: "Quick Actions"), symbol: "wand.and.stars", replaces: true,
                exportsByDefault: true)
        case .extensions:
            return .init(
                label: String(localized: "Extensions"), symbol: "puzzlepiece.extension",
                replaces: false, exportsByDefault: true)
        case .more:
            return .init(
                label: String(localized: "More Shortcuts & Settings"), symbol: "command",
                replaces: false, exportsByDefault: true)
        case .chatHistory:
            return .init(
                label: String(localized: "AI Chat History"), symbol: "bubble.left.and.bubble.right",
                replaces: false, exportsByDefault: false)
        }
    }

    static var exportedByDefault: Set<FullBackupSection> {
        Set(allCases.filter(\.descriptor.exportsByDefault))
    }

    static func ordered(_ selection: Set<FullBackupSection>) -> [FullBackupSection] {
        allCases.filter(selection.contains)
    }
}

enum FullBackupImportMode: String, CaseIterable, Identifiable, Sendable {
    case merge
    case replace

    var id: Self { self }

    var title: String {
        switch self {
        case .merge: return String(localized: "Merge")
        case .replace: return String(localized: "Replace")
        }
    }
}
