import Foundation

/// Which pages `read_page` may open, and at which address: as the user or a search engine wrote it.
enum WebPageScope {
    /// The address the turn was given for the page `asked` names; the model's spelling never leaves.
    static func page(for asked: URL, in messages: [AIMessage], shown: [URL]) -> URL? {
        key(for: asked).flatMap { given(in: messages, shown: shown)[$0] }
    }

    /// The user's links, then the search results the model was shown, by `key(for:)`; first wins.
    static func given(in messages: [AIMessage], shown: [URL]) -> [String: URL] {
        let typed = links(in: messages.filter { $0.role == .user }.map(\.text).joined(separator: "\n"))
        var pages: [String: URL] = [:]
        for url in typed + shown {
            guard let key = key(for: url), pages[key] == nil else { continue }
            pages[key] = secured(url)
        }
        return pages
    }

    /// What names a page, for the model to pick one by; an address with a user or password names none.
    static func key(for url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
            components.user == nil, components.password == nil,
            var host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let port = components.port.flatMap { [80, 443].contains($0) ? nil : ":\($0)" } ?? ""
        var path = components.path.replacingOccurrences(of: "/{2,}", with: "/", options: .regularExpression)
        if path.hasSuffix("/") { path.removeLast() }
        let query = components.query.flatMap { $0.isEmpty ? nil : "?" + $0 } ?? ""
        return host + port + path + query
    }

    /// Plain HTTP to the open web goes over HTTPS, since ATS refuses it; a local host keeps HTTP.
    static func secured(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http", let host = url.host()?.lowercased(),
            !WebSearchEndpoint.allowsPlainHTTP(to: host),
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.scheme = "https"
        if components.port == 80 { components.port = nil }
        return components.url ?? url
    }

    /// A redirect stays on the open web, or on the local host the read began at.
    static func follows(from start: URL?, to target: URL?) -> Bool {
        guard let target, let components = URLComponents(url: target, resolvingAgainstBaseURL: false),
            ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
            components.user == nil, components.password == nil,
            let host = target.host()?.lowercased(), !host.isEmpty
        else { return false }
        return !isLocal(host) || start?.host()?.lowercased() == host
    }

    /// Loopback, `.local`, one label or an address literal, in any form `inet_aton` reads.
    static func isLocal(_ host: String) -> Bool {
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        let last = name.split(separator: ".").last ?? Substring(name)
        return name.contains(":") || last.allSatisfy { ("0"..."9").contains($0) } || last.hasPrefix("0x")
            || name == "localhost" || name.hasSuffix(".localhost")
            || WebSearchEndpoint.allowsPlainHTTP(to: name)
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
