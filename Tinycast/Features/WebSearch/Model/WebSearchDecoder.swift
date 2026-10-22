import Foundation

/// Each engine's answer as results; a shape it no longer knows is `.unreadable`, never a guess.
enum WebSearchDecoder {
    static let maxURLCharacters = 500

    static func results(
        _ data: Data, status: Int, from source: WebSearchSource
    ) -> Result<[WebSearchResult], WebSearchFailure> {
        switch status {
        case 200: break
        case 429: return .failure(.rateLimited)
        case 202 where source == .duckDuckGo, 403 where source == .duckDuckGo: return .failure(.refused)
        case 401, 403: return .failure(.unauthorized)
        default: return .failure(.status(status))
        }
        let decoded: Result<[WebSearchResult], WebSearchFailure>
        switch source {
        case .exa: decoded = mcp(data).flatMap { readable(exa($0.text)) }
        case .parallel: decoded = mcp(data).flatMap { readable(parallel($0.structured, text: $0.text)) }
        case .duckDuckGo:
            decoded = String(bytes: data, encoding: .utf8).map(duckDuckGo) ?? .failure(.unreadable)
        case .searxng: decoded = readable(searxng(data))
        case .brave: decoded = readable(brave(data))
        case .tavily: decoded = readable(tavily(data))
        }
        return decoded.flatMap { $0.isEmpty ? .failure(.empty) : .success($0) }
    }

