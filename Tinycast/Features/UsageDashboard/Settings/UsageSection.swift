import SwiftUI

/// Settings → AI → Usage: what replies on this Mac reported, and an OpenRouter key's spend.
struct UsageSection: View {
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var appSettings
    @Environment(AISettingsStore.self) private var aiSettings

    @State private var period = UsagePeriod.month
    @State private var anchor = Date()
    @State private var loaded: Loaded?

    private struct Request: Hashable {
        let interval: DateInterval
        let slices: [Date]
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
        let request = Request(
            interval: interval, slices: period.slices(of: interval, calendar: calendar),
            isEnabled: appSettings.aiEnabled)
        let openRouter = aiSettings.connections.filter {
            $0.provider == .openRouter && aiSettings.isRouteEnabled(.api($0.id))
        }
        Section {
            periodBar(interval: interval, now: now)
                // Keyed on the request: a new period, or AI switched off, retires this load.
                .task(id: request) { await load(request) }
            if let loaded, loaded.request == request {
                if let report = loaded.report, !report.lines.isEmpty {
                    SettingsRow(title: Self.summary(report.total), subtitle: pricedNote(report.total)) {
                        EmptyView()
                    }
                    if report.slices.count > 1 {
                        UsageTrendStrip(
                            slices: report.slices, period: period, interval: interval, now: now,
                            calendar: calendar)
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
                and from a log of the replies no chat keeps, such as Quick Actions. Costs are as each \
                route reported them. Balances are fetched only when you ask.
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
            databaseURL: core.chatHistory.databaseURL, ledgerURL: UsageLedger.url, in: request.interval,
            slices: request.slices, agents: acpBindings())
        guard !Task.isCancelled else { return }
        loaded = Loaded(request: request, report: report)
    }

    /// A chat an ACP agent ran is the agent's: its CLI ran it, whatever the model picker held.
    private func acpBindings() -> [UUID: UUID] {
        let store = core.agentStore
        let acp = Set(store.agents.filter { $0.runtime != nil }.map(\.id))
        return store.chatAgents.filter { acp.contains($0.value) }
    }

    fileprivate static func summary(_ total: UsageTotals) -> String {
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
    @State private var editsManagementKey = false

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
            HStack(spacing: Theme.Spacing.md) {
                Button("Management Key…") { editsManagementKey = true }
                Button("Check Balance", action: start)
                    .disabled(state == .checking)
            }
        }
        .onDisappear {
            check?.cancel()
            if state == .checking { state = .idle }
        }
        .settingsEditorPanel(isPresented: $editsManagementKey) {
            OpenRouterManagementKeyPanel(connection: connection) { changed in
                editsManagementKey = false
                // A balance shown with the old key would now describe an account it may not be.
                if changed, state != .checking { state = .idle }
            }
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
        switch balance.credits {
        case .loaded(let credits):
            let left = UsageFormat.cost(credits.remaining)
            let total = UsageFormat.cost(credits.totalCredits)
            lines.append(String(localized: "\(left) of \(total) credits left"))
        case .needsManagementKey:
            lines.append(String(localized: "The account balance needs an OpenRouter management key."))
        case .failed(let failure):
            lines.append(failure.message)
        }
        return lines
    }
}

/// Tokens per hour of a day, or per day of a week or month, with the slice holding now tinted.
private struct UsageTrendStrip: View {
    let slices: [UsageReport.Slice]
    let period: UsagePeriod
    let interval: DateInterval
    let now: Date
    let calendar: Calendar

    var body: some View {
        let peak = slices.map(\.totals.tokens).max() ?? 0
        let current = period.isCurrent(interval, now: now) ? slices.lastIndex { $0.start <= now } : nil
        HStack(alignment: .bottom, spacing: Theme.Spacing.xxs) {
            ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                bar(slice, peak: peak, isCurrent: index == current)
            }
        }
        .frame(height: Theme.Size.usageTrendHeight)
    }

    private func bar(_ slice: UsageReport.Slice, peak: Int, isCurrent: Bool) -> some View {
        let tokens = slice.totals.tokens
        let label = period.sliceTitle(of: slice.start, calendar: calendar) + "\n"
            + UsageSection.summary(slice.totals)
        let fill: Color =
            tokens == 0 ? Theme.Colors.separator : isCurrent ? .accentColor : Theme.Colors.textTertiary
        let height =
            tokens == 0
            ? Theme.Size.hairline
            : max(Theme.Spacing.xxs, Theme.Size.usageTrendHeight * CGFloat(tokens) / CGFloat(max(peak, 1)))
        return Color.clear
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: Theme.Radius.glyph)
                    .fill(fill)
                    .frame(height: height)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .help(label)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: label))
    }
}

/// Sets or removes one connection's management key; the key is checked for, never read back.
private struct OpenRouterManagementKeyPanel: View {
    let connection: AIConnection
    let onDone: (_ changed: Bool) -> Void

    @State private var key = ""
    @State private var isStored = false
    @State private var failure: String?

    private let keychain = KeychainSecretStore.openRouterManagementKeys

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            SettingsEditorHeader(
                title: "OpenRouter Management Key",
                subtitle: """
                    Used only to read your account's credits when you press Check Balance, and sent \
                    only to OpenRouter. Create one in OpenRouter's settings under Management Keys.
                    """)
            RevealableSecureField(
                title: String(localized: "Management Key"), text: $key,
                prompt: isStored ? Text("Stored in Keychain") : Text(verbatim: "sk-or-v1-…"))
                .settingsEditorTextField()
            if let failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(Theme.Colors.destructive)
            }
            HStack(spacing: Theme.Spacing.md) {
                if isStored {
                    Button("Remove", role: .destructive, action: remove)
                        .buttonStyle(.modalAction(.destructive, fillsWidth: false))
                }
                Spacer()
                Button("Cancel") { onDone(false) }
                    .buttonStyle(.modalAction(.cancel))
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.modalAction(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(Theme.Spacing.dialogInset)
        .frame(width: Theme.Size.editorSheetWidth)
        .settingsEditorPanelSurface(controlsOnGlass: false)
        .onAppear(perform: checkStored)
    }

    private var trimmed: String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func checkStored() {
        do {
            isStored = try keychain.hasSecret(for: connection.id)
        } catch {
            failure = String(localized: "Tinycast couldn't read the keys from the Keychain.")
        }
    }

    private func save() {
        do {
            try keychain.setSecret(trimmed, for: connection.id)
            onDone(true)
        } catch {
            failure = String(localized: "Tinycast couldn't save the key to the Keychain.")
        }
    }

    private func remove() {
        do {
            try keychain.removeSecret(for: connection.id)
            onDone(true)
        } catch {
            failure = String(localized: "Tinycast couldn't save the key to the Keychain.")
        }
    }
}
