import Foundation

/// One `web_search` call: the chain's engines in turn until one answers; built per turn, not kept.
nonisolated struct WebSearchRunner: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    let chain: [WebSearchSource]
    let searxng: URL?
    /// The tool this turn reads a page with, `web_fetch` or `read_page`, so the answer can name it.
    let reader: String?
    /// Read at most once per call, and only when a keyed engine's turn comes.
    let keys: @Sendable () -> [String: String]
    var transport: Transport = WebSearchRunner.fetch

    static let maxAttempts = 4
    static let maxResponseBytes = 1_048_576

    func run(_ call: AIToolCall) async -> AIToolResult {
        guard let query = WebSearchTool.parse(call.arguments) else {
            return .failure(call.id, WebSearchTool.missingQuery)
        }
        return await answer(query, callID: call.id)
    }

    func answer(_ query: WebSearchQuery, callID: String) async -> AIToolResult {
        guard !chain.isEmpty else { return .failure(callID, WebSearchTool.noEngines) }
        switch await search(query) {
        case .found(let source, let results):
            return AIToolResult(
                callID: callID,
                content: WebSearchTool.answer(results, for: query, from: source, reader: reader),
                isError: false)
        case .failed(let attempts) where Self.foundNothing(attempts):
            return AIToolResult(callID: callID, content: WebSearchTool.noResults(for: query), isError: false)
        case .failed(let attempts):
            return .failure(callID, WebSearchTool.failure(for: query, attempts: attempts))
        }
    }

    @concurrent
    func search(_ query: WebSearchQuery) async -> WebSearchOutcome {
        var attempts: [WebSearchAttempt] = []
        var loadedKeys: [String: String]?
        var requests = 0
        for source in chain {
            guard !Task.isCancelled, requests < Self.maxAttempts else { break }
            var key: String?
            if source.key != .none {
                let all = loadedKeys ?? keys()
                loadedKeys = all
                key = all[source.rawValue]
            }
            let request: URLRequest
            switch WebSearchEndpoint.request(query, to: source, key: key, searxng: searxng) {
            case .success(let built): request = built
            case .failure(let failure):
                attempts.append(WebSearchAttempt(source: source, failure: failure))
                continue
            }
            requests += 1
            do {
                let (data, status) = try await transport(request)
                switch WebSearchDecoder.results(data, status: status, from: source) {
                case .success(let results):
                    return .found(source, Array(results.prefix(query.count)))
                case .failure(let failure):
                    attempts.append(WebSearchAttempt(source: source, failure: failure))
                }
            } catch {
                if Task.isCancelled { break }
                attempts.append(WebSearchAttempt(source: source, failure: .failed(error.localizedDescription)))
            }
        }
        return .failed(attempts)
    }

    /// Every engine that was asked answered with nothing; one skipped for a missing key asked none.
    private static func foundNothing(_ attempts: [WebSearchAttempt]) -> Bool {
        let asked = attempts.filter { $0.failure != .missingKey && $0.failure != .missingAddress }
        return !asked.isEmpty && asked.allSatisfy { $0.failure == .empty }
    }

    /// No cookie may follow the user between searches, and Exa and Parallel both set one.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()

    static let fetch: Transport = { request in
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= maxResponseBytes { break }
        }
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
