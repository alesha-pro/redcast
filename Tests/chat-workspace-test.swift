import Foundation

@main
@MainActor
struct ChatWorkspaceTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() async {
        theFileRoundTrips()
        anOldOrBrokenFileStillLoads()
        unknownFieldsSurviveARewrite()
        deletingAFolderNeverDeletesAChat()
        movesAreExclusiveAndUnarchive()
        theLayoutListsEachChatOnce()
        commandDigitsReachTheFirstTenVisibleRows()
        instructionsComposeAfterTheAppPrompt()
        creativityKeepsTheRestOfTheRequest()
        autoArchiveSparesPinnedOpenAndRecentChats()
        deletionsExpireAfterSixtyDays()
        theStoreWritesOnlyOnChange()
        trashHidesAndRestoreReturns()
        tidyPurgesExpiredAndForgetsStaleEntries()
        await editingAQuestionRewritesTheHistory()
        recallStepsAndRestoresTheDraft()
        branchesCopyUnderNewIDs()
        longMessagesFold()
        toolKindsAndLanguageHues()
        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Fixtures

    static func directory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tinycast-workspace-\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    static func conversation(
        _ title: String, at date: Date, pinned: Bool = false, id: UUID = UUID()
    ) -> ChatConversation {
        ChatConversation(
            id: id, title: title, preview: "", createdAt: date, updatedAt: date, messageCount: 2,
            isPinned: pinned)
    }

    @discardableResult
    static func saved(_ history: ChatHistoryStore, _ text: String, at date: Date = Date()) -> UUID {
        var session = ChatSession(createdAt: date)
        session.append(ChatMessage(role: .user, text: text, sentAt: date))
        session.append(ChatMessage(role: .assistant, text: "answer to \(text)", sentAt: date))
        history.save(session)
        return session.id
    }

    static func coordinator(_ root: URL) -> (ChatWorkspaceCoordinator, FakeHost) {
        let history = ChatHistoryStore(directory: root)
        let defaults = UserDefaults(suiteName: "tinycast-workspace-\(UUID().uuidString)")!
        let workspace = ChatWorkspaceCoordinator(
            store: ChatWorkspaceStore(directory: root),
            settings: ChatWorkspaceSettings(defaults: defaults), history: history,
            chats: AIChatSurfacesState(history: history))
        let host = FakeHost()
        workspace.host = host
        workspace.prepare()
        history.load()
        return (workspace, host)
    }

    // MARK: - Persistence

    static func theFileRoundTrips() {
        var workspace = ChatWorkspace()
        let folder = workspace.createFolder(named: "  Research  ", hue: .green, symbol: "book.fill")!
        workspace.updateFolder(folder.id) {
            $0.instructions = "Cite sources."
            $0.agentID = UUID()
            $0.isCollapsed = true
        }
        let chat = UUID()
        workspace.move(chat, to: folder.id)
        workspace.setInstructions("Answer in Russian.", of: chat)
        workspace.setCreativity(.high, of: chat)
        let other = UUID()
        workspace.trash(other, title: "Old chat", at: Date(timeIntervalSince1970: 1_000))
        let reread = ChatWorkspace(data: workspace.data)
        expect(reread == workspace, "a written workspace reads back equal")
        expect(reread.folders.first?.name == "Research", "a folder name is trimmed")
        expect(reread.folder(id: folder.id)?.hue == .green, "a folder keeps its colour")
        expect(reread.placement(of: chat).creativity == .high, "a chat keeps its creativity")
        expect(reread.trashed.first?.title == "Old chat", "a deleted chat keeps its title")
    }

