import Foundation

/// What the ⌘K Show section asks for; screen state, never persisted.
struct AgentSessionFilter: Equatable, Sendable {
    /// Nil shows every source.
    var source: AgentSource?
    var showsAutomated = false
    var showsArchived = false

    func admits(_ session: AgentSession) -> Bool {
        if let source, session.source != source { return false }
        if session.isAutomated, !showsAutomated { return false }
        if session.isArchived, !showsArchived { return false }
        return true
    }
}

/// Folded once per load, so a keystroke ranks without re-folding about 1,000 titles.
struct AgentSessionSearchKeys: Sendable {
    /// A folded owner field as bytes: owners match literally, so a byte search is all they need.
    struct Owner: Sendable {
        let bytes: [UInt8]
        let length: Int
        let isASCII: Bool

        init(_ raw: String) {
            let folded = FuzzyMatch.normalized(raw)
            bytes = Array(folded.utf8)
            length = folded.count
            isASCII = bytes.allSatisfy { $0 < 0x80 }
        }
    }

    /// The query folded both ways once per keystroke.
    struct Query: Sendable {
        let fuzzy: FuzzyMatch.Query
        let bytes: [UInt8]
        let length: Int

        init(_ raw: String) {
            fuzzy = FuzzyMatch.Query(raw)
            let folded = FuzzyMatch.normalized(raw)
            bytes = Array(folded.utf8)
            length = folded.count
        }
    }

    let title: FuzzyMatch.Candidate
    let owners: [Owner]

    init(_ session: AgentSession) {
        title = FuzzyMatch.Candidate(session.title)
        owners = [session.folderName, session.branch, session.agentName, session.firstPrompt, session.lastPrompt]
            .compactMap { text in
                guard let text, !text.isEmpty else { return nil }
                return Owner(text)
            }
    }

    /// The strongest key's cell plus its shape; prompts are owners, so they never match loosely.
    func quality(_ query: Query) -> Int? {
        var best = FuzzyMatch.match(query.fuzzy, candidate: title).flatMap { match in
            SearchRelevance.cell(.name, match.tier).map { $0 + SearchRelevance.shape(match) }
        }
        for owner in owners {
            guard let match = Self.literal(query, in: owner), let cell = SearchRelevance.cell(.owner, match.tier)
            else { continue }
            best = max(best ?? .min, cell + SearchRelevance.shape(match))
        }
        return best
    }

    /// `FuzzyMatch`'s literal tiers by `memmem`, skipping the subsequence pass owners never use.
    static func literal(_ query: Query, in owner: Owner) -> FuzzyMatch.Match? {
        let needle = query.bytes
        guard !needle.isEmpty, owner.bytes.count >= needle.count else { return nil }
        func match(_ tier: FuzzyMatch.Tier, offset: Int) -> FuzzyMatch.Match {
            FuzzyMatch.Match(
                tier: tier, offset: offset, queryLength: query.length, candidateLength: owner.length, spread: 0)
        }
        if owner.bytes == needle { return match(.exact, offset: 0) }
        if owner.bytes.starts(with: needle) { return match(.prefix, offset: 0) }
        let found = owner.bytes.withUnsafeBytes { haystack -> Int? in
            guard let base = haystack.baseAddress else { return nil }
            return needle.withUnsafeBytes { pattern in
                memmem(base, haystack.count, pattern.baseAddress, pattern.count).map {
                    base.distance(to: UnsafeRawPointer($0))
                }
            }
        }
        guard let byteOffset = found else { return nil }
        let isWordStart = !isWordByte(owner.bytes[byteOffset - 1])
        let offset =
            owner.isASCII
            ? byteOffset : String(bytes: owner.bytes[..<byteOffset], encoding: .utf8)?.count ?? byteOffset
        return match(isWordStart ? .wordStart : .substring, offset: offset)
    }

    /// A letter or digit, or any byte of a non-ASCII scalar, which is most likely a letter.
    private static func isWordByte(_ byte: UInt8) -> Bool {
        byte >= 0x80 || (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }
}

enum AgentSessionQuery {
    static let resultLimit = 300

    /// `live` is keyed by `AgentSession.id`, so a Claude and a Codex id can never collide.
    static func rank(
        _ entries: [(AgentSession, AgentSessionSearchKeys)], query: String,
        filter: AgentSessionFilter, live: [String: AgentLiveEntry]
    ) -> [AgentSession] {
        let admitted = entries.filter { filter.admits($0.0) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            func liveRank(_ session: AgentSession) -> Int {
                guard let status = live[session.id]?.status, status.isLive else { return Int.max }
                return status.rank
            }
            return admitted.map(\.0)
                .sorted { lhs, rhs in
                    let (left, right) = (liveRank(lhs), liveRank(rhs))
                    return left != right ? left < right : lhs.updatedAt > rhs.updatedAt
                }
                .prefix(resultLimit).map { $0 }
        }
        var scored = score(admitted, query: AgentSessionSearchKeys.Query(trimmed))
        if scored.isEmpty, trimmed.contains(" ") {
            scored = scoreTokens(admitted, tokens: trimmed.split(separator: " ").map(String.init))
        }
        return scored
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.updatedAt > $1.0.updatedAt }
            .prefix(resultLimit).map(\.0)
    }

    private static func score(
        _ entries: [(AgentSession, AgentSessionSearchKeys)], query: AgentSessionSearchKeys.Query
    ) -> [(AgentSession, Int)] {
        entries.compactMap { session, keys in keys.quality(query).map { (session, $0) } }
    }

    /// Every word of two or more characters must land somewhere; the qualities add up.
    private static func scoreTokens(
        _ entries: [(AgentSession, AgentSessionSearchKeys)], tokens: [String]
    ) -> [(AgentSession, Int)] {
        let queries = tokens.filter { $0.count >= 2 }.map(AgentSessionSearchKeys.Query.init)
        guard !queries.isEmpty else { return [] }
        return entries.compactMap { session, keys in
            var total = 0
            for query in queries {
                guard let quality = keys.quality(query) else { return nil }
                total += quality
            }
            return (session, total)
        }
    }
}
