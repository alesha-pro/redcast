import Foundation

/// Which pages `read_page` may open: an address the turn was handed, never one the model wrote.
enum WebPageScope {
    /// Whether a user message, or one of this turn's `web_search` answers, names `url`.
    static func allows(_ url: URL, in messages: [AIMessage]) -> Bool {
        guard let key = key(for: url) else { return false }
        return given(in: messages).contains(key)
    }

    /// The pages the turn was handed, as `key(for:)`; a page read and a reply add none.
    static func given(in messages: [AIMessage]) -> Set<String> {
        let searches = Set(messages.flatMap(\.toolCalls).filter { $0.name == WebSearchTool.name }.map(\.id))
        let texts = messages.compactMap { message -> String? in
            switch message.role {
            case .user: message.text
            case .tool: message.toolResult.flatMap { searches.contains($0.callID) ? $0.content : nil }
            case .system, .assistant: nil
            }
        }
        return Set(links(in: texts.joined(separator: "\n")).compactMap(key(for:)))
    }

    /// What names a page; scheme, case, `www.`, doubled slashes or an escape can carry nothing.
    static func key(for url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
            var host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let port = components.port.flatMap { [80, 443].contains($0) ? nil : ":\($0)" } ?? ""
        var path = components.path.replacingOccurrences(of: "/{2,}", with: "/", options: .regularExpression)
        if path.hasSuffix("/") { path.removeLast() }
        let query = components.query.flatMap { $0.isEmpty ? nil : "?" + $0 } ?? ""
        return host + port + path + query
    }

    /// Links as a reader sees them, a bare domain included; only http and https count.
    static func links(in text: String) -> [URL] {
        guard !text.isEmpty,
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap(\.url)
            .filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    }
}