    static func anOldOrBrokenFileStillLoads() {
        expect(ChatWorkspace(data: Data()) == ChatWorkspace(), "no file is an empty workspace")
        expect(ChatWorkspace(data: Data("not json".utf8)) == ChatWorkspace(), "garbage is an empty workspace")
        let good = UUID()
        let json = """
            {"folders": [{"id": "\(good.uuidString)", "name": "Work", "color": "teal"},
                         {"name": "no id"}, {"id": "\(good.uuidString)", "name": "duplicate"}],
             "chats": {"not-a-uuid": {"folder": "\(good.uuidString)"},
                       "\(UUID().uuidString)": {"creativity": "extreme", "archivedAt": "yesterday"}}}
            """
        let workspace = ChatWorkspace(data: Data(json.utf8))
        expect(workspace.folders.map(\.name) == ["Work"], "a bad or duplicate folder is dropped alone")
        expect(
            workspace.folders.first?.hue == RaycastHue.stable(for: good),
            "an unknown colour reads as the folder's derived one")
        expect(workspace.folders.first?.symbol == ChatFolder.symbols[0], "a missing icon is the default")
        expect(workspace.placements.isEmpty, "entries with nothing readable are dropped")
    }

    static func unknownFieldsSurviveARewrite() {
        let folder = UUID()
        let chat = UUID()
        let json = """
            {"version": 7, "future": {"a": 1},
             "folders": [{"id": "\(folder.uuidString)", "name": "Work", "color": "red",
                          "symbol": "star.fill", "sortKey": 3}],
             "chats": {"\(chat.uuidString)": {"folder": "\(folder.uuidString)", "starred": true}}}
            """
        var workspace = ChatWorkspace(data: Data(json.utf8))
        workspace.setInstructions("Be brief.", of: chat)
        let object = JSONValue(data: workspace.data)?.objectValue
        expect(object?["future"] == .object(["a": .number(1)]), "an unknown top-level field is kept")
        let folders = object?["folders"]?.arrayValue
        expect(folders?.first?.objectValue?["sortKey"] == .number(3), "an unknown folder field is kept")
        let entry = object?["chats"]?.objectValue?[chat.uuidString]?.objectValue
        expect(entry?["starred"] == .bool(true), "an unknown chat field is kept")
        expect(entry?["instructions"] == .string("Be brief."), "the new field is written beside it")
        workspace.move(chat, to: nil)
        workspace.setInstructions(nil, of: chat)
        expect(workspace.placements[chat] != nil, "an entry holding only unknown fields is not dropped")
    }

    // MARK: - Folders and moves

    static func deletingAFolderNeverDeletesAChat() {
        var workspace = ChatWorkspace()
        let work = workspace.createFolder(named: "Work")!
        let home = workspace.createFolder(named: "Home")!
        let a = UUID(), b = UUID(), c = UUID()
        workspace.move(a, to: work.id)
        workspace.move(b, to: work.id)
        workspace.move(c, to: home.id)
        workspace.setInstructions("Keep me.", of: b)
        workspace.deleteFolder(work.id)
        expect(workspace.folders.map(\.id) == [home.id], "only the deleted folder goes")
        expect(workspace.folderID(of: a) == nil && workspace.folderID(of: b) == nil, "its chats go back to Recent")
        expect(workspace.placements[a] == nil, "an entry left empty is dropped, the chat itself untouched")
        expect(workspace.placement(of: b).instructions == "Keep me.", "a chat's own settings survive")
        expect(workspace.folderID(of: c) == home.id, "chats in other folders stay put")
        expect(work.color != home.color, "two new folders get two colours")
    }

    static func movesAreExclusiveAndUnarchive() {
        var workspace = ChatWorkspace()
        let work = workspace.createFolder(named: "Work")!
        let chat = UUID()
        workspace.archive(chat, at: Date())
        workspace.move(chat, to: work.id)
        expect(!workspace.isArchived(chat), "filing an archived chat brings it back")
        workspace.move(chat, to: UUID())
        expect(workspace.folderID(of: chat) == work.id, "an unknown folder leaves the chat where it was")
        workspace.move(chat, to: nil)
        expect(workspace.folderID(of: chat) == nil, "nil is Recent")
        expect(workspace.createFolder(named: "   ") == nil, "a blank folder name is refused")
        workspace.updateFolder(work.id) { $0.name = "" }
        expect(workspace.folder(id: work.id)?.name == "Work", "a blank rename keeps the old name")
    }

