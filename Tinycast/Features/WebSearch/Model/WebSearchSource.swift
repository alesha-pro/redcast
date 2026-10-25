import Foundation

/// An engine Tinycast can ask; the raw value is what settings and the Keychain item store.
enum WebSearchSource: String, CaseIterable, Identifiable, Sendable {
    case exa
    case parallel
    case duckDuckGo
    case searxng
    case brave
    case tavily

    enum Key: Sendable {
        case none
        case optional
        case required
    }

    var id: String { rawValue }

    /// Brand names, the same in every language.
    var title: String {
        switch self {
        case .exa: "Exa"
        case .parallel: "Parallel"
        case .duckDuckGo: "DuckDuckGo"
        case .searxng: "SearXNG"
        case .brave: "Brave Search"
        case .tavily: "Tavily"
        }
    }

    var key: Key {
        switch self {
        case .exa: .optional
        case .brave, .tavily: .required
        case .parallel, .duckDuckGo, .searxng: .none
        }
    }

    /// Every key lives in one Keychain item under this account, as `[rawValue: key]`.
    static let keychainAccount = UUID(uuidString: "5EA2C4B1-0D8E-4F6A-9B3C-2E7F1A6D8C40")!
}

enum WebSearchRecency: String, CaseIterable, Sendable {
    case day, week, month, year
}

struct WebSearchQuery: Equatable, Sendable {
    let text: String
    let count: Int
    let recency: WebSearchRecency?
}

struct WebSearchResult: Equatable, Sendable {
    let title: String
    let url: String
    /// As the engine wrote it: an ISO date, or Brave's "2 days ago".
    let published: String?
    let excerpt: String
}

/// Why one engine gave nothing; every case moves the search on to the next engine.
enum WebSearchFailure: Error, Equatable, Sendable {
    case missingKey
    case missingAddress
    case rateLimited
    case refused
    case unauthorized
    case status(Int)
    case unreadable
    case empty
    case failed(String)

    /// English on purpose: the model reads it, the user sees the panel's own wording.
    var reason: String {
        switch self {
        case .missingKey: "no API key"
        case .missingAddress: "no address set"
        case .rateLimited: "rate limited"
        case .refused: "refused the request (a CAPTCHA or a block)"
        case .unauthorized: "the key was not accepted"
        case .status(let code): "HTTP \(code)"
        case .unreadable: "an answer Redcast cannot read"
        case .empty: "no results"
        case .failed(let message): message
        }
    }
}

struct WebSearchAttempt: Equatable, Sendable {
    let source: WebSearchSource
    let failure: WebSearchFailure
}

enum WebSearchOutcome: Equatable, Sendable {
    case found(WebSearchSource, [WebSearchResult])
    case failed([WebSearchAttempt])
}
