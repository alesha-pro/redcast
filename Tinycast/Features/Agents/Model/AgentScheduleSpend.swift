import Foundation

/// The daily cap on what scheduled runs spend, and what they spent on the day last counted.
struct AgentScheduleSpend: Codable, Equatable, Sendable {
    /// US dollars a day across the runs schedules start on their own; nil is no cap.
    var capUSD: Double?
    /// The local day `spentUSD` was counted on, as `yyyy-MM-dd`.
    var day: String?
    var spentUSD: Double

    init(capUSD: Double? = nil, day: String? = nil, spentUSD: Double = 0) {
        self.capUSD = capUSD
        self.day = day
        self.spentUSD = spentUSD
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capUSD = try container.decodeIfPresent(Double.self, forKey: .capUSD)
        day = try container.decodeIfPresent(String.self, forKey: .day)
        spentUSD = try container.decodeIfPresent(Double.self, forKey: .spentUSD) ?? 0
    }
}

/// What a schedule may spend today. Pure: the day, the costs and the locale all come in.
enum AgentSpendPolicy {
    /// A local calendar day, so the cap starts afresh at midnight wherever the Mac is.
    static func day(of date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// What finished scheduled runs spent on `day`; another day's total no longer counts.
    static func spent(_ spend: AgentScheduleSpend, on day: String) -> Double {
        spend.day == day ? spend.spentUSD : 0
    }

    /// A due run starts only below the cap, so a cap of zero holds every schedule.
    static func allowsStart(_ spend: AgentScheduleSpend, on day: String) -> Bool {
        guard let cap = spend.capUSD else { return true }
        return spent(spend, on: day) < cap
    }

    /// Passed once the day's finished runs and the reported cost of those still running exceed it.
    static func isOver(_ spend: AgentScheduleSpend, on day: String, running: Double) -> Bool {
        guard let cap = spend.capUSD else { return false }
        return spent(spend, on: day) + running > cap
    }

    /// A finished run's cost, counted on the day it ended; the cap itself is left as it was.
    static func adding(
        _ cost: Double, to spend: AgentScheduleSpend, on day: String
    ) -> AgentScheduleSpend {
        var updated = spend
        updated.spentUSD = spent(spend, on: day) + (cost.isFinite ? max(0, cost) : 0)
        updated.day = day
        return updated
    }

    /// A cap as typed: a negative or non-finite number is no cap at all.
    static func cap(_ typed: Double?) -> Double? {
        guard let typed, typed.isFinite, typed >= 0 else { return nil }
        return typed
    }

    static func amount(_ usd: Double, locale: Locale) -> String {
        usd.formatted(.currency(code: "USD").locale(locale))
    }

    /// Why a due run did not start, in the words its row shows.
    static func notStarted(cap: Double, locale: Locale) -> String {
        let limit = amount(cap, locale: locale)
        return String(localized: "Not started: scheduled runs reached today's cap of \(limit)")
    }

    static func stopped(cap: Double, locale: Locale) -> String {
        let limit = amount(cap, locale: locale)
        return String(localized: "Stopped at today's spend cap of \(limit)")
    }
}
