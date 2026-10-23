import Foundation

/// The parent turn's route, seen first so its web scope knows each round's messages.
struct AgentWebRounds: AIProvider {
    let base: any AIProvider
    let scope: AgentWebScope

    func stream(_ request: AIRequest) -> AIProviderStream {
        scope.note(request)
        return base.stream(request)
    }
}
