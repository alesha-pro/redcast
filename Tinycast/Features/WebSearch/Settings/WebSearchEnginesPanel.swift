import SwiftUI

/// The engines a search tries, in order: switches, keys, the SearXNG address and a Test for each.
struct WebSearchEnginesPanel: View {
    @Environment(AppCore.self) private var core

    let onDone: () -> Void

    @State private var draft: WebSearchConfiguration
    @State private var keyDrafts: [WebSearchSource: String] = [:]
    /// As read when the panel opened, so Save writes the Keychain only when a key changed.
    @State private var savedKeys: [String: String] = [:]
    @State private var keysReadable = true
    @State private var tests: [WebSearchSource: TestState] = [:]
    @State private var testTasks: [WebSearchSource: Task<Void, Never>] = [:]
    @State private var failure: String?

    private enum TestState: Equatable {
        case running
        case passed(Int, Duration)
        case failed(String)
    }

    private static let setupGuide = URL(string: "https://docs.searxng.org/admin/installation.html")!
    private static let testQuery = WebSearchQuery(text: "Tinycast macOS launcher", count: 3, recency: nil)

    init(configuration: WebSearchConfiguration, onDone: @escaping () -> Void) {
        _draft = State(initialValue: configuration)
        self.onDone = onDone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            SettingsEditorHeader(
                title: "Search Engines",
                subtitle: """
                    Tried in order: when one fails or is busy, the next one answers. Only the query \
                    leaves this Mac.
                    """)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    ForEach(draft.order) { source in
                        engineRow(source)
                        if source != draft.order.last { Divider() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 520)

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(
                    """
                    Searches send only the query, with no cookies and no cache. DuckDuckGo is read \
                    from its web page, not an official API.
                    """)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("SearXNG setup", destination: Self.setupGuide)
            }
            .font(.caption)

            if let failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(Theme.Colors.destructive)
            }

            HStack(spacing: Theme.Spacing.md) {
                Spacer()
                Button("Cancel", action: onDone)
                    .buttonStyle(.modalAction(.cancel))
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.modalAction(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.dialogInset)
        .frame(width: Theme.Size.editorSheetWidth)
        .settingsEditorPanelSurface(controlsOnGlass: false)
        .onAppear(perform: loadKeys)
        .onDisappear {
            for task in testTasks.values { task.cancel() }
        }
    }

