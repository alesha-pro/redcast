import Foundation
import Synchronization

/// One turn's web tools in a chat without an agent: `web_search`, and `read_page` in its scope.
nonisolated final class WebChatTools: Sendable {
    /// One part of a page, or a PDF's pages, or the failure the model is told; `web_fetch`'s read.
    typealias Fetch = @Sendable (_ url: URL, _ part: Int, _ pages: String?) async -> (text: String, failed: Bool)

    let search: WebSearchRunner
    private let fetch: Fetch
    /// All `read_page` may judge by, for this turn only.
    private let scope = Mutex(Scope())

    private struct Scope {
        var messages: [AIMessage] = []
        /// Addresses this turn's searches returned and a round has shown the model.
        var shown: [URL] = []
        /// Addresses of searches since the latest round, shown with the next one.
        var found: [URL] = []
        /// Pages read this turn by key; another part of one is not another read.
        var read: Set<String> = []
    }

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
        case WebSearchTool.name: await find(call)
        case WebPageTool.name: await read(call)
        default: nil
        }
    }

    fileprivate func note(_ request: AIRequest) {
        scope.withLock {
            $0.messages = request.messages
            $0.shown += $0.found
            $0.found.removeAll()
        }
    }

    /// The engine's own result addresses; the answer's text, which repeats the query, adds none.
    private func find(_ call: AIToolCall) async -> AIToolResult {
        let (result, found) = await search.run(call)
        let pages = found.compactMap { URL(string: $0.url) }
        scope.withLock { $0.found += pages }
        return result
    }

    private func read(_ call: AIToolCall) async -> AIToolResult {
        guard let asked = WebPageTool.url(in: call.arguments) else {
            return .failure(call.id, WebPageTool.invalidURL)
        }
        let (messages, shown) = scope.withLock { ($0.messages, $0.shown) }
        // The given address is fetched, so no spelling of the model's can carry chat text out.
        guard let url = WebPageScope.page(for: asked, in: messages, shown: shown) else {
            return .failure(call.id, WebPageTool.outOfScope(asked))
        }
        let key = WebPageScope.key(for: url) ?? url.absoluteString
        let counted = scope.withLock { scope in
            guard scope.read.contains(key) || scope.read.count < WebPageTool.maxReads else { return false }
            scope.read.insert(key)
            return true
        }
        guard counted else { return .failure(call.id, WebPageTool.readsUsed) }
        let position = WebPageTool.position(in: JSONValue(data: Data(call.arguments.utf8))?.objectValue ?? [:])
        let page = await fetch(url, position.part, position.pages)
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
