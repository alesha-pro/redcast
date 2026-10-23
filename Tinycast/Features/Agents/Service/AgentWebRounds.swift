import Foundation

/// A turn's route, seen first so its web scope knows each round; see `AgentWebScope.note`.
struct AgentWebRounds: AIProvider {
    let base: any AIProvider
    let scope: AgentWebScope
    /// A sub-agent's question is its parent's brief, written by the model, so its links give none.
    var readsMessages = true

    func stream(_ request: AIRequest) -> AIProviderStream {
        scope.note(request, readingMessages: readsMessages)
        return base.stream(request)
    }
}
