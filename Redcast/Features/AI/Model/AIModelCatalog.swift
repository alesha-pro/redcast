import Foundation

/// Fork: what a chat's route says about money and room, read off models.dev's published catalog.
struct AIRouteFacts: Equatable, Sendable {
    enum Billing: Equatable, Sendable {
        case perToken
        /// A plan or this Mac pays, so a token has no price worth showing.
        case unbilled
        /// A CLI that prices its own replies; it says nothing when it has nothing to say.
        case ownReport
        /// Unknown to the catalog, or sharing its address with a plan: never guessed at.
        case undetermined
    }

    var billing: Billing
    var window: Int?
    /// Only for a route billed per token that does not bill its own replies.
    var rates: AIModelRates?
}

enum AIModelCatalog {
    private struct Route {
        let id: String
        let isPlan: Bool
        let key: String
    }

    private struct Entry {
        let window: Int?
        let rates: AIModelRates?
    }

    private struct Tables {
        let routes: [Route]
        let models: [String: [String: Entry]]
    }

    private static let tables = parse(routes: AIModelCatalogData.routes, models: AIModelCatalogData.models)

    static func facts(for selection: AIModelSelection?, connection: AIConnection?) -> AIRouteFacts {
        switch selection {
        case .api(_, let model, _):
            guard let connection else { return AIRouteFacts(billing: .undetermined) }
            return facts(for: model, on: connection)
        case .grok(let model, _):
            return AIRouteFacts(billing: .ownReport, window: tables.models["xai"]?[model]?.window)
        case .openCode(let model, _):
            // OpenCode names a model `provider/model`, and its providers are this catalog's.
            let parts = model.split(separator: "/", maxSplits: 1).map(String.init)
            let window = parts.count == 2 ? tables.models[parts[0]]?[parts[1]]?.window : nil
            return AIRouteFacts(billing: .ownReport, window: window)
        case .claude:
            return AIRouteFacts(billing: .ownReport)
        case .codex, .cursor, .appleIntelligence, nil:
            return AIRouteFacts(billing: .unbilled)
        }
    }

    private static func facts(for model: String, on connection: AIConnection) -> AIRouteFacts {
        let known = connection.contextWindows?[model]
        if AIEndpointPolicy.isLoopback(connection.baseURL) {
            return AIRouteFacts(billing: .unbilled, window: known)
        }
        let routes = routes(atBaseURL: connection.baseURL)
        let entries = routes.compactMap { route in tables.models[route.id]?[model].map { (route, $0) } }
        let window = known ?? entries.lazy.compactMap(\.1.window).first
        if connection.provider == .codexPlan || connection.billing == .plan {
            return AIRouteFacts(billing: .unbilled, window: window)
        }
        // OpenRouter's reply carries what it billed, so its catalog price would only ever disagree.
        if connection.provider == .openRouter {
            return AIRouteFacts(billing: .perToken, window: window)
        }
        let rates = entries.lazy.filter { !$0.0.isPlan }.compactMap(\.1.rates).first
        if connection.billing == .perToken {
            return AIRouteFacts(billing: .perToken, window: window, rates: rates)
        }
        switch (routes.contains { $0.isPlan }, routes.contains { !$0.isPlan }) {
        case (true, false): return AIRouteFacts(billing: .unbilled, window: window)
        case (false, true): return AIRouteFacts(billing: .perToken, window: window, rates: rates)
        default: return AIRouteFacts(billing: .undetermined, window: window)
        }
    }

    /// The address itself; a path no API lists falls back to whoever else answers on that host.
    private static func routes(atBaseURL baseURL: String) -> [Route] {
        guard let key = routeKey(baseURL) else { return [] }
        let exact = tables.routes.filter { $0.key == key }
        if !exact.isEmpty { return exact }
        let host = key.prefix { $0 != "/" }
        return tables.routes.filter { $0.key.prefix { $0 != "/" } == host }
    }