    /// An MCP `tools/call` answer, as JSON or as server-sent events: its text and structured data.
    static func mcp(_ data: Data) -> Result<(text: String, structured: JSONValue?), WebSearchFailure> {
        let body = (String(bytes: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let message: [String: JSONValue]?
        if body.hasPrefix("{") {
            message = JSONValue(data: Data(body.utf8))?.objectValue
        } else {
            message = body.split(whereSeparator: \.isNewline).lazy
                .filter { $0.hasPrefix("data:") }
                .compactMap { line in
                    JSONValue(data: Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8))?
                        .objectValue
                }
                .first { $0["result"] != nil || $0["error"] != nil }
        }
        guard let message else { return .failure(.unreadable) }
        if let error = message["error"] {
            return .failure(refusal(error.objectValue?["message"]?.stringValue ?? ""))
        }
        guard let result = message["result"]?.objectValue else { return .failure(.unreadable) }
        let text = (result["content"]?.arrayValue ?? [])
            .compactMap(\.objectValue)
            .filter { $0["type"]?.stringValue == "text" }
            .compactMap { $0["text"]?.stringValue }
            .joined(separator: "\n")
        if result["isError"]?.boolValue == true { return .failure(refusal(text)) }
        let structured = result["structuredContent"]
        guard !text.isEmpty || structured != nil else { return .failure(.unreadable) }
        return .success((text, structured))
    }

    /// `Title:` blocks; a format without them is nil, so it falls through to the next engine.
    static func exa(_ text: String) -> [WebSearchResult]? {
        let found = ("\n" + text).components(separatedBy: "\nTitle: ").dropFirst().compactMap(exaResult)
        return found.isEmpty ? nil : found
    }

    private static func exaResult(_ block: String) -> WebSearchResult? {
        let lines = block.components(separatedBy: "\n")
        var url: String?
        var published: String?
        var body: [String] = []
        for (index, line) in lines.enumerated().dropFirst() {
            if ["Highlights:", "Text:", "Summary:"].contains(line.trimmingCharacters(in: .whitespaces)) {
                body = Array(lines[(index + 1)...])
                break
            }
            if line.hasPrefix("URL: ") { url = String(line.dropFirst(5)) }
            if line.hasPrefix("Published: ") { published = date(String(line.dropFirst(11))) }
        }
        guard let url = url.flatMap(webURL) else { return nil }
        return WebSearchResult(
            title: lines[0], url: url, published: published, excerpt: body.joined(separator: "\n"))
    }

    static func parallel(_ structured: JSONValue?, text: String) -> [WebSearchResult]? {
        guard
            let items = structured?.objectValue?["results"]?.arrayValue
                ?? JSONValue(data: Data(text.utf8))?.objectValue?["results"]?.arrayValue
        else { return nil }
        return items.compactMap(\.objectValue).compactMap { item in
            result(
                item, excerpt: (item["excerpts"]?.arrayValue ?? []).compactMap(\.stringValue)
                    .joined(separator: " … "),
                published: item["publish_date"]?.stringValue)
        }
    }

    static func duckDuckGo(_ html: String) -> Result<[WebSearchResult], WebSearchFailure> {
        if html.contains("anomaly-modal") || html.contains("challenge-form") { return .failure(.refused) }
        let blocks = html.components(separatedBy: "class=\"result results_links").dropFirst()
        return .success(
            blocks.compactMap { block -> WebSearchResult? in
                // The rest of the block's class attribute; an ad says so there.
                guard !block.prefix(while: { $0 != "\"" }).contains("result--ad"),
                    let link = block.firstMatch(
                        of: #/<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>/#.dotMatchesNewlines()),
                    let url = duckDuckGoTarget(String(link.1))
                else { return nil }
                let snippet = block.firstMatch(
                    of: #/class="result__snippet"[^>]*>(.*?)</(?:a|div)>/#.dotMatchesNewlines())
                let published = block.firstMatch(of: #/(\d{4}-\d{2}-\d{2})T\d{2}:\d{2}/#)
                return WebSearchResult(
                    title: plain(String(link.2)), url: url, published: published.map { String($0.1) },
                    excerpt: snippet.map { plain(String($0.1)) } ?? "")
            })
    }

    static func searxng(_ data: Data) -> [WebSearchResult]? {
        guard let items = JSONValue(data: data)?.objectValue?["results"]?.arrayValue else { return nil }
        return items.compactMap(\.objectValue).compactMap { item in
            result(
                item, excerpt: plain(item["content"]?.stringValue ?? ""),
                published: item["publishedDate"]?.stringValue)
        }
    }

    /// No web hits leaves `web` out entirely, which is an empty answer, not a broken one.
    static func brave(_ data: Data) -> [WebSearchResult]? {
        guard let object = JSONValue(data: data)?.objectValue else { return nil }
        guard let web = object["web"] else { return [] }
        guard let items = web.objectValue?["results"]?.arrayValue else { return nil }
        return items.compactMap(\.objectValue).compactMap { item in
            result(
                item, excerpt: plain(item["description"]?.stringValue ?? ""),
                published: item["page_age"]?.stringValue ?? item["age"]?.stringValue)
        }
    }

    static func tavily(_ data: Data) -> [WebSearchResult]? {
        guard let items = JSONValue(data: data)?.objectValue?["results"]?.arrayValue else { return nil }
        return items.compactMap(\.objectValue).compactMap { item in
            result(
                item, excerpt: item["content"]?.stringValue ?? "",
                published: item["published_date"]?.stringValue)
        }
    }

    /// Tags out, named and numeric entities decoded, whitespace runs as one space.
    static func plain(_ html: String) -> String {
        var text = html.replacing(#/<[^>]+>/#, with: " ")
        for (entity, value) in [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'")
        ] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = text.replacing(#/&#(x[0-9a-fA-F]+|[0-9]+);/#) { match in
            let digits = match.1
            let value = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            return value.flatMap { Unicode.Scalar($0) }.map { String(Character($0)) } ?? String(match.0)
        }
        // Last, so an escaped entity such as `&amp;lt;` stays `&lt;` rather than becoming `<`.
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func result(
        _ item: [String: JSONValue], excerpt: String, published: String?
    ) -> WebSearchResult? {
        guard let url = item["url"]?.stringValue.flatMap(webURL) else { return nil }
        return WebSearchResult(
            title: item["title"]?.stringValue ?? "", url: url, published: published.flatMap(date),
            excerpt: excerpt)
    }

    /// `N/A` and blanks are no date; an ISO timestamp keeps its day.
    private static func date(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value != "N/A" else { return nil }
        return value.prefixMatch(of: #/\d{4}-\d{2}-\d{2}/#).map { String($0.0) } ?? String(value.prefix(40))
    }

    /// The target behind an older page's `//duckduckgo.com/l/?uddg=` hop; ads and the rest drop.
    private static func duckDuckGoTarget(_ href: String) -> String? {
        let decoded = href.replacingOccurrences(of: "&amp;", with: "&")
        guard !decoded.contains("duckduckgo.com/y.js") else { return nil }
        let absolute = decoded.hasPrefix("//") ? "https:" + decoded : decoded
        guard absolute.contains("duckduckgo.com/l/") else { return webURL(absolute) }
        return URLComponents(string: absolute)?.queryItems?.first { $0.name == "uddg" }?.value.flatMap(webURL)
    }

    /// Only a page a model can cite or fetch; a cut link would send it to the wrong one.
    private static func webURL(_ raw: String) -> String? {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = URL(string: url)?.scheme?.lowercased()
        guard url.count <= maxURLCharacters, scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private static func readable(_ results: [WebSearchResult]?) -> Result<[WebSearchResult], WebSearchFailure> {
        results.map { .success($0) } ?? .failure(.unreadable)
    }

    private static func refusal(_ message: String) -> WebSearchFailure {
        let lowered = message.lowercased()
        let limited = ["rate limit", "rate-limit", "ratelimit", "too many requests"].contains {
            lowered.contains($0)
        }
        if limited { return .rateLimited }
        return .failed(message.isEmpty ? "an error with no message" : String(message.prefix(160)))
    }
}
