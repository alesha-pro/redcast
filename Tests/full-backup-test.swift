import AppleArchive
import Foundation
import SQLite3
import System

/// The full backup's sections, version tolerance, import rules and sealed secrets, in temp dirs.
@main
@MainActor
struct FullBackupTest {
    static var failures = 0

    static func check(_ description: String, _ condition: @autoclosure () -> Bool) {
        print("\(condition() ? "PASS" : "FAIL")  \(description)")
        if !condition() { failures += 1 }
    }

    static func scratch(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-backup-test-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func main() {
        let root = scratch("root")
        defer { try? FileManager.default.removeItem(at: root) }
        everySectionRoundTrips(in: root)
        chatHistoryMerges(in: root)
        oldFilesImport(in: root)
        unknownSectionsAreSkipped(in: root)
        recordsFromNewerBuildsAreDropped()
        importRulesKeepConsent()
        mergeAndReplace()
        secretsSeal(in: root)
        autoExport()
        homePathsTravelPortable()
        reportNamesWhatItLeft()
        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Fixtures

    static let connectionID = UUID()
    static let agentID = UUID()
    static let serverID = UUID()
    static let actionID = UUID()

    static let agents: AgentsBackup = {
        let agent = AgentProfile(
            id: agentID, name: "Researcher", color: "teal", instructions: "Cite sources.",
            model: .api(connection: connectionID, model: "gpt-5", effort: "high"), directory: "~/Projects/notes",
            disabledSkills: ["deploy"], runtime: AgentRuntime(kind: .codex, command: "npx", arguments: ["-y", "codex"]),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.25))
        let schedule = AgentSchedule(
            agentID: agentID, name: "Morning digest", prompt: "Summarise the inbox.", noteTitle: "Digest",
            isEnabled: true, createdAt: Date(timeIntervalSince1970: 1_700_000_100.5))
        return AgentsBackup(
            agents: FullBackupList([agent]), schedules: FullBackupList([schedule]), scheduleCapUSD: 2.5,
            memories: [agentID.uuidString.lowercased(): "# Memory\n- likes tea"], quickAIAgent: agentID,
            chatAgent: nil)
    }()

    static let mcp: MCPBackup = {
        MCPBackup(
            servers: FullBackupList([
                MCPServer(
                    id: serverID, name: "Files", slug: "files",
                    transport: .stdio(command: "npx", arguments: ["-y", "fs-mcp"], environmentKeys: ["ROOT"]),
                    isEnabled: true, trust: .always),
                MCPServer(name: "Docs", slug: "docs", isEnabled: false)
            ]),
            consents: FullBackupConsents([.mcpEnabled]))
    }()

    static let ai: AIBackup = {
        AIBackup(
            connections: FullBackupList([
                AIConnection(
                    id: connectionID, name: "OpenRouter", provider: .openRouter, models: ["a", "b"],
                    reasoningOptions: ["a": .thinkingSwitch])
            ]),
            defaultModel: .api(connection: connectionID, model: "a", effort: nil), webSearch: true,
            choices: false, systemPrompt: "Be brief.", systemPromptEnabled: true, retentionDays: 30,
            opensTo: 1, newChatAfterMinutes: 15, toolRounds: 8, shownModels: ["api:x": ["a"]],
            disabledRoutes: ["appleIntelligence"], installedProviders: ["codex"],
            installedOverrides: ["claude": InstalledAIOverride(commandPath: "/opt/bin/claude", environmentNames: ["K"])],
            webSearchEngines: .standard, chatAutoArchiveDays: 30, chatFloatsOnTop: true,
            consents: FullBackupConsents([.aiEnabled, .installedAITools, .chatFinishNotifications]))
    }()

    static let voice: VoiceBackup = {
        var modes = VoiceModeSettings()
        modes.custom = [VoiceMode(name: "Formal", instructions: "Rewrite formally.")]
        modes.apps = ["com.apple.mail": "plain"]
        return VoiceBackup(
            dictationModel: .api(connection: connectionID, model: "flash", effort: nil), cleanup: false,
            vocabulary: "Redcast, Tinycast", languages: ["ru", "en"], appContext: "screenshot", modes: modes,
            askMode: "pushToTalk", askModel: nil, askAgent: agentID, dictationMode: "toggle", dictationLanguage: "ru",
            dictationAdaptsCapitalization: true, dictationLiveInsertion: false, dictationIdleReleaseMinutes: 5,
            consents: FullBackupConsents([.cloudDictation, .dictationAppScreenshot]))
    }()

    static let quickActions: QuickActionsBackup = {
        QuickActionsBackup(
            actions: FullBackupList([
                CustomQuickAction(
                    id: actionID, name: "Tweetify", instructions: "Make it a tweet: {clipboard}",
                    createdAt: Date(timeIntervalSince1970: 1_700_000_200))
            ]),
            previews: ["fixGrammar": false], language: "ru", instructions: ["summarize": "Three bullets."],
            model: .appleIntelligence, modelOverrides: [actionID.uuidString: .claude(model: "opus", effort: nil)],
            consents: FullBackupConsents([.quickActionsEnabled]))
    }()

    static let extensions: ExtensionsBackup = {
        ExtensionsBackup(
            extensions: FullBackupList([
                .init(
                    name: "github", title: "GitHub", author: "raycast", owner: "raycast", commitSHA: "abc123",
                    preferences: ["defaultRepo": .string("tinycast"), "showDrafts": .bool(true), "limit": .number(20),
                        "editor": .application("/Applications/Zed.app")],
                    appearance: ExtensionAppearance(symbol: "star", tint: .teal), backgroundCommands: ["Unread"],
                    menuBarCommands: ["Unread", "Reviews"])
            ]),
            aiModel: .api(connection: connectionID, model: "b", effort: nil),
            consents: FullBackupConsents([.extensionsEnabled]))
    }()

    static let more: MoreBackup = {
        MoreBackup(
            hotkeys: FullBackupList([
                .init(kind: .dictation, id: nil, binding: .doubleModifier(.rightOption)),
                .init(
                    kind: .agent, id: agentID.uuidString,
                    binding: .combo(.init(carbonKeyCode: 0, carbonModifiers: 0x1900))),
                .init(kind: .snippet, id: "Signature", binding: .doubleTap(.control))
            ]),
            fallbackOrder: ["command:quick-ai", "command:run-shell-command"],
            disabledFallbacks: ["command:define"], hiddenMeetingCalendars: ["cal-1"], meetingBrowser: "com.google.Chrome",
            screenAwarenessDestination: "quickAI", agentSessionsEnabled: true,
            agentSessionsTerminal: "com.mitchellh.ghostty",
            agentStatusMenuBar: true, consents: FullBackupConsents([.screenAwarenessEnabled, .snippetsEnabled]))
    }()

    static let chats: ChatHistoryBackup = {
        ChatHistoryBackup(
            conversations: 2, chatAgents: [UUID().uuidString.lowercased(): agentID.uuidString.lowercased()],
            personalChats: [UUID().uuidString.lowercased()])
    }()

    // MARK: - Round trip

    /// Each section through the real layout, a sealed `.tinycast` and a fresh extract.
    static func everySectionRoundTrips(in root: URL) {
        let source = root.appendingPathComponent("source")
        let bundle = BackupBundle(root: source)
        try? bundle.prepare([])
        try? bundle.writeManifest(BackupManifest(appVersion: "test", createdAt: Date(), counts: [:]))
        let layout = FullBackupLayout(bundleRoot: source)
        try? layout.prepare()
        var contents = FullBackupContents()
        func put<P: Encodable>(_ payload: P, _ section: FullBackupSection, count: Int) {
            try? layout.write(payload, for: section)
            contents.sections[section.rawValue] = .init(version: section.version, count: count)
        }
        put(agents, .agents, count: agents.count)
        put(mcp, .mcpServers, count: mcp.count)
        put(ai, .ai, count: ai.count)
        put(voice, .voice, count: voice.count)
        put(quickActions, .quickActions, count: quickActions.count)
        put(extensions, .extensions, count: extensions.count)
        put(more, .more, count: more.count)
        put(chats, .chatHistory, count: chats.count)
        let folders = Data(#"{"version":1,"folders":[{"id":"\#(UUID().uuidString)","name":"Work"}],"chats":{}}"#.utf8)
        try? folders.write(to: layout.chatFoldersURL)
        try? FileManager.default.createDirectory(at: layout.chatsDirectory, withIntermediateDirectories: true)
        try? Data(#"{"chats":{}}"#.utf8).write(to: layout.chatPlacementsURL)
        try? layout.writeContents(contents)

        let file = root.appendingPathComponent("round.tinycast")
        let opened = root.appendingPathComponent("opened")
        do {
            try BackupArchive.seal(directory: source, into: file)
            try BackupArchive.open(file: file, into: opened)
        } catch {
            check("seal and open a full backup (\(error))", false)
            return
        }
        check("the upstream manifest still reads", (try? BackupBundle(root: opened).readManifest()) != nil)
        backupOpensUnderEitherExtension(sealed: file, in: root)
        let back = FullBackupLayout(bundleRoot: opened)
        let preview = back.preview()
        check(
            "the preview offers every section",
            Set(preview.available.keys) == Set(FullBackupSection.allCases))
        check("the preview counts agents", preview.available[.agents] == 1)
        check("agents round-trip", back.read(AgentsBackup.self, for: .agents) == agents)
        check(
            "an agent keeps its skills, folder, runtime and colour",
            back.read(AgentsBackup.self, for: .agents)?.agents?.items.first.map {
                $0.disabledSkills == ["deploy"] && $0.directory == "~/Projects/notes" && $0.runtime?.command == "npx"
                    && $0.color == "teal"
            } == true)
        check(
            "schedules keep their state in the file",
            back.read(AgentsBackup.self, for: .agents)?.schedules?.items.first?.isEnabled == true)
        check("MCP servers round-trip", back.read(MCPBackup.self, for: .mcpServers) == mcp)
        check("AI connections round-trip", back.read(AIBackup.self, for: .ai) == ai)
        check("voice modes round-trip", back.read(VoiceBackup.self, for: .voice) == voice)
        check(
            "quick actions round-trip",
            back.read(QuickActionsBackup.self, for: .quickActions) == quickActions)
        check("extensions round-trip", back.read(ExtensionsBackup.self, for: .extensions) == extensions)
        check("more shortcuts round-trip", back.read(MoreBackup.self, for: .more) == more)
        check("chat links round-trip", back.read(ChatHistoryBackup.self, for: .chatHistory) == chats)
        check(
            "AI Chat's folders travel with the AI section, its chats' settings with the history",
            (try? Data(contentsOf: back.chatFoldersURL)) == folders
                && FileManager.default.fileExists(atPath: back.chatPlacementsURL.path))
        let text = (try? String(contentsOf: back.payloadURL(.extensions), encoding: .utf8)) ?? ""
        check(
            "an app preference is stored by its path, not as a bare string",
            text.contains("\"application\""))
    }

    // MARK: - Chat history

    static func makeChatDatabase(at url: URL, ids: [String], extraColumn: Bool) {
        var database: OpaquePointer?
        sqlite3_open(url.path, &database)
        let extra = extraColumn ? ", folder TEXT" : ""
        sqlite3_exec(database, "CREATE TABLE conversations(id TEXT PRIMARY KEY, title TEXT\(extra));", nil, nil, nil)
        sqlite3_exec(
            database, "CREATE TABLE messages(id TEXT PRIMARY KEY, conversation_id TEXT, text TEXT);", nil, nil, nil)
        for id in ids {
            sqlite3_exec(database, "INSERT INTO conversations(id, title) VALUES('\(id)', 'Chat \(id)');", nil, nil, nil)
            sqlite3_exec(
                database, "INSERT INTO messages VALUES('m-\(id)', '\(id)', 'hello from \(id)');", nil, nil, nil)
        }
        sqlite3_close(database)
    }

    static func chatHistoryMerges(in root: URL) {
        let live = root.appendingPathComponent("live-chats.sqlite3")
        makeChatDatabase(at: live, ids: ["a", "b"], extraColumn: false)
        let layout = FullBackupLayout(bundleRoot: root.appendingPathComponent("chat-bundle"))
        try? layout.prepare()
        try? FileManager.default.createDirectory(at: layout.chatsDirectory, withIntermediateDirectories: true)
        do {
            try FullBackupChatArchive.snapshot(live, to: layout.chatDatabaseURL)
        } catch {
            check("a chat database snapshots (\(error))", false)
            return
        }
        check(
            "the snapshot holds every conversation",
            FullBackupChatArchive.conversationCount(at: layout.chatDatabaseURL) == 2)
        let target = root.appendingPathComponent("target-chats.sqlite3")
        makeChatDatabase(at: target, ids: ["b", "c"], extraColumn: true)
        let added = (try? FullBackupChatArchive.merge(layout.chatDatabaseURL, into: target)) ?? -1
        check("merge adds only the conversation this Mac lacks", added == 1)
        check("merge keeps this Mac's own", FullBackupChatArchive.conversationCount(at: target) == 3)
        let again = (try? FullBackupChatArchive.merge(layout.chatDatabaseURL, into: target)) ?? -1
        check("merging the same file twice adds nothing", again == 0)
    }

    // MARK: - Version tolerance

    /// A file from before the fork's sections: upstream's categories only, and the fork offers nothing.
    static func oldFilesImport(in root: URL) {
        let old = root.appendingPathComponent("old")
        let bundle = BackupBundle(root: old)
        try? bundle.prepare([.configuration])
        try? bundle.write(Data(#"{"favoriteApps":["com.apple.Safari"]}"#.utf8), to: bundle.settingsURL)
        try? bundle.writeManifest(BackupManifest(appVersion: "1.0", createdAt: Date(), counts: ["configuration": 1]))
        let file = root.appendingPathComponent("old.tinycast")
        let opened = root.appendingPathComponent("old-opened")
        try? BackupArchive.seal(directory: old, into: file)
        try? BackupArchive.open(file: file, into: opened)
        let manifest = try? BackupBundle(root: opened).readManifest()
        check("an old file's manifest still reads", manifest?.categories == [.configuration])
        let layout = FullBackupLayout(bundleRoot: opened)
        check("an old file has no fork contents", layout.readContents() == nil)
        check("an old file's preview is empty", layout.preview().isEmpty && layout.preview().skipped.isEmpty)
    }

    static func unknownSectionsAreSkipped(in root: URL) {
        var contents = FullBackupContents()
        contents.sections = [
            "agents": .init(version: 99, count: 1), "tags": .init(version: 1, count: 4),
            "voice": .init(version: 1, count: 2)
        ]
        let preview = FullBackupPreview(contents)
        check("a known section of a known version is offered", preview.available == [.voice: 2])
        check(
            "a newer version and an unknown name are skipped by name",
            preview.skipped == ["agents", "tags"])
        var newer = FullBackupContents()
        newer.format = FullBackupContents.currentFormat + 1
        newer.sections = ["voice": .init(version: 1, count: 2)]
        check("a newer format skips every section", FullBackupPreview(newer).available.isEmpty)
        let layout = FullBackupLayout(bundleRoot: root.appendingPathComponent("unknown"))
        try? layout.prepare()
        try? Data(#"{"format":1,"sections":{"voice":{"version":1,"count":0}},"future":true}"#.utf8)
            .write(to: layout.contentsURL)
        check("contents with fields this build lacks still decode", layout.preview().available[.voice] == 0)
    }

    static func recordsFromNewerBuildsAreDropped() {
        let record = #"{"id":"\#(UUID().uuidString)","name":"A","instructions":"x","previewsResult":true,"createdAt":0}"#
        let json = "[\(record),{\"id\":7}]"
        let list = try? JSONDecoder().decode(FullBackupList<CustomQuickAction>.self, from: Data(json.utf8))
        check("an unreadable record is dropped, the rest kept", list?.items.count == 1 && list?.dropped == 1)
        let consents = try? JSONDecoder().decode(FullBackupConsents.self, from: Data(#"["aiEnabled","teleport"]"#.utf8))
        check("an unknown consent name is dropped", consents?.on == [.aiEnabled])
        let partial = try? JSONDecoder().decode(AIBackup.self, from: Data(#"{"webSearch":true}"#.utf8))
        check(
            "a section with only some fields decodes",
            partial?.webSearch == true && partial?.connections == nil)
    }

    // MARK: - Import rules

    static func importRulesKeepConsent() {
        let paused = FullBackupImportPolicy.pausing(agents.schedules?.items ?? [])
        check("every schedule lands paused", paused.schedules.allSatisfy { !$0.isEnabled })
        check("the summary names the schedules that ran", paused.paused == ["Morning digest"])
        let servers = FullBackupImportPolicy.disabling(mcp.servers?.items ?? [])
        check("every MCP server lands off", servers.servers.allSatisfy { !$0.isEnabled })
        check("the summary names only the servers that were on", servers.disabled == ["Files"])
        check("trust and transport travel unchanged", servers.servers.first?.trust == .always)
        let schedule = agents.schedules?.items.first
        let running = FullBackupImportPolicy.pausing(agents.schedules?.items ?? [], runningHere: [schedule!.id])
        check(
            "a schedule this Mac already runs keeps running",
            running.schedules.first?.isEnabled == true && running.paused.isEmpty)
        let kept = FullBackupImportPolicy.disabling(mcp.servers?.items ?? [], enabledHere: [serverID])
        check(
            "a server already on here stays on",
            kept.servers.first?.isEnabled == true && kept.disabled.isEmpty)
        let launches = FullBackupImportPolicy.launches(agents: agents, mcp: mcp, ai: ai)
        check("launchable commands are listed before import", launches.count == 3)
        check("an ACP agent's command is named", launches.contains("Researcher: npx -y codex"))
        check("a stdio server's command is named", launches.contains("Files: npx -y fs-mcp"))
        check("an installed tool's path is named", launches.contains("claude: /opt/bin/claude"))
        var codex = ai
        codex.connections = FullBackupList([
            AIConnection(name: "ChatGPT Plus", provider: .codexPlan), AIConnection(name: "Keys", provider: .openAI)
        ])
        check(
            "a ChatGPT plan connection travels and asks to sign in again",
            FullBackupImportPolicy.signsInAgain(codex) == ["ChatGPT Plus"])
        let widened = FullBackupImportPolicy.appContext(recorded: .screenshot, current: .title)
        check("a wider screen context is kept back", widened.level == .title && widened.widened)
        let narrowed = FullBackupImportPolicy.appContext(recorded: .off, current: .title)
        check("a narrower screen context applies", narrowed.level == .off && !narrowed.widened)
        check(
            "an imported chat on Allow Everything lands on Agent's Settings",
            FullBackupImportPolicy.chatAccess(.allowEverything) == nil)
        check(
            "while Ask Every Time, which only narrows, and the default land as they were",
            FullBackupImportPolicy.chatAccess(.askEveryTime) == .askEveryTime
                && FullBackupImportPolicy.chatAccess(nil) == nil)
        let background = FullBackupImportPolicy.backgroundCommands(extensions.extensions?.items ?? [])
        check(
            "background and menu-bar commands are named once each",
            background == ["GitHub › Reviews", "GitHub › Unread"])
        let fallbacks = FullBackupImportPolicy.disabledFallbacks(
            recorded: ["command:define"], current: ["command:run-shell-command"])
        check(
            "an import never re-arms a fallback switched off here",
            fallbacks == ["command:define", "command:run-shell-command"])
        let review = FullBackupImportPolicy.consentsToReview([mcp.consents, ai.consents, nil]) { $0 == .aiEnabled }
        check(
            "consents recorded on and still off here are listed",
            review == [.mcpEnabled, .installedAITools, .chatFinishNotifications])
    }

    static func mergeAndReplace() {
        struct Item: Identifiable, Equatable { let id: Int }
        let merge = FullBackupMerge.plan(
            incoming: [Item(id: 2), Item(id: 3)], existing: [Item(id: 1), Item(id: 2)], mode: .merge)
        check(
            "merge keeps what only this Mac has",
            merge.removals.isEmpty && merge.upserts.map(\.id) == [2, 3])
        let replace = FullBackupMerge.plan(
            incoming: [Item(id: 2), Item(id: 3)], existing: [Item(id: 1), Item(id: 2)], mode: .replace)
        check("replace removes what the file lacks", replace.removals == [1])
        check("sections that can't replace say so", !FullBackupSection.voice.descriptor.replaces)
        check("chat history never replaces", !FullBackupSection.chatHistory.descriptor.replaces)
        check("chat history is opt-in", !FullBackupSection.exportedByDefault.contains(.chatHistory))
    }

    // MARK: - Secrets

    static func secretsSeal(in root: URL) {
        let secrets = FullBackupSecrets(
            aiKeys: [connectionID.uuidString: "sk-or-v1-SECRETKEY"], aiHeaders: [connectionID.uuidString: ["X-Org": "o1"]],
            openRouterManagementKeys: nil,
            mcp: [serverID.uuidString: #"{"headerValue":"Bearer MCPTOKEN","environment":{}}"#],
            webSearchKeys: ["brave": "BRAVEKEY"], installedEnvironment: ["claude": ["ANTHROPIC_API_KEY": "ENVKEY"]],
            extensions: [
                "github": .init(passwords: ["token": "GHTOKEN"], oauthTokens: ["github": #"{"access":"OAUTH"}"#])
            ])
        guard let plaintext = try? FullBackupLayout.encoder.encode(secrets),
            let sealed = try? FullBackupCipher.seal(
                plaintext, passphrase: "correct horse", count: secrets.count, iterations: 100_000)
        else {
            check("secrets seal", false)
            return
        }
        check(
            "the header names its KDF and cipher",
            sealed.header.kdf == "pbkdf2-sha256" && sealed.header.cipher == "aes-256-gcm")
        check("the salt is random and long enough", sealed.header.salt.count == 16)
        check(
            "the sealed bytes hold no secret",
            sealed.sealed.range(of: Data("SECRETKEY".utf8)) == nil)
        let opened = try? FullBackupCipher.open(sealed.sealed, header: sealed.header, passphrase: "correct horse")
        check(
            "the right passphrase opens them",
            opened.flatMap { try? JSONDecoder().decode(FullBackupSecrets.self, from: $0) } == secrets)
        var wrong: FullBackupCipher.CipherError?
        do {
            _ = try FullBackupCipher.open(sealed.sealed, header: sealed.header, passphrase: "wrong horse")
        } catch { wrong = error }
        check("a wrong passphrase is refused", wrong == .wrongPassphrase)
        var lowered = sealed.header
        lowered.iterations = 100_001
        var tampered: FullBackupCipher.CipherError?
        do {
            _ = try FullBackupCipher.open(sealed.sealed, header: lowered, passphrase: "correct horse")
        } catch { tampered = error }
        check("an edited header fails authentication", tampered == .wrongPassphrase)
        var weak = sealed.header
        weak.iterations = 1_000
        var refused: FullBackupCipher.CipherError?
        do {
            _ = try FullBackupCipher.open(sealed.sealed, header: weak, passphrase: "correct horse")
        } catch { refused = error }
        check("a header asking for too few iterations is refused", refused == .unsupported)
        let again = try? FullBackupCipher.seal(plaintext, passphrase: "correct horse", count: 1, iterations: 100_000)
        check("two seals never share a salt", again?.header.salt != sealed.header.salt)
        check("the default work factor is OWASP's", FullBackupCipher.iterations >= 600_000)

        let source = root.appendingPathComponent("sealed-source")
        let layout = FullBackupLayout(bundleRoot: source)
        try? BackupBundle(root: source).prepare([])
        try? BackupBundle(root: source).writeManifest(BackupManifest(appVersion: "t", createdAt: Date(), counts: [:]))
        try? layout.prepare()
        try? layout.writeSecrets(sealed.sealed)
        try? layout.writeContents(FullBackupContents(sections: [:], secrets: sealed.header))
        let file = root.appendingPathComponent("sealed.tinycast")
        let extracted = root.appendingPathComponent("sealed-opened")
        try? BackupArchive.seal(directory: source, into: file)
        try? BackupArchive.open(file: file, into: extracted)
        let back = FullBackupLayout(bundleRoot: extracted)
        check("the preview reports sealed secrets", back.preview().secrets?.count == secrets.count)
        let reopened = back.readSecrets().flatMap {
            try? FullBackupCipher.open($0, header: sealed.header, passphrase: "correct horse")
        }
        check("secrets survive the archive", reopened == plaintext)
        let leaked = ["SECRETKEY", "MCPTOKEN", "BRAVEKEY", "ENVKEY", "GHTOKEN", "OAUTH"].filter { needle in
            files(under: extracted).contains { (try? String(contentsOf: $0, encoding: .utf8))?.contains(needle) == true }
        }
        check("no extracted file holds a secret in the clear", leaked.isEmpty)
    }

    static func files(under root: URL) -> [URL] {
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).filter { !$0.hasDirectoryPath }
    }

    // MARK: - Paths

    /// Upstream's rule for a file people share: no `/Users/<name>` in it.
    static func homePathsTravelPortable() {
        let home = "/Users/alexey"
        check(
            "a path under home travels as ~",
            FullBackupPaths.portable("/Users/alexey/Code", home: home) == "~/Code")
        check(
            "a path outside home is kept",
            FullBackupPaths.portable("/opt/bin/codex", home: home) == "/opt/bin/codex")
        check(
            "a sibling user's path is kept",
            FullBackupPaths.portable("/Users/alexeyz/x", home: home) == "/Users/alexeyz/x")
        check(
            "~ comes back under this Mac's home",
            FullBackupPaths.local("~/Code", home: "/Users/a") == "/Users/a/Code")
        let agent = AgentProfile(
            name: "A", directory: "/Users/alexey/Projects/x",
            runtime: AgentRuntime(
                kind: .custom, command: "/Users/alexey/bin/acp", arguments: ["--root", "/Users/alexey/x"]))
        let server = MCPServer(
            name: "S",
            transport: .stdio(command: "/Users/alexey/bin/mcp", arguments: ["/Users/alexey/data"], environmentKeys: []))
        let portable: (String) -> String = { FullBackupPaths.portable($0, home: home) }
        let payload = AgentsBackup(agents: FullBackupList([FullBackupPaths.agent(agent, portable)]))
        let servers = MCPBackup(servers: FullBackupList([FullBackupPaths.server(server, portable)]))
        let text = [try? FullBackupLayout.encoder.encode(payload), try? FullBackupLayout.encoder.encode(servers)]
            .compactMap { $0.flatMap { String(bytes: $0, encoding: .utf8) } }.joined()
        check(
            "an agent's folder and command and a server's command carry no /Users",
            !text.contains("/Users"))
        let local: (String) -> String = { FullBackupPaths.local($0, home: "/Users/b") }
        let back = FullBackupPaths.agent(FullBackupPaths.agent(agent, portable), local)
        check("an agent's folder lands under this Mac's home", back.directory == "/Users/b/Projects/x")
        check(
            "an extension's file preference travels portable",
            FullBackupPaths.value(.string("/Users/alexey/a.txt"), portable) == .string("~/a.txt"))
    }

    // MARK: - On quit

    /// Redcast writes `.redcast`; a `.tinycast` from upstream or an older build opens the same.
    static func backupOpensUnderEitherExtension(sealed file: URL, in root: URL) {
        let manifest = { (name: String) -> BackupManifest? in
            let copy = root.appendingPathComponent("either.\(name)")
            let opened = root.appendingPathComponent("opened-\(name)")
            try? FileManager.default.copyItem(at: file, to: copy)
            guard (try? BackupArchive.open(file: copy, into: opened)) != nil else { return nil }
            return try? BackupBundle(root: opened).readManifest()
        }
        let redcast = manifest("redcast")
        check("a .redcast backup opens", redcast?.appVersion == "test")
        check("a .tinycast backup opens the same", manifest("tinycast")?.appVersion == redcast?.appVersion)
    }

    static func autoExport() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        check("a first export is due", FullBackupAutoExportPolicy.isDue(lastExport: nil, now: now, days: 7))
        check(
            "a recent export is not due",
            !FullBackupAutoExportPolicy.isDue(lastExport: now.addingTimeInterval(-86_400), now: now, days: 7))
        check(
            "an old export is due",
            FullBackupAutoExportPolicy.isDue(lastExport: now.addingTimeInterval(-8 * 86_400), now: now, days: 7))
        let name = FullBackupAutoExportPolicy.fileName(at: now, timeZone: TimeZone(identifier: "UTC")!)
        check("the file name sorts by time", name == "Redcast-Auto-2027-01-15-080000.redcast")
        let names = [
            "Tinycast-Auto-2027-01-01-080000.tinycast", "Redcast-Auto-2027-01-03-080000.redcast",
            "Tinycast-Auto-2027-01-02-080000.tinycast", "Mine.tinycast", "Mine.redcast",
            "Tinycast-Auto-notes.txt", "Redcast-Auto-2027-01-04-080000.tinycast"
        ]
        check(
            "pruning keeps the newest and never touches the user's files",
            FullBackupAutoExportPolicy.pruned(names, keeping: 2) == ["Tinycast-Auto-2027-01-01-080000.tinycast"])
        check(
            "older .tinycast exports age out by their time, after the newer .redcast ones",
            FullBackupAutoExportPolicy.pruned(names, keeping: 1)
                == ["Tinycast-Auto-2027-01-02-080000.tinycast", "Tinycast-Auto-2027-01-01-080000.tinycast"])
    }

    static func reportNamesWhatItLeft() {
        var report = FullBackupReport()
        report.applied = [.agents: 1]
        report.pausedSchedules = ["Morning digest"]
        report.disabledServers = ["Files"]
        report.consents = [.aiEnabled]
        report.missingExtensions = ["GitHub"]
        report.skippedSections = ["tags"]
        check("the report says each thing it left off", report.sentences.count == 6)
        check("a report with nothing in it says nothing", FullBackupReport().sentences.isEmpty)
    }
}
