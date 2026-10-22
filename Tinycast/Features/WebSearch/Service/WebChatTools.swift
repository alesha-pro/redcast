import Foundation
import Synchronization

/// One turn's web tools in a chat without an agent: `web_search`, and `read_page` in its scope.
nonisolated final class WebChatTools: Sendable {
    /// A page's readable text, or the failure the model is told; `web_fetch`'s own read in the app.
    typealias Fetch = @Sendable (URL) async -> (text: String, failed: Bool)

    let search: WebSearchRunner
    private let fetch: Fetch
    /// The latest round's messages, all `read_page` may judge by; they die with the turn.
    private let latest = Mutex<[AIMessage]>([])

    init(search: WebSearchRunner, fetch: @escaping Fetch) {
        self.search = search
        self.fetch = fetch
    }

    static func definitions(origin: String) -> [AITool] {
        [WebSearchTool.definition(origin: origin), WebPageTool.definition(origin: origin)]
    }

    /// The route the loop streams each round through, seen first so the scope is that round's.
    func watching(_ base: any AIProvider) -> any AIProvider {
        RoundWatcher(base: base, tools: self)
    }

    /// Nil for a call that is neither tool, which the caller routes on.
    func run(_ call: AIToolCall) async -> AIToolResult? {
        switch call.name {
        case WebSearchTool.name: await search.run(call)
        case WebPageTool.name: await read(call)
        default: nil
        }
    }

    fileprivate func note(_ request: AIRequest) {
        latest.withLock { $0 = request.messages }
    }

    private func read(_ call: AIToolCall) async -> AIToolResult {
        guard let url = WebPageTool.url(in: call.arguments) else {
            return .failure(call.id, WebPageTool.invalidURL)
        }
        let messages = latest.withLock { $0 }
        guard WebPageScope.allows(url, in: messages) else {
            return .failure(call.id, WebPageTool.outOfScope(url))
        }
        let page = await fetch(url)
        guard !page.failed else { return .failure(call.id, page.text) }
        return AIToolResult(
            callID: call.id, content: WebPageTool.answer(page.text, from: url), isError: false)
    }
}

private struct RoundWatcher: AIProvider {
    let base: any AIProvider
    let tools: WebChatTools

    func stream(_ request: AIRequest) -> AIProviderStream {
        tools.note(request)
        return base.stream(request)
    }
}