    /// Host and path without what every client appends, so `/v1` and no `/v1` are one API.
    private static func routeKey(_ baseURL: String) -> String? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host()?.lowercased() else { return nil }
        var path = url.path().lowercased()
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in ["/chat/completions", "/messages", "/v1"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
        }
        return host + path
    }

    private static func parse(routes: String, models: String) -> Tables {
        let parsedRoutes = routes.split(separator: "\n").compactMap { line -> Route? in
            let fields = line.trimmingCharacters(in: .whitespaces).split(separator: "\t").map(String.init)
            guard fields.count == 3, let key = routeKey(fields[2]) else { return nil }
            return Route(id: fields[0], isPlan: fields[1] == "plan", key: key)
        }
        var table: [String: [String: Entry]] = [:]
        var route = ""
        for line in models.split(separator: "\n") {
            let row = line.drop { $0 == " " }
            if row.first == "@" {
                route = String(row.dropFirst())
                continue
            }
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false)
            guard let id = fields.first else { continue }
            table[route, default: [:]][String(id)] = Entry(
                window: fields.count > 1 ? Int(fields[1]) : nil,
                rates: fields.count > 2
                    ? AIModelRates(prices: fields[2], tiers: fields.count > 3 ? fields[3] : "") : nil)
        }
        return Tables(routes: parsedRoutes, models: table)
    }
}

extension AIModelRates {
    fileprivate init?(prices: Substring, tiers: Substring) {
        guard let base = Prices(prices) else { return nil }
        self.init(
            base: base,
            tiers: tiers.split(separator: ",").compactMap { tier in
                let parts = tier.split(separator: ":")
                guard parts.count == 2, let above = Int(parts[0]), let prices = Prices(parts[1]) else {
                    return nil
                }
                return Tier(above: above, prices: prices)
            })
    }
}

extension AIModelRates.Prices {
    fileprivate init?(_ text: Substring) {
        let fields = text.split(separator: "/", omittingEmptySubsequences: false).map { Double($0) }
        guard fields.count == 5, let input = fields[0], let output = fields[1] else { return nil }
        self.init(
            input: input, output: output, cacheRead: fields[2], cacheWrite: fields[3], reasoning: fields[4])
    }
}

extension AIUsage {
    /// A reply the route did not price, priced by its tariff; a route's own figure always wins.
    func priced(by rates: AIModelRates?) -> AIUsage {
        guard costUSD == nil, let rates, inputTokens != nil || outputTokens != nil else { return self }
        var priced = self
        priced.costUSD = rates.cost(
            input: inputTokens ?? 0, cached: cachedInputTokens ?? 0, written: cacheWrittenTokens ?? 0,
            output: outputTokens ?? 0, reasoning: reasoningTokens ?? 0)
        return priced
    }
}

/// Fork: the chat's cost as the settings card states it; a plan's chat states nothing at all.
enum ChatCostLine: Equatable, Sendable {
    case hidden
    case noTariff
    /// Replies from before tariffs were known: they keep no price, and the next one will have one.
    case notYetPriced
    case spent(Double, estimated: Bool, pricedReplies: Int, replies: Int)

    /// A reply is priced when it is written, since a chat can change model between two of them.
    static func line(facts: AIRouteFacts, runsOwnRuntime: Bool, replies: [AIUsage]) -> ChatCostLine {
        // ACP does not say who pays, and Claude Code reports a price on a plan too.
        if runsOwnRuntime || facts.billing == .unbilled { return .hidden }
        let costs = replies.compactMap(\.costUSD)
        if !costs.isEmpty {
            return .spent(
                costs.reduce(0, +), estimated: facts.billing == .ownReport || facts.rates != nil,
                pricedReplies: costs.count, replies: replies.count)
        }
        if facts.billing == .ownReport || replies.isEmpty { return .hidden }
        return facts.rates == nil ? .noTariff : .notYetPriced
    }
}
