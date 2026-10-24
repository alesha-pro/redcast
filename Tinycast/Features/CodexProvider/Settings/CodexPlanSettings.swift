import SwiftUI

/// The Providers page of one Codex (ChatGPT) connection: its sign-in, models and last limits.
struct CodexPlanConnectionSections: View {
    @Environment(CodexPlanAccounts.self) private var accounts
    let connection: AIConnection

    var body: some View {
        let id = connection.id
        Section {
            statusRows(id)
        } header: {
            Text("Account")
        } footer: {
            Text(
                """
                Signs in with OpenAI’s Sign in with ChatGPT for open-source apps. Tokens stay in your \
                login Keychain.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if accounts.phase(for: id) == .signedIn || accounts.limits[id] != nil {
            Section {
                CodexPlanLimitRows(limits: accounts.limits[id])
                LabeledContent {
                    Link("Manage Usage", destination: CodexPlanLimitRows.manageUsageURL)
                } label: {
                    Text("ChatGPT usage settings")
                }
            } header: {
                Text("Codex limits")
            } footer: {
                Text("Read from your own replies; nothing is fetched in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func statusRows(_ id: UUID) -> some View {
        switch accounts.phase(for: id) {
        case .signedOut:
            LabeledContent {
                signInButton(id)
            } label: {
                Text("Not signed in")
                Text("Uses your ChatGPT plan’s Codex usage, not an API key.")
            }
        case .signingIn:
            LabeledContent {
                Button("Cancel") { accounts.cancelSignIn(id) }
            } label: {
                HStack(spacing: Theme.Spacing.md) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the browser…")
                }
                Text("Finish signing in on the page that opened.")
            }
        case .signInRequired:
            LabeledContent {
                signInButton(id)
            } label: {
                Label("Sign in required", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Your ChatGPT sign-in has expired.")
            }
        case .failed(let message):
            LabeledContent {
                Button("Try Again") { accounts.signIn(id) }
                    .disabled(accounts.isSigningIn)
            } label: {
                Label("Sign-in failed", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(message)
            }
        case .signedIn:
            signedInRows(id)
        }
    }

    @ViewBuilder
    private func signedInRows(_ id: UUID) -> some View {
        let account = accounts.accounts[id]
        LabeledContent {
            Text(verbatim: account?.planTitle.map { "ChatGPT \($0)" } ?? "ChatGPT")
                .foregroundStyle(.secondary)
        } label: {
            Text("Account")
            if let email = account?.email {
                RedactedText(
                    value: email,
                    revealHelp: String(localized: "Click to reveal the signed-in account"),
                    hideHelp: String(localized: "Click to hide the signed-in account"))
            }
        }
        LabeledContent {
            Button("Sign Out") { accounts.signOut(id) }
        } label: {
            if account?.usesPlan == false {
                Label("Plan usage not allowed", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("This sign-in did not allow ChatGPT plan usage. Sign out and sign in again.")
            } else {
                Text("Using ChatGPT plan")
                Text("Replies count against your plan’s Codex usage.")
            }
        }
        LabeledContent {
            Button("Refresh Models") { Task { await accounts.loadModels(id) } }
                .disabled(accounts.loadingModels.contains(id))
        } label: {
            Text("Models")
            Text(accounts.modelFailures[id] ?? String(localized: "\(connection.models.count) models available"))
        }
    }

    private func signInButton(_ id: UUID) -> some View {
        Button("Continue with ChatGPT") { accounts.signIn(id) }
            .disabled(accounts.isSigningIn)
    }
}

extension CodexPlanAccounts {
    /// The Providers list's one line: usable once signed in, not once a key is saved.
    func caption(for connection: AIConnection) -> String {
        switch phase(for: connection.id) {
        case .signedIn:
            let count = String(localized: "\(connection.models.count) models")
            return String(localized: "Ready · \(count)")
        case .signingIn: return String(localized: "Checking…")
        case .signedOut, .signInRequired: return String(localized: "Sign in required")
        case .failed: return String(localized: "Check failed")
        }
    }
}

/// One row per usage window the last reply reported, and how old that report is.
struct CodexPlanLimitRows: View {
    static let manageUsageURL = URL(string: "https://chatgpt.com/settings/usage")!

    let limits: CodexPlanLimits?

    var body: some View {
        if let limits {
            ForEach(Array(limits.windows.enumerated()), id: \.offset) { index, window in
                LabeledContent {
                    HStack(spacing: Theme.Spacing.md) {
                        ProgressView(value: Double(window.remainingPercent), total: 100)
                            .frame(width: Theme.Size.aiUsageBar)
                        Text("\(window.remainingPercent)% left")
                            .monospacedDigit()
                    }
                } label: {
                    Text(Self.title(window, primary: index == 0 && limits.primary != nil))
                    if let reset = window.resetsAt {
                        Text("Resets \(reset, style: .relative)")
                    }
                }
            }
            Text("As of \(limits.capturedAt.formatted(.relative(presentation: .named)))")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("No limits yet. They arrive with your next reply.")
                .foregroundStyle(.secondary)
        }
    }

    static func title(_ window: CodexPlanLimits.Window, primary: Bool) -> String {
        guard let minutes = window.windowMinutes, minutes > 0 else {
            return primary
                ? String(localized: "Primary window") : String(localized: "Secondary window")
        }
        if minutes >= 1_440 { return String(localized: "\(minutes / 1_440)-day window") }
        if minutes >= 60 { return String(localized: "\(minutes / 60)-hour window") }
        return String(localized: "\(minutes)-minute window")
    }

    /// The Usage pane's lines: each window, then the snapshot's age.
    static func lines(_ limits: CodexPlanLimits?, now: Date) -> [String] {
        guard let limits else { return [String(localized: "No limits yet. They arrive with your next reply.")] }
        let formatter = RelativeDateTimeFormatter()
        var lines = limits.windows.enumerated().map { index, window in
            let title = title(window, primary: index == 0 && limits.primary != nil)
            let left = window.remainingPercent
            guard let reset = window.resetsAt else { return String(localized: "\(title): \(left)% left") }
            let when = formatter.localizedString(for: reset, relativeTo: now)
            return String(localized: "\(title): \(left)% left, resets \(when)")
        }
        let age = formatter.localizedString(for: limits.capturedAt, relativeTo: now)
        lines.append(String(localized: "As of \(age)"))
        return lines
    }
}

/// Settings → AI → Usage: a Codex (ChatGPT) connection's limits, read from disk, never fetched.
struct CodexPlanUsageRow: View {
    @Environment(CodexPlanAccounts.self) private var accounts
    let connection: AIConnection
    let showsName: Bool

    var body: some View {
        var lines = CodexPlanLimitRows.lines(accounts.limits[connection.id], now: Date())
        if showsName { lines.insert(connection.title, at: 0) }
        return SettingsRow(
            title: "Codex limits", subtitle: lines.joined(separator: "\n"), subtitleLineLimit: 6,
            anchor: .aiUsage
        ) {
            Link("Manage Usage", destination: CodexPlanLimitRows.manageUsageURL)
        }
        .onAppear { accounts.loadLimits() }
    }
}