    static func theLayoutListsEachChatOnce() {
        let now = Date()
        var workspace = ChatWorkspace()
        let work = workspace.createFolder(named: "Work")!
        let pinned = conversation("pinned", at: now, pinned: true)
        let filed = conversation("filed", at: now)
        let recent = conversation("recent", at: now)
        let archived = conversation("archived", at: now)
        let deleted = conversation("deleted", at: now)
        let pinnedAndFiled = conversation("pinned and filed", at: now, pinned: true)
        workspace.move(filed.id, to: work.id)
        workspace.move(pinnedAndFiled.id, to: work.id)
        workspace.archive(archived.id, at: now)
        workspace.trash(deleted.id, title: "deleted", at: now)
        let all = [pinned, filed, recent, archived, deleted, pinnedAndFiled]
        let layout = ChatSidebarLayout(conversations: all, workspace: workspace, dayTitle: { _ in "Today" })
        expect(layout.pinned.map(\.title) == ["pinned", "pinned and filed"], "pinned chats sit above all")
        expect(layout.folders.first?.chats.map(\.title) == ["filed"], "a folder lists its unpinned chats")
        expect(layout.recent.flatMap(\.chats).map(\.title) == ["recent"], "Recent holds the rest")
        expect(layout.archived.map(\.title) == ["archived"], "archived chats are only in Archived")
        let listed = layout.pinned + layout.folders.flatMap(\.chats) + layout.recent.flatMap(\.chats)
            + layout.archived
        expect(listed.count == Set(listed.map(\.id)).count, "no chat is listed twice")
        expect(!listed.contains { $0.id == deleted.id }, "a deleted chat is in no section")
        let search = ChatSidebarLayout(
            conversations: all, workspace: workspace, matching: [archived.id, deleted.id, recent.id],
            dayTitle: { _ in "Today" })
        expect(
            search.results?.map(\.title) == ["recent", "archived"],
            "search reaches archived chats, never deleted ones")
    }

    static func commandDigitsReachTheFirstTenVisibleRows() {
        let now = Date()
        var workspace = ChatWorkspace()
        let folded = workspace.createFolder(named: "Folded")!
        workspace.updateFolder(folded.id) { $0.isCollapsed = true }
        let open = workspace.createFolder(named: "Open")!
        let pinned = conversation("p", at: now, pinned: true)
        let hidden = conversation("in folded", at: now)
        let shown = conversation("in open", at: now)
        workspace.move(hidden.id, to: folded.id)
        workspace.move(shown.id, to: open.id)
        let recents = (0..<12).map { conversation("r\($0)", at: now) }
        let layout = ChatSidebarLayout(
            conversations: [pinned, hidden, shown] + recents, workspace: workspace, dayTitle: { _ in "Today" })
        let order = layout.shortcutOrder
        expect(order.first == pinned.id && order[1] == shown.id, "pinned first, then open folders' chats")
        expect(!order.contains(hidden.id), "a folded folder's chats have no digit")
        expect(ChatShortcutIndex.chat(forDigit: "1", in: order) == pinned.id, "⌘1 is the top row")
        expect(ChatShortcutIndex.chat(forDigit: "0", in: order) == order[9], "⌘0 is the tenth")
        expect(ChatShortcutIndex.badge(for: order[9], in: order) == "0", "the tenth row shows 0")
        expect(ChatShortcutIndex.badge(for: order[10], in: order) == nil, "the eleventh shows nothing")
        expect(ChatShortcutIndex.chat(forDigit: "5", in: Array(order.prefix(3))) == nil, "past the list is nothing")
    }

    // MARK: - Instructions and creativity

    static func instructionsComposeAfterTheAppPrompt() {
        expect(ChatInstructions.compose(base: nil) == nil, "nothing to say stays nil")
        expect(ChatInstructions.compose(base: "App.") == "App.", "no folder or chat text leaves the base as is")
        let full = ChatInstructions.compose(
            base: "App.", folderName: "Work", folder: "Folder rule.", chat: " Chat rule. ")
        expect(full?.hasPrefix("App.") == true, "the app's prompt stays first")
        let folderAt = full?.range(of: "Folder rule.")?.lowerBound
        let chatAt = full?.range(of: "Chat rule.")?.lowerBound
        expect(folderAt != nil && chatAt != nil && folderAt! < chatAt!, "the folder's text comes before the chat's")
        expect(full?.contains("“Work”") == true, "the folder is named to the model")
        let off = ChatInstructions.compose(base: nil, chat: "Only this.")
        expect(off?.contains("Only this.") == true, "with the system prompt off a chat's own text still goes")
        expect(ChatInstructions.compose(base: "App.", folder: "  ", chat: "\n") == "App.", "blank text adds nothing")
    }

