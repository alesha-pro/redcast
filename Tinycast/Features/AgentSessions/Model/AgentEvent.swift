import Foundation

/// `redcast://` or `tinycast://agent-sessions/…`: each is claimed, so none reaches the launcher.
enum AgentDeepLink: Equatable, Sendable {
    case open(query: String?)
    case jump
    case event(AgentEvent)

    static let host = "agent-sessions"
    static let queryLimit = 200

    static func claims(_ url: URL) -> Bool {
        ["redcast", "tinycast"].contains(url.scheme?.lowercased()) && url.host()?.lowercased() == host
    }

    /// Nil drops the link: anything outside the grammar, or an event without the right token.
    static func parse(_ url: URL, token: String?) -> AgentDeepLink? {
        guard claims(url), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var fields: [String: String] = [:]
        for item in components.queryItems ?? [] where fields[item.name] == nil {
            fields[item.name] = item.value ?? ""
        }
        switch components.path {
        case "/open":
            let query = fields["q"].map { String($0.prefix(queryLimit)) }
            return .open(query: query?.isEmpty == false ? query : nil)
        case "/jump":
            return .jump
        case "/event":
            return event(fields, token: token).map(AgentDeepLink.event)
        default:
            return nil
        }
    }

    private static func event(_ fields: [String: String], token: String?) -> AgentEvent? {
        guard fields["v"] == "1", let token, let presented = fields["k"], constantTimeEqual(presented, token),
            let agent = fields["agent"].flatMap(AgentHookTarget.init(rawValue:))?.agent,
            let event = fields["event"].flatMap(AgentHookEvent.init(rawValue:)),
            let session = fields["session"], (8...64).contains(session.utf8.count),
            AgentResumeCommand.isSafeID(session)
        else { return nil }
        let kind = fields["kind"] ?? ""
        guard kind.utf8.count <= 40, kind.utf8.allSatisfy({ (0x61...0x7A).contains($0) || $0 == UInt8(ascii: "_") })
        else { return nil }
        var pid: Int32?
        if let text = fields["pid"], !text.isEmpty {
            guard text.utf8.count <= 7, text.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
                let value = Int32(text), value > 0
            else { return nil }
            pid = value
        }
        return AgentEvent(agent: agent, event: event, sessionID: session, kind: kind.isEmpty ? nil : kind, pid: pid)
    }

    /// Every byte is compared whatever matched before, so timing says nothing about the token.
    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let (left, right) = (Array(lhs.utf8), Array(rhs.utf8))
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

struct AgentEvent: Equatable, Sendable {
    let agent: AgentSource
    let event: AgentHookEvent
    let sessionID: String
    /// `notification_type`.
    let kind: String?
    let pid: Int32?

    var status: AgentLiveStatus {
        switch event {
        case .working: .working
        case .waiting: .waiting(reason: kind)
        case .finished: .finished
        case .failed: .failed
        case .ended: .ended
        }
    }
}

struct AgentActivity: Identifiable, Equatable, Sendable {
    let agent: AgentSource
    let sessionID: String
    var id: String { agent.rawValue + ":" + sessionID }
    var status: AgentLiveStatus
    var title: String?
    var directory: String?
    var hostBundleID: String?
    var tty: String?
    /// Where the session runs, from this Mac's history; `.terminal` until it is known.
    var host: AgentSessionHost
    var updatedAt: Date
    var seen: Bool

    init(
        agent: AgentSource, sessionID: String, status: AgentLiveStatus = .working, title: String? = nil,
        directory: String? = nil, hostBundleID: String? = nil, tty: String? = nil,
        host: AgentSessionHost = .terminal, updatedAt: Date, seen: Bool = false
    ) {
        self.agent = agent
        self.sessionID = sessionID
        self.status = status
        self.title = title
        self.directory = directory
        self.hostBundleID = hostBundleID
        self.tty = tty
        self.host = host
        self.updatedAt = updatedAt
        self.seen = seen
    }

    /// A person's own session; an automated run or one Tinycast started never asks for attention.
    var isTracked: Bool { host != .automated && host != .tinycast }

    /// Worth a menu-bar row: still going, waiting, or done and not looked at yet.
    var needsAttention: Bool {
        switch status {
        case .working, .waiting: true
        case .finished, .failed: !seen
        case .idle, .ended: false
        }
    }
}

/// Activity bookkeeping without timers: everything ages out when it is next touched.
enum AgentActivityPolicy {
    static let capacity = 32
    static let endedLinger: TimeInterval = 600
    static let staleAfter: TimeInterval = 12 * 3_600
    static let repeatWindow: TimeInterval = 10
    static let claudeApp = "com.anthropic.claudefordesktop"
    static let codexApp = "com.openai.codex"

    /// A desktop app's helper process reports its own id; the app is what gets focus and HUDs.
    static func appBundleID(_ host: String) -> String {
        [claudeApp, codexApp].first { host.hasPrefix($0 + ".") } ?? host
    }

