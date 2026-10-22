import SwiftUI

/// Settings → AI → Usage: what this Mac's chats reported, and an OpenRouter key's spend on a press.
struct UsageSection: View {
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var appSettings
    @Environment(AISettingsStore.self) private var aiSettings

    @State private var period = UsagePeriod.month
    @State private var anchor = Date()
    @State private var loaded: Loaded?

    private struct Request: Hashable {
        let interval: DateInterval
        let isEnabled: Bool
    }

    /// A nil report is a history that would not read.
    private struct Loaded {
        let request: Request
        let report: UsageReport?
    }

    private let calendar = Calendar.autoupdatingCurrent

    var body: some View {
        let now = Date()
        let interval = period.interval(containing: anchor, calendar: calendar)
        let request = Request(interval: interval, isEnabled: appSettings.aiEnabled)
        let openRouter = aiSettings.connections.filter {
            $0.provider == .openRouter && aiSettings.isRouteEnabled(.api($0.id))
        }
        Section {
            periodBar(interval: interval, now: now)
                // Keyed on the request: a new period, or AI switched off, retires this load.
                .task(id: request) { await load(request) }
            if let loaded, loaded.request == request {
                if let report = loaded.report, !report.lines.isEmpty {
                    SettingsRow(title: summary(report.total), subtitle: pricedNote(report.total)) {
                        EmptyView()
                    }
                    ForEach(report.lines) { line in
                        UsageLineRow(
                            line: line, title: title(of: line.subject), source: source(of: line.subject))
                    }
                } else {
                    Text("No usage in this period")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(openRouter) { connection in
                OpenRouterBalanceRow(connection: connection, showsName: openRouter.count > 1)
            }
        } header: {
            SettingsSectionHeader(.aiUsage)
        } footer: {
            Text(
                """
                Counted from the chats kept on this Mac, so a deleted chat takes its usage with it, \
                and Quick Actions are not counted. Costs are as each route reported them. Balances \
                are fetched only when you ask.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func periodBar(interval: DateInterval, now: Date) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Picker("Usage", selection: $period) {
                ForEach(UsagePeriod.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer(minLength: Theme.Spacing.lg)
            Button("Previous Period", systemImage: "chevron.left") { step(by: -1) }
                .help("Previous Period")
            Text(period.title(of: interval, now: now, calendar: calendar))
                .monospacedDigit()
            Button("Next Period", systemImage: "chevron.right") { step(by: 1) }
                .help("Next Period")
                .disabled(interval.end > now)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    private func step(by count: Int) {
        anchor = period.step(anchor, by: count, calendar: calendar)
    }

    private func load(_ request: Request) async {
        guard request.isEnabled else { return }
        let report = try? await UsageQuery.report(
            databaseURL: core.chatHistory.databaseURL, in: request.interval, agents: acpBindings())
        guard !Task.isCancelled else { return }
        loaded = Loaded(request: request, report: report)
    }

    /// A chat an ACP agent ran is the agent's: its CLI ran it, whatever the model picker held.
    private func acpBindings() -> [UUID: UUID] {
        let store = core.agentStore
        let acp = Set(store.agents.filter { $0.runtime != nil }.map(\.id))
        return store.chatAgents.filter { acp.contains($0.value) }
    }

    private func summary(_ total: UsageTotals) -> String {
        let tokens = UsageFormat.tokens(total.tokens)
        guard let cost = total.cost else { return String(localized: "\(tokens) tokens") }
        return String(localized: "\(tokens) tokens · \(UsageFormat.cost(cost))")
    }

    private func pricedNote(_ total: UsageTotals) -> String? {
        guard total.pricedReplies > 0, total.pricedReplies < total.replies else { return nil }
        return String(localized: "Cost reported for \(total.pricedReplies) of \(total.replies) replies")
    }

    private func title(of subject: UsageSubject) -> String {
        switch subject {
        case .model(_, let model): model
        case .agent(let id): core.agentStore.agent(id: id)?.name ?? String(localized: "Unknown model")
        case .unknown: String(localized: "Unknown model")
        }
    }

    private func source(of subject: UsageSubject) -> String? {
        switch subject {
        case .model(.api(let id), _):
            aiSettings.connection(id: id)?.title ?? String(localized: "Deleted connection")
        case .model(.appleIntelligence, _): AppleIntelligence.title
        case .model(let source, _): source.installedKind?.title
        case .agent(let id): core.agentStore.agent(id: id)?.runtime?.kind.title
        case .unknown: nil
        }
    }
}

private struct UsageLineRow: View {
    let line: UsageReport.Line
    let title: String
    let source: String?

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            Text(verbatim: amounts)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help(detail)
        }
    }

    private var subtitle: String {
        let replies = line.totals.replies
        guard let source else { return String(localized: "\(replies) replies") }
        return String(localized: "\(source) · \(replies) replies")
    }

    private var amounts: String {
        let totals = line.totals
        let input = UsageFormat.tokens(totals.promptTokens)
        let output = UsageFormat.tokens(totals.output)
        let tokens = String(localized: "\(input) in · \(output) out")
        return [tokens, totals.cost.map { UsageFormat.cost($0) } ?? "—"].joined(separator: " · ")
    }

    /// The full counts behind the compact ones, with the cached and thinking parts named.
    private var detail: String {
        let totals = line.totals
        let prompt = totals.promptTokens.formatted()
        let output = totals.output.formatted()
        let cached = totals.cached.formatted()
        let thinking = totals.reasoning.formatted()
        let inputLine = totals.cached > 0 ? String(localized: "\(prompt) · \(cached) cached") : prompt
        let outputLine =
            totals.reasoning > 0 ? String(localized: "\(output) · \(thinking) thinking") : output
        return inputLine + "\n" + outputLine
    }
}

/// One OpenRouter key's spend, fetched only on a press and dropped with the section.
private struct OpenRouterBalanceRow: View {
    let connection: AIConnection
    let showsName: Bool

    @State private var state = BalanceState.idle
    @State private var check: Task<Void, Never>?

    private enum BalanceState: Equatable {
        case idle
        case checking
        case loaded(OpenRouterBalance)
        case failed(String)
    }

    var body: some View {
        let brand = AIProviderKind.openRouter.title
        SettingsRow(
            title: showsName ? "\(brand) (\(connection.title))" : brand, subtitle: subtitle,
            subtitleLineLimit: 3
        ) {
            Button("Check Balance", action: start)
                .disabled(state == .checking)
        }
        .onDisappear {
            check?.cancel()
            if state == .checking { state = .idle }
        }
    }

    private var subtitle: String? {
        switch state {
        case .idle: nil
        case .checking: String(localized: "Checking…")
        case .failed(let message): message
        case .loaded(let balance): Self.lines(of: balance).joined(separator: "\n")
        }
    }

    private func start() {
        check?.cancel()
        state = .checking
        let connection = connection
        check = Task {
            let result: BalanceState
            do throws(OpenRouterAccount.Failure) {
                result = .loaded(try await OpenRouterAccountClient.balance(for: connection))
            } catch {
                result = .failed(error.message)
            }
            guard !Task.isCancelled else { return }
            state = result
        }
    }

    private static func lines(of balance: OpenRouterBalance) -> [String] {
        let key = balance.key
        let today = UsageFormat.cost(key.usageDaily)
        let week = UsageFormat.cost(key.usageWeekly)
        let month = UsageFormat.cost(key.usageMonthly)
        var lines = [String(localized: "\(today) today · \(week) this week · \(month) this month (UTC)")]
        if let spending = key.spendingLimit {
            let left = UsageFormat.cost(spending.remaining)
            let limit = UsageFormat.cost(spending.limit)
            lines.append(String(localized: "\(left) of \(limit) left on this key"))
        } else {
            lines.append(String(localized: "No spending limit on this key"))
        }
        if let credits = balance.credits {
            let left = UsageFormat.cost(credits.remaining)
            let total = UsageFormat.cost(credits.totalCredits)
            lines.append(String(localized: "\(left) of \(total) credits left"))
        } else {
            lines.append(String(localized: "The account balance needs an OpenRouter management key."))
        }
        return lines
    }
}
