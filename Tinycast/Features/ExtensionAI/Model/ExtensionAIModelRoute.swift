import Foundation

/// Which of the user's API connections answers when an extension names a Raycast model.
enum ExtensionAIModelRoute {
    /// Nil keeps the extension model: no vendor named, already that vendor, or none offered.
    static func selection(
        for requested: String, fallback: AIModelSelection?, offered connections: [AIConnection]
    ) -> AIModelSelection? {
        guard let brand = vendor(of: requested) else { return nil }
        if let fallback, self.brand(of: fallback, among: connections) == brand { return nil }
        let wanted = tokens(of: requested)
        var best: (rank: Rank, selection: AIModelSelection)?
        var position = 0
        for connection in connections {
            for model in connection.models
            where AIBrand.resolve(provider: connection.provider, model: model) == brand {
                position += 1
                let rank = Rank(
                    isVendor: connection.provider.isVendor, name: tokens(of: name(of: model)),
                    wanted: wanted, order: -position)
                if best.map({ $0.rank < rank }) ?? true {
                    best = (rank, .api(connection: connection.id, model: model, effort: nil))
                }
            }
        }
        return best?.selection
    }

    /// The first word is the host (`OpenAI_`, `groq-`) or an old family; Groq or Vercel name none.
    private static func vendor(of requested: String) -> AIBrand? {
        AIBrand.resolve(model: String(requested.prefix { !"_-/".contains($0) }))
    }

    /// The vendor behind a pick: its connection's preset, or the model id a router or CLI names.
    static func brand(of selection: AIModelSelection, among connections: [AIConnection]) -> AIBrand? {
        switch selection {
        case .appleIntelligence: return nil
        case .codex: return .openAI
        case .claude: return .claude
        case .grok: return .x
        case .openCode(let model, _), .cursor(let model, _): return AIBrand.resolve(model: model)
        case .api(let id, let model, _):
            guard let connection = connections.first(where: { $0.id == id }) else {
                return AIBrand.resolve(model: model)
            }
            return AIBrand.resolve(provider: connection.provider, model: model)
        }
    }

    /// Runs of letters or digits, so `Claude_Haiku_4.5` and `claude-haiku-4-5` agree.
    static func tokens(of id: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in id.lowercased() {
            let isWordy = character.isLetter || character.isNumber
            let continues = current.last.map {
                ($0.isLetter && character.isLetter) || ($0.isNumber && character.isNumber)
            }
            if !isWordy || continues == false {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            }
            if isWordy { current.append(character) }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// A router's `vendor/` prefix is the same for every model it lists, so it never decides.
    private static func name(of model: String) -> String {
        model.split(separator: "/").last.map(String.init) ?? model
    }
}

/// A vendor's own preset outranks a router; then the closer name, the shorter one, the earlier one.
private struct Rank: Comparable {
    let isVendor: Bool
    let shared: Int
    let extra: Int
    /// Negative and falling, so an earlier model ranks higher on an otherwise equal footing.
    let order: Int

    init(isVendor: Bool, name: [String], wanted: [String], order: Int) {
        self.isVendor = isVendor
        shared = name.filter(wanted.contains).reduce(0) { $0 + Self.weight(of: $1) }
        extra = name.count { !wanted.contains($0) }
        self.order = order
    }

    /// A tier or family word says more about a model than a version digit or a lone letter.
    static func weight(of token: String) -> Int {
        token.count > 1 && token.allSatisfy(\.isLetter) ? 2 : 1
    }

    static func < (lhs: Rank, rhs: Rank) -> Bool {
        (lhs.isVendor ? 1 : 0, lhs.shared, -lhs.extra, lhs.order)
            < (rhs.isVendor ? 1 : 0, rhs.shared, -rhs.extra, rhs.order)
    }
}

private extension AIProviderKind {
    /// The presets that are one vendor's own API, as opposed to a router or gateway.
    var isVendor: Bool { self == .openAI || self == .anthropic || self == .gemini }
}