    private func engineRow(_ source: WebSearchSource) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.md) {
                Toggle(source.title, isOn: enabled(source))
                    .toggleStyle(.checkbox)
                    .disabled(!isReady(source) && !draft.enabled.contains(source))
                Spacer(minLength: Theme.Spacing.md)
                Button("Test") { test(source) }
                    .disabled(!isReady(source) || tests[source] == .running)
                moveButton(source, by: -1, symbol: "chevron.up", label: "Move Up")
                moveButton(source, by: 1, symbol: "chevron.down", label: "Move Down")
            }
            Self.caption(source)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            credentialField(source)
            testStatus(source)
        }
    }

    @ViewBuilder
    private func credentialField(_ source: WebSearchSource) -> some View {
        if source.key != .none {
            RevealableSecureField(
                title: String(localized: "API key"), text: key(source),
                prompt: source.key == .optional ? Text("API key (optional)") : Text("API key"))
                .settingsEditorTextField()
                .disabled(!keysReadable)
        } else if source == .searxng {
            TextField("Address", text: address, prompt: Text(verbatim: "http://llm-server.local:8888"))
                .settingsEditorTextField()
            if let error = addressError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.destructive)
            }
        }
    }

    @ViewBuilder
    private func testStatus(_ source: WebSearchSource) -> some View {
        switch tests[source] {
        case .running?:
            Text("Testing…").font(.caption).foregroundStyle(.secondary)
        case .passed(let count, let duration)?:
            Text("\(count) results in \(Self.seconds(duration)) s").font(.caption).foregroundStyle(.secondary)
        case .failed(let message)?:
            Text(message).font(.caption).foregroundStyle(Theme.Colors.destructive)
        case nil:
            EmptyView()
        }
    }

    private func moveButton(
        _ source: WebSearchSource, by offset: Int, symbol: String, label: LocalizedStringKey
    ) -> some View {
        let index = draft.order.firstIndex(of: source) ?? 0
        return Button {
            withAnimation(.snappy) { draft.move(source, by: offset) }
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
        .disabled(!draft.order.indices.contains(index + offset))
    }

    // MARK: - Draft

    private func enabled(_ source: WebSearchSource) -> Binding<Bool> {
        Binding(
            get: { draft.enabled.contains(source) },
            set: { on in
                if on { draft.enabled.insert(source) } else { draft.enabled.remove(source) }
            })
    }

    private func key(_ source: WebSearchSource) -> Binding<String> {
        Binding(
            get: { keyDrafts[source] ?? "" },
            set: { value in
                let had = !(keyDrafts[source] ?? "").isEmpty
                keyDrafts[source] = value
                follow(source, had: had, has: !value.isEmpty)
            })
    }

    private var address: Binding<String> {
        Binding(
            get: { draft.searxngAddress },
            set: { value in
                let had = searxngURL != nil
                draft.searxngAddress = value
                follow(.searxng, had: had, has: searxngURL != nil)
            })
    }

    /// Typing a key or a valid address switches its engine on; losing a needed one switches it off.
    private func follow(_ source: WebSearchSource, had: Bool, has: Bool) {
        if has, !had { draft.enabled.insert(source) }
        if had, !has, !isReady(source) { draft.enabled.remove(source) }
    }

    private func isReady(_ source: WebSearchSource) -> Bool {
        switch source {
        case .searxng: searxngURL != nil
        default: source.key != .required || !(keyDrafts[source] ?? "").isEmpty
        }
    }

    private var searxngURL: URL? {
        try? WebSearchEndpoint.searxngURL(draft.searxngAddress).get()
    }

    private var addressError: String? {
        guard !draft.searxngAddress.trimmingCharacters(in: .whitespaces).isEmpty,
            case .failure(let error) = WebSearchEndpoint.searxngURL(draft.searxngAddress)
        else { return nil }
        return error.message
    }

    /// Keys this build does not know are kept as read, so an older build never drops a newer one's.
    private var rawKeys: [String: String] {
        var keys = savedKeys
        for source in WebSearchSource.allCases where source.key != .none {
            keys[source.rawValue] = keyDrafts[source]?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return keys.filter { !$0.value.isEmpty }
    }

    // MARK: - Effects

    /// The panel's only Keychain read; a failed one leaves the keys alone, never blanks them.
    private func loadKeys() {
        do {
            savedKeys = try core.webSearch.keys()
            for (raw, value) in savedKeys {
                if let source = WebSearchSource(rawValue: raw) { keyDrafts[source] = value }
            }
        } catch {
            keysReadable = false
            failure = String(localized: "Tinycast couldn't read the keys from the Keychain.")
        }
    }

    /// The only request outside a turn, and only on a click.
    private func test(_ source: WebSearchSource) {
        testTasks[source]?.cancel()
        let keys = rawKeys
        let runner = WebSearchRunner(
            chain: [source], searxng: searxngURL, reader: nil, keys: { keys })
        tests[source] = .running
        testTasks[source] = Task {
            let clock = ContinuousClock()
            let start = clock.now
            let outcome = await runner.search(Self.testQuery)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .found(_, let results):
                tests[source] = .passed(results.count, clock.now - start)
            case .failed(let attempts):
                tests[source] = .failed(Self.failureMessage(attempts.first?.failure ?? .empty))
            }
        }
    }

    private func save() {
        let keys = rawKeys
        if keysReadable, keys != savedKeys {
            do {
                try core.webSearch.setKeys(keys)
            } catch {
                failure = String(localized: "Tinycast couldn't save the key to the Keychain.")
                return
            }
        }
        core.webSearch.save(draft)
        onDone()
    }

    // MARK: - Wording

    private static func caption(_ source: WebSearchSource) -> Text {
        switch source {
        case .exa:
            Text(
                """
                Search with page excerpts. Free without a key at a shared rate limit; a free key adds \
                monthly credit.
                """)
        case .parallel:
            Text("Search built for agents, with page excerpts. Free without a key at a lower rate limit.")
        case .duckDuckGo:
            Text(
                """
                Private results with short snippets, read from its web page. Unofficial, and may refuse \
                when busy.
                """)
        case .searxng:
            Text("Your own SearXNG with JSON output switched on. Unlimited and private.")
        case .brave:
            Text(
                """
                Brave's independent index. Needs a key; about 1,000 searches a month are free, with a \
                card on file.
                """)
        case .tavily:
            Text("Search for agents. Needs a key; 1,000 searches a month are free, no card.")
        }
    }

    /// The user's wording for what `WebSearchFailure.reason` tells the model.
    private static func failureMessage(_ failure: WebSearchFailure) -> String {
        switch failure {
        case .rateLimited: String(localized: "Rate limited; try again later.")
        case .refused: String(localized: "Refused the request.")
        case .unauthorized: String(localized: "The key was not accepted.")
        case .status(let code): String(localized: "Answered HTTP \(code).")
        case .unreadable: String(localized: "Answered in a shape Tinycast can't read.")
        case .empty: String(localized: "No results.")
        case .missingKey: String(localized: "Needs a key.")
        case .missingAddress: String(localized: "Needs an address.")
        case .failed(let message): message
        }
    }

    private static func seconds(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        return (Double(seconds) + Double(attoseconds) / 1e18).formatted(.number.precision(.fractionLength(1)))
    }
}