    static func creativityKeepsTheRestOfTheRequest() {
        expect(ChatCreativity.none.temperature == 0 && ChatCreativity.maximum.temperature == 1.5, "Raycast's scale")
        let request = AIRequest(
            instructions: "i", messages: [AIMessage(role: .user, text: "q")], maxOutputTokens: 99,
            webSearch: true, conversationID: UUID(), forbidsCalls: true)
        let warmed = request.withTemperature(0.7)
        expect(warmed.temperature == 0.7, "the temperature is set")
        expect(
            warmed.withTemperature(nil) == request, "every other field, the loop's included, carries over")
    }

    // MARK: - Archive and Recently Deleted

    static func autoArchiveSparesPinnedOpenAndRecentChats() {
        let now = Date()
        let old = now.addingTimeInterval(-40 * 24 * 60 * 60)
        let idle = conversation("idle", at: old)
        let pinned = conversation("pinned", at: old, pinned: true)
        let open = conversation("open", at: old)
        let fresh = conversation("fresh", at: now)
        var workspace = ChatWorkspace()
        let already = conversation("already", at: old)
        workspace.archive(already.id, at: old)
        let all = [idle, pinned, open, fresh, already]
        let month = ChatAutoArchive.month.chatsToArchive(all, workspace: workspace, now: now, sparing: [open.id])
        expect(month == [idle.id], "only an unpinned, closed, idle chat is archived")
        expect(
            ChatAutoArchive.quarter.chatsToArchive(all, workspace: workspace, now: now, sparing: []).isEmpty,
            "nothing is idle for three months yet")
        expect(
            ChatAutoArchive.never.chatsToArchive(all, workspace: workspace, now: now, sparing: []).isEmpty,
            "Never archives nothing")
    }

    static func deletionsExpireAfterSixtyDays() {
        let now = Date()
        var workspace = ChatWorkspace()
        let expired = UUID(), kept = UUID()
        workspace.trash(expired, title: "a", at: now.addingTimeInterval(-ChatWorkspace.trashLifetime - 1))
        workspace.trash(kept, title: "b", at: now.addingTimeInterval(-ChatWorkspace.trashLifetime + 60))
        expect(workspace.expired(at: now) == [expired], "only a deletion 60 days old expires")
        workspace.prune(keeping: [])
        expect(workspace.isTrashed(kept), "pruning never drops a deleted chat before its purge")
        workspace.restore(kept)
        expect(!workspace.isTrashed(kept) && workspace.trashed.map(\.id) == [expired], "restore takes it back")
    }

    static func theStoreWritesOnlyOnChange() {
        let root = directory("store")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatWorkspaceStore(directory: root)
        store.load()
        expect(!FileManager.default.fileExists(atPath: store.fileURL.path), "loading writes no file")
        store.change { _ in }
        expect(!FileManager.default.fileExists(atPath: store.fileURL.path), "a change that changes nothing writes nothing")
        store.change { $0.createFolder(named: "Work") }
        let reopened = ChatWorkspaceStore(directory: root)
        reopened.load()
        expect(reopened.workspace.folders.map(\.name) == ["Work"], "a change is on disk at once")
        reopened.close()
        expect(reopened.workspace.folders.isEmpty, "closing drops the document from memory")
    }