    /// An ACP chat's session, or an agent whose process runs under this app, is Tinycast's own.
    static func isTinycastOwned(
        sessionID: String, hostBundleID: String?, acpSessions: Set<String>, appBundleID: String?
    ) -> Bool {
        acpSessions.contains(sessionID) || (hostBundleID != nil && hostBundleID == appBundleID)
    }

    /// Replaces the session's entry; an event resolved after a newer one changes nothing.
    static func apply(_ event: AgentEvent, resolved: AgentActivity, to items: [AgentActivity], now: Date)
        -> [AgentActivity]
    {
        // An entry kept before its session was known to be untracked goes too.
        guard resolved.isTracked else { return prune(items.filter { $0.id != resolved.id }, now: now) }
        var updated = resolved
        updated.status = event.status
        let previous = items.first { $0.id == updated.id }
        if let previous, previous.updatedAt > updated.updatedAt { return prune(items, now: now) }
        switch event.status {
        case .finished, .failed: updated.seen = false
        default: updated.seen = previous?.status == updated.status ? previous?.seen ?? false : false
        }
        return prune([updated] + items.filter { $0.id != updated.id }, now: now)
    }

    static func prune(_ items: [AgentActivity], now: Date) -> [AgentActivity] {
        let kept = items.filter { item in
            let age = now.timeIntervalSince(item.updatedAt)
            if age > staleAfter { return false }
            return item.status != .ended || age <= endedLinger
        }
        return Array(kept.sorted { $0.updatedAt > $1.updatedAt }.prefix(capacity))
    }

    /// The newest waiting session, else the newest one that finished or failed unseen.
    static func jumpTarget(_ items: [AgentActivity]) -> AgentActivity? {
        let newest = items.sorted { $0.updatedAt > $1.updatedAt }
        if let waiting = newest.first(where: { if case .waiting = $0.status { true } else { false } }) {
            return waiting
        }
        return newest.first { ($0.status == .finished || $0.status == .failed) && !$0.seen }
    }

    struct Announcement: Equatable, Sendable {
        enum Tone: Equatable, Sendable { case success, neutral, danger }
        let tone: Tone
        let kind: AgentHookEvent
    }

    /// What to say, or nil to stay quiet; `lastAnnounced` is this session's last one of this kind.
    static func announcement(
        for activity: AgentActivity, previous: AgentActivity?, frontmostBundleID: String?,
        lastAnnounced: Date?, now: Date
    ) -> Announcement? {
        let announcement: Announcement
        switch activity.status {
        case .finished: announcement = Announcement(tone: .success, kind: .finished)
        case .waiting: announcement = Announcement(tone: .neutral, kind: .waiting)
        case .failed: announcement = Announcement(tone: .danger, kind: .failed)
        case .working, .idle, .ended: return nil
        }
        guard activity.isTracked else { return nil }
        // Both desktop apps announce their own agents' turns.
        if let host = activity.hostBundleID.map(appBundleID) {
            guard host != claudeApp, host != codexApp, host != frontmostBundleID else { return nil }
        }
        if let lastAnnounced, now.timeIntervalSince(lastAnnounced) < repeatWindow { return nil }
        guard previous?.status != activity.status else { return nil }
        return announcement
    }
}

enum ClaudeAgentsListing {
    /// `claude agents --json`; unknown statuses read as idle, unknown fields are ignored.
    static func decode(_ data: Data) -> [AgentLiveEntry] {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return array.compactMap { object in
            guard let session = object["sessionId"] as? String, AgentResumeCommand.isSafeID(session) else {
                return nil
            }
            let reason = (object["waitingFor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let status: AgentLiveStatus
            if object["kind"] as? String == "background", let state = object["state"] as? String {
                status = backgroundStatus(state, reason: reason)
            } else {
                status = interactiveStatus(object["status"] as? String, reason: reason)
            }
            let pid = (object["pid"] as? NSNumber).map { Int32(truncatingIfNeeded: $0.int64Value) }
            let started = (object["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1_000) }
            let background = (object["id"] as? String).flatMap { AgentResumeCommand.isSafeID($0) ? $0 : nil }
            return AgentLiveEntry(
                sessionID: session, status: status, pid: pid.flatMap { $0 > 0 ? $0 : nil },
                backgroundID: background, directory: object["cwd"] as? String, startedAt: started)
        }
    }

    private static func interactiveStatus(_ status: String?, reason: String?) -> AgentLiveStatus {
        switch status {
        case "busy": .working
        case "waiting": .waiting(reason: reason)
        default: .idle
        }
    }

    private static func backgroundStatus(_ state: String, reason: String?) -> AgentLiveStatus {
        switch state {
        case "working": .working
        case "blocked": .waiting(reason: reason)
        case "done": .finished
        case "failed": .failed
        case "stopped": .ended
        default: .idle
        }
    }
}
