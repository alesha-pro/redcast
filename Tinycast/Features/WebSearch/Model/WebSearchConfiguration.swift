import Foundation

/// Which engines run and in what order, and where the user's SearXNG is; keys are the Keychain's.
struct WebSearchConfiguration: Equatable, Sendable {
    private(set) var order: [WebSearchSource]
    var enabled: Set<WebSearchSource>
    var searxngAddress: String

    static let standard = WebSearchConfiguration(
        order: WebSearchSource.allCases, enabled: [.exa, .parallel, .duckDuckGo], searxngAddress: "")

    init(order: [WebSearchSource], enabled: Set<WebSearchSource>, searxngAddress: String) {
        var seen = Set<WebSearchSource>()
        let kept = order.filter { seen.insert($0).inserted }
        // An engine a later build added joins at the end, switched off.
        self.order = kept + WebSearchSource.allCases.filter { !seen.contains($0) }
        self.enabled = enabled
        self.searxngAddress = searxngAddress
    }

    var chain: [WebSearchSource] { order.filter(enabled.contains) }

    mutating func move(_ source: WebSearchSource, by offset: Int) {
        guard let from = order.firstIndex(of: source) else { return }
        let to = min(max(from + offset, 0), order.count - 1)
        guard to != from else { return }
        order.remove(at: from)
        order.insert(source, at: to)
    }
}

extension WebSearchConfiguration: Codable {
    private enum CodingKeys: String, CodingKey { case order, enabled, searxngAddress }

    /// Strings, so an engine another build added or dropped never fails the whole value.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let order = (try? container.decode([String].self, forKey: .order)) ?? []
        let enabled = (try? container.decode([String].self, forKey: .enabled)) ?? []
        self.init(
            order: order.compactMap(WebSearchSource.init(rawValue:)),
            enabled: Set(enabled.compactMap(WebSearchSource.init(rawValue:))),
            searxngAddress: (try? container.decode(String.self, forKey: .searxngAddress)) ?? "")
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(order.map(\.rawValue), forKey: .order)
        try container.encode(enabled.map(\.rawValue).sorted(), forKey: .enabled)
        try container.encode(searxngAddress, forKey: .searxngAddress)
    }
}