    static func trashHidesAndRestoreReturns() {
        let root = directory("trash")
        defer { try? FileManager.default.removeItem(at: root) }
        let (workspace, _) = coordinator(root)
        let id = saved(workspace.history, "Delete me")
        let other = saved(workspace.history, "Keep me")
        workspace.history.setPinned(true, id: id)
        workspace.trash(id)
        expect(workspace.history.conversation(id: id) == nil, "a deleted chat leaves every list")
        expect(workspace.history.session(id: id) != nil, "its transcript stays on disk")
        expect(workspace.workspace.trashed.first?.title == "Delete me", "Recently Deleted lists it by title")
        workspace.history.save(workspace.history.session(id: id)!)
        expect(workspace.history.conversation(id: id) == nil, "a late save cannot bring it back")
        let reloaded = ChatHistoryStore(directory: root)
        let again = ChatWorkspaceCoordinator(
            store: ChatWorkspaceStore(directory: root), settings: workspace.settings, history: reloaded,
            chats: AIChatSurfacesState(history: reloaded))
        again.prepare()
        reloaded.load()
        expect(reloaded.conversation(id: id) == nil, "a relaunch keeps it hidden")
        expect(reloaded.conversation(id: other) != nil, "other chats load as before")
        workspace.restore(id)
        expect(workspace.history.conversation(id: id) != nil, "restoring lists it again")
        expect(workspace.history.conversation(id: id)?.isPinned == false, "a restored chat comes back unpinned")
    }

    static func tidyPurgesExpiredAndForgetsStaleEntries() {
        let root = directory("tidy")
        defer { try? FileManager.default.removeItem(at: root) }
        let (workspace, host) = coordinator(root)
        let now = Date()
        let doomed = saved(workspace.history, "Old")
        let idle = saved(workspace.history, "Idle", at: now.addingTimeInterval(-10 * 24 * 60 * 60))
        let live = saved(workspace.history, "Live")
        workspace.trash(doomed, now: now.addingTimeInterval(-ChatWorkspace.trashLifetime - 5))
        let stale = UUID()
        workspace.store.change { $0.setInstructions("gone", of: stale) }
        workspace.settings.autoArchive = .week
        workspace.tidy(now: now)
        expect(workspace.history.session(id: doomed) == nil, "an expired deletion is erased for good")
        expect(host.forgotten == [doomed], "its agent notes and CLI thread are let go")
        expect(workspace.workspace.placements[stale] == nil, "an entry for a vanished chat is forgotten")
        expect(workspace.workspace.isArchived(idle), "an idle chat is archived as history loads")
        expect(!workspace.workspace.isArchived(live), "a recent one is not")
    }

    // MARK: - Editing a sent question

    static func editingAQuestionRewritesTheHistory() async {
        let root = directory("edit")
        defer { try? FileManager.default.removeItem(at: root) }
        let (workspace, _) = coordinator(root)
        let chat = workspace.chats.window
        let provider = ScriptedProvider(rounds: [
            [.text("A1"), .finished], [.text("A2"), .finished], [.text("B1"), .finished]
        ])
        chat.send("Q1", using: provider)
        await settle(chat)
        chat.send("Q2", using: provider)
        await settle(chat)
        chat.draft = "half typed"
        expect(workspace.stepRecall(-1, in: chat) == false, "↑ over a typed draft moves the caret instead")
        chat.draft = ""
        expect(workspace.stepRecall(-1, in: chat), "↑ in an empty composer recalls the last question")
        expect(chat.draft == "Q2", "the newest question comes back")
        expect(workspace.stepRecall(-1, in: chat) && chat.draft == "Q1", "another ↑ steps to an older one")
        chat.draft = "Q1 edited"
        workspace.applyEdit(in: chat)
        chat.send(chat.draft, using: provider)
        await settle(chat)
        expect(chat.session.messages.map(\.text) == ["Q1 edited", "B1"], "the edit replaces what followed")
        expect(provider.requests.last?.messages.map(\.text) == ["Q1 edited"], "only the edit is asked")
        let stored = workspace.history.session(id: chat.session.id)?.messages.map(\.text)
        expect(stored == ["Q1 edited", "B1"], "the stored transcript is rewritten, not spliced")
        expect(workspace.editingMessageID(in: chat) == nil, "sending ends the edit")
    }

