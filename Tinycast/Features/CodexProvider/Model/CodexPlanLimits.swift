import Foundation

/// The plan's usage windows as the last reply reported them; nothing is ever asked for them.
struct CodexPlanLimits: Codable, Equatable, Sendable {
    struct Window: Codable, Equatable, Sendable {
        let usedPercent: Double
        let windowMinutes: Int?
        let resetsAt: Date?

        var remainingPercent: Int { Int(max(0, min(100, 100 - usedPercent)).rounded()) }
        var isSpent: Bool { usedPercent >= 100 }
    }

    let primary: Window?
    let secondary: Window?
    let capturedAt: Date

    var windows: [Window] { [primary, secondary].compactMap { $0 } }

    /// The reset that lifts a spent limit: the latest among the spent windows.
    var spentUntil: Date? {
        windows.filter(\.isSpent).compactMap(\.resetsAt).max()
    }

    /// Codex's `x-codex-*` family, as codex-api's `parse_rate_limit_for_limit` reads it.
    static func parse(headers: [String: String], now: Date) -> CodexPlanLimits? {
        var lowered: [String: String] = [:]
        for (name, value) in headers { lowered[name.lowercased()] = value }
        func window(_ prefix: String) -> Window? {
            guard let raw = lowered["x-codex-\(prefix)-used-percent"],
                let used = Double(raw.trimmingCharacters(in: .whitespaces)), used.isFinite
            else { return nil }
            let minutes = lowered["x-codex-\(prefix)-window-minutes"].flatMap { Int($0) }
            let reset = lowered["x-codex-\(prefix)-reset-at"].flatMap { Double($0) }
            // Codex drops an all-zero window as one the server did not fill in.
            guard used != 0 || (minutes ?? 0) != 0 || reset != nil else { return nil }
            return Window(
                usedPercent: used, windowMinutes: minutes,
                resetsAt: reset.map(Date.init(timeIntervalSince1970:)))
        }
        return make(primary: window("primary"), secondary: window("secondary"), now: now)
    }

    /// A `codex.rate_limits` stream event, the WebSocket transport's carrier of the same numbers.
    static func parse(event: JSONValue, now: Date) -> CodexPlanLimits? {
        guard let fields = event.objectValue, fields["type"]?.stringValue == "codex.rate_limits",
            let limits = fields["rate_limits"]?.objectValue
        else { return nil }
        func window(_ value: JSONValue?) -> Window? {
            guard let raw = value?.objectValue, case .number(let used)? = raw["used_percent"] else {
                return nil
            }
            let reset: Double? = if case .number(let at)? = raw["reset_at"] { at } else { nil }
            return Window(
                usedPercent: used, windowMinutes: raw["window_minutes"]?.intValue,
                resetsAt: reset.map(Date.init(timeIntervalSince1970:)))
        }
        return make(primary: window(limits["primary"]), secondary: window(limits["secondary"]), now: now)
    }

    private static func make(primary: Window?, secondary: Window?, now: Date) -> CodexPlanLimits? {
        guard primary != nil || secondary != nil else { return nil }
        return CodexPlanLimits(primary: primary, secondary: secondary, capturedAt: now)
    }
}

/// What a refused request or a failed stream means for someone using their ChatGPT plan.
enum CodexPlanFailure: Equatable, Sendable {
    case usageLimit(resetsAt: Date?)
    case signInRequired
    case notEligible
    case unsupported(String?)
    case unavailable
    case other(String)

    struct Detail: Equatable, Sendable {
        let code: String?
        let message: String?
        let param: String?
        let resetsAt: Date?
    }

    /// Both the HTTP body's `error` and a stream's `response.error` or `error` event.
    static func detail(in json: JSONValue?) -> Detail {
        let fields = json?.objectValue ?? [:]
        let error =
            fields["response"]?.objectValue?["error"]?.objectValue
            ?? fields["error"]?.objectValue ?? fields
        let code = error["code"]?.stringValue ?? error["type"]?.stringValue
        let resets: Date? =
            if case .number(let at)? = error["resets_at"] {
                Date(timeIntervalSince1970: at)
            } else { nil }
        return Detail(
            code: code == "error" ? nil : code,
            message: error["message"]?.stringValue ?? fields["detail"]?.stringValue,
            param: error["param"]?.stringValue, resetsAt: resets)
    }

    static func classify(status: Int?, detail: Detail, limits: CodexPlanLimits?) -> CodexPlanFailure {
        switch detail.code {
        case "subscription_sharing_usage_limit_exceeded", "usage_limit_reached", "usage_not_included":
            return .usageLimit(resetsAt: detail.resetsAt ?? limits?.spentUntil)
        case "subscription_sharing_invalid_user", "invalid_api_key", "token_expired":
            return .signInRequired
        case "subscription_sharing_user_not_eligible":
            return .notEligible
        case "subscription_sharing_unsupported_capability":
            return .unsupported(detail.param)
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
            return .unavailable
        default: break
        }
        switch status {
        case 401?: return .signInRequired
        case 429? where limits?.spentUntil != nil: return .usageLimit(resetsAt: limits?.spentUntil)
        case 503?: return .unavailable
        default: return .other(detail.message ?? "")
        }
    }

    func message(now: Date) -> String {
        switch self {
        case .usageLimit(let resetsAt?):
            let when = RelativeDateTimeFormatter().localizedString(for: resetsAt, relativeTo: now)
            return String(
                localized: "Your ChatGPT plan’s usage limit is reached. It resets \(when).")
        case .usageLimit(nil):
            return String(
                localized: """
                    Your ChatGPT plan’s usage limit is reached. Review your plan or this app’s \
                    limit in ChatGPT settings → Usage.
                    """)
        case .signInRequired:
            return String(
                localized: "Your ChatGPT sign-in has expired. Sign in again in Settings → AI → Providers.")
        case .notEligible:
            return String(localized: "This ChatGPT account cannot use its plan in other apps.")
        case .unsupported(let param?):
            return String(localized: "Using your ChatGPT plan does not support “\(param)”.")
        case .unsupported(nil):
            return String(localized: "Using your ChatGPT plan does not support this request.")
        case .unavailable:
            return String(localized: "ChatGPT plan usage is unavailable right now. Try again shortly.")
        case .other(let message): return message
        }
    }

    /// Only a busy plan may pass on a retry; a spent limit stays spent until it resets.
    var isTransient: Bool { self == .unavailable }
}
