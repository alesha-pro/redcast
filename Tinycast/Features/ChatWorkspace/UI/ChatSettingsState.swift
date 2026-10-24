import Foundation

/// Fork: a glyph the settings sidebar draws: a symbol, a brand mark, or a coloured tile.
enum ChatSettingsIcon: Equatable {
    case symbol(String, RaycastHue?)
    case asset(String, RaycastHue?)
    case tile(String, RaycastHue)
}

/// Fork: one dropdown in the settings sidebar, built from whatever the chat's route offers.
struct ChatSettingsMenu: Identifiable {
    struct Choice: Identifiable {
        let id: String
        let title: String
        var detail: String?
        var icon: ChatSettingsIcon?
        let isOn: Bool
        let select: () -> Void
    }

    struct Group: Identifiable {
        let id: String
        var title: String?
        let choices: [Choice]
    }

    let id: String
    let label: String
    let title: String
    var icon: ChatSettingsIcon?
    var groups: [Group]
    var isEnabled = true
    var help: String?
    /// A trailing row such as Manage Agents…, below a divider.
    var footer: (title: String, run: () -> Void)?
}

/// Fork: what a chat has spent and holds, the context ring's numbers and the chat's running cost.
struct ChatUsageFacts: Equatable {
    var fill: Double = 0
    var contextTokens: Int?
    var contextWindow: Int?
    var inputTokens: Int?
    var cachedTokens: Int?
    var outputTokens: Int?
    var reasoningTokens: Int?
    var lastCost: Double?
    /// Every reply's reported cost added up, nil when no reply reported one.
    var chatCost: Double?
    var chatTokens: Int?
    var sentMessages = 0
    var totalMessages = 0
    var historyBytes = 0
    var budget = 0
}

/// Fork: the right sidebar's whole content for one chat, so it renders the same from fixtures.
struct ChatSettingsState {
    let chatID: UUID
    var isSaved: Bool
    var title: String
    var placeholderTitle: String
    var agent: ChatSettingsMenu?
    var pickers: [ChatSettingsMenu] = []
    var creativity: ChatCreativity?
    /// Only an API route takes a temperature, and Gemini keeps its own.
    var creativityApplies: Bool
    var instructions: String
    var webSearch: Bool?
    var tools: ChatToolsFacts?
    var usage: ChatUsageFacts
    var rename: (String) -> Void = { _ in }
    var setWebSearch: (Bool) -> Void = { _ in }
    var showSettings: () -> Void = {}
}

/// Fork: the chat's MCP servers as the sidebar lists them.
struct ChatToolsFacts {
    struct Server: Identifiable {
        let id: String
        let name: String
        let isOn: Bool
    }

    var takesTools: Bool
    var isEnabled: Bool
    var servers: [Server]
    var setEnabled: (Bool) -> Void = { _ in }
    var toggle: (String) -> Void = { _ in }
    var showSettings: () -> Void = {}
}

/// Fork: where the settings sidebar's facts come from; the app's AI Chat coordinator, or fixtures.
@MainActor
protocol ChatSettingsSource: AnyObject {
    func settingsState(for chat: AIChatState) -> ChatSettingsState
    /// The composer's chip and the window's subtitle: the model, and the agent when there is one.
    func modelSummary(for chat: AIChatState) -> ChatModelSummary
}

/// Fork: the chat's model and agent in a few words, for the composer's chip and the title bar.
struct ChatModelSummary: Equatable {
    var icon: ChatSettingsIcon?
    var model: String
    var agent: ChatAgentChoice?
}