    static func recallStepsAndRestoresTheDraft() {
        let q1 = ChatMessage(role: .user, text: "one")
        let a1 = ChatMessage(role: .assistant, text: "reply")
        let q2 = ChatMessage(role: .user, text: "two")
        let messages = [q1, a1, q2]
        var recall = ChatRecall(in: messages, chatID: UUID(), draft: "draft")!
        expect(recall.messageID == q2.id, "a recall starts at the newest question")
        expect(recall.step(-1, in: messages) && recall.messageID == q1.id, "↑ goes back")
        expect(recall.step(-1, in: messages) && recall.messageID == q1.id, "↑ stops at the first")
        expect(recall.step(1, in: messages) && recall.messageID == q2.id, "↓ comes forward")
        expect(!recall.step(1, in: messages), "↓ past the newest ends the recall")
        expect(ChatRecall.arrowsStep(composer: "two", recall: recall), "arrows step over an unedited question")
        expect(!ChatRecall.arrowsStep(composer: "two!", recall: recall), "an edited one keeps its arrows")
        expect(ChatRecall.keptCount(editing: q2.id, in: messages) == 2, "an edit keeps what came before it")
        expect(ChatRecall.keptCount(editing: a1.id, in: messages) == nil, "a reply is never edited")
        expect(ChatRecall(in: [a1], chatID: UUID(), draft: "") == nil, "a chat with no question has nothing to recall")
    }

    static func branchesCopyUnderNewIDs() {
        let q = ChatMessage(role: .user, text: "q")
        let a = ChatMessage(role: .assistant, text: "a")
        let later = ChatMessage(role: .user, text: "later")
        let branch = ChatBranch.messages(of: [q, a, later], through: a.id)
        expect(branch?.map(\.text) == ["q", "a"], "a branch stops at the message it starts from")
        expect(branch.map { Set($0.map(\.id)).isDisjoint(with: [q.id, a.id]) } == true, "with ids of its own")
        expect(ChatBranch.messages(of: [q], through: UUID()) == nil, "an unknown message branches nothing")
    }

    static func longMessagesFold() {
        expect(!ChatMessageFold.folds("short"), "a short message stays open")
        expect(ChatMessageFold.folds(Array(repeating: "line", count: 11).joined(separator: "\n")), "11 lines fold")
        expect(ChatMessageFold.folds(String(repeating: "x", count: 1_000)), "one very long line folds too")
    }

    static func toolKindsAndLanguageHues() {
        expect(ChatToolKind.of(title: "web_search · swift", origin: "") == .web, "a search is web")
        expect(ChatToolKind.of(title: "run_command: ls", origin: "Agent") == .terminal, "a command is terminal")
        expect(ChatToolKind.of(title: "read_file: /tmp/a", origin: "") == .files, "a read is files")
        expect(ChatToolKind.of(title: "create_issue", origin: "GitHub") == .mcp, "anything else from a server is MCP")
        expect(CodeLanguageHue.hue(for: "Swift") == .orange, "Swift is orange")
        expect(CodeLanguageHue.hue(for: nil) == .gray, "no language is grey")
    }

    static func settle(_ chat: AIChatState) async {
        for _ in 0..<100 where chat.isStreaming {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
final class FakeHost: ChatWorkspaceHost {
    var forgotten: [UUID] = []
    var opened: [UUID] = []
    func openChat(id: UUID) { opened.append(id) }
    func closeWindow() {}
    func newChat(agentID: UUID?) {}
    func copyChat(id: UUID) {}
    func exportChat(id: UUID) {}
    func deleteChat(id: UUID) async {}
    func confirm(title: String, message: String, symbol: String, confirmTitle: String) async -> Bool { true }
    func showMessage(_ message: String) {}
    func forgetChat(id: UUID) { forgotten.append(id) }
    var agentChoices: [ChatAgentChoice] { [] }
    func agentID(ofChat id: UUID) -> UUID? { nil }
    func bindAgent(_ id: UUID?, toChat chat: UUID) {}
}

final class ScriptedProvider: AIProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var rounds: [[AIStreamEvent]]
    private var seen: [AIRequest] = []

    init(rounds: [[AIStreamEvent]]) {
        self.rounds = rounds
    }

    var requests: [AIRequest] { lock.withLock { seen } }

    func stream(_ request: AIRequest) -> AIProviderStream {
        let events: [AIStreamEvent] = lock.withLock {
            seen.append(request)
            return rounds.isEmpty ? [.finished] : rounds.removeFirst()
        }
        return AIProviderStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}
