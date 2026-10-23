import Foundation

/// The one request each engine takes; pure, so a wrong shape fails a harness, not a turn.
enum WebSearchEndpoint {
    static let userAgent = "Tinycast (+https://github.com/alesha-pro/tinycast)"
    static let exa = URL(string: "https://mcp.exa.ai/mcp")!
    static let parallel = URL(string: "https://search.parallel.ai/mcp")!
    static let duckDuckGo = URL(string: "https://html.duckduckgo.com/html/")!
    static let brave = URL(string: "https://api.search.brave.com/res/v1/web/search")!
    static let tavily = URL(string: "https://api.tavily.com/search")!

    static func request(
        _ query: WebSearchQuery, to source: WebSearchSource, key: String?, searxng: URL?
    ) -> Result<URLRequest, WebSearchFailure> {
        let key = key.flatMap { $0.isEmpty ? nil : $0 }
        switch source {
        case .exa:
            var request = mcp(
                exa, tool: "web_search_exa",
                arguments: ["query": query.text, "objective": objective(query), "numResults": query.count])
            if let key { request.setValue(key, forHTTPHeaderField: "x-api-key") }
            return .success(request)
        case .parallel:
            return .success(
                mcp(
                    parallel, tool: "web_search",
                    arguments: ["objective": objective(query), "search_queries": [query.text]]))
        case .duckDuckGo:
            var request = base(duckDuckGo, method: "POST")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let recency = query.recency.map { [("df", duckDuckGoRange($0))] } ?? []
            request.httpBody = Data(encoded([("q", query.text)] + recency).utf8)
            return .success(request)
        case .searxng:
            guard let searxng else { return .failure(.missingAddress) }
            let recency = query.recency.map { [("time_range", searxngRange($0))] } ?? []
            let items = [("q", query.text), ("format", "json")] + recency
            return .success(base(url(searxng.appending(path: "search"), items), method: "GET"))
        case .brave:
            guard let key else { return .failure(.missingKey) }
            let recency = query.recency.map { [("freshness", "p" + duckDuckGoRange($0))] } ?? []
            let items = [("q", query.text), ("count", String(query.count)), ("text_decorations", "false")]
            var request = base(url(brave, items + recency), method: "GET")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
            return .success(request)
        case .tavily:
            guard let key else { return .failure(.missingKey) }
            var body: [String: Any] = [
                "query": query.text, "max_results": query.count, "search_depth": "basic",
                "include_answer": false
            ]
            body["time_range"] = query.recency?.rawValue
            var request = base(tavily, method: "POST")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            request.httpBody = json(body)
            return .success(request)
        }
    }

    /// HTTPS anywhere; plain HTTP only where App Transport Security allows it with no exception.
    static func searxngURL(_ raw: String) -> Result<URL, WebSearchAddressError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed), let host = parsed.host()?.lowercased(), !host.isEmpty,
            var components = URLComponents(url: parsed, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return .failure(.invalid) }
        if scheme == "http", !allowsPlainHTTP(to: host) {
            return .failure(isIPLiteral(host) ? .ipLiteral : .insecure)
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/search") { path.removeLast("/search".count) }
        components.scheme = scheme
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let base = components.url else { return .failure(.invalid) }
        return .success(base)
    }

    /// What ATS lets plain HTTP reach with no exception: a loopback, `.local` or single-label host.
    static func allowsPlainHTTP(to host: String) -> Bool {
        // Since macOS 14, ATS refuses plain HTTP to an IP address unless the app opts out.
        ["localhost", "127.0.0.1", "::1"].contains(host)
            || (!isIPLiteral(host) && (host.hasSuffix(".local") || !host.contains(".")))
    }

    private static func isIPLiteral(_ host: String) -> Bool {
        host.contains(":") || host.allSatisfy { "0123456789.".contains($0) }
    }

    private static func objective(_ query: WebSearchQuery) -> String {
        guard let recency = query.recency else { return query.text }
        return query.text + " Prefer pages from the past \(recency.rawValue)."
    }

    private static func duckDuckGoRange(_ recency: WebSearchRecency) -> String {
        String(recency.rawValue.prefix(1))
    }

    /// SearXNG documents no week for its JSON API, so a week widens to a month.
    private static func searxngRange(_ recency: WebSearchRecency) -> String {
        recency == .week ? WebSearchRecency.month.rawValue : recency.rawValue
    }

    private static func mcp(_ url: URL, tool: String, arguments: [String: Any]) -> URLRequest {
        var request = base(url, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = json([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": tool, "arguments": arguments]
        ])
        return request
    }

    private static func base(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func url(_ base: URL, _ items: [(String, String)]) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = encoded(items)
        return components?.url ?? base
    }

    /// A form-style decoder reads a literal `+` as a space, which would turn `c++` into `c  `.
    private static func encoded(_ items: [(String, String)]) -> String {
        var components = URLComponents()
        components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
    }

    /// Sorted keys, so a body is the same bytes every time.
    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }
}

enum WebSearchAddressError: Error, Equatable, Sendable {
    case invalid
    case insecure
    case ipLiteral

    var message: String {
        switch self {
        case .invalid: String(localized: "Enter the server's address, like https://search.example.com.")
        case .insecure:
            String(localized: "Use HTTPS, or a name on your network such as llm-server.local.")
        case .ipLiteral:
            String(
                localized: """
                    macOS blocks plain HTTP to an IP address. Use the server's name, like \
                    llm-server.local, or HTTPS.
                    """)
        }
    }
}
