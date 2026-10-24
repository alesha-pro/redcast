import Foundation

/// Fork: what the workspace asks of the app, so its views render from fixtures in a harness too.
@MainActor
protocol ChatWorkspaceHost: AnyObject {
    func openChat(id: UUID)
    func closeWindow()
    /// A new window chat, already bound to the agent when one is named.
    func newChat(agentID: UUID?)
    func copyChat(id: UUID)
    func exportChat(id: UUID)
    /// Upstream's delete, asked first.
    func deleteChat(id: UUID) async
    func confirm(title: String, message: String, symbol: String, confirmTitle: String) async -> Bool
    func showMessage(_ message: String)
    /// A chat deleted for good: its agent's notes and any CLI thread go with it.
    func forgetChat(id: UUID)
    var agentChoices: [ChatAgentChoice] { get }
    func agentID(ofChat id: UUID) -> UUID?
    func bindAgent(_ id: UUID?, toChat chat: UUID)
}

/// Fork: an agent as the workspace shows it, on its own coloured tile.
struct ChatAgentChoice: Identifiable, Equatable {
    let id: UUID
    let name: String
    let symbol: String
    let hue: RaycastHue
}
