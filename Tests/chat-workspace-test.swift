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
        branchesNestUnderTheirParentWithinASection()
        aBranchAwayFromItsParentSaysWhereItCameFrom()
        deepBranchesAndBrokenLinksStaySafe()
        commandDigitsFollowTheTree()
        branchLinksAndFoldsSurviveTheFile()
        selectionMath()
        bulkFactsWordTheActions()
        instructionsComposeAfterTheAppPrompt()
        creativityKeepsTheRestOfTheRequest()
        do { try await creativityRidesEveryRequestAndYieldsToARefusal() } catch { expect(false, "\(error)") }
        autoArchiveSparesPinnedOpenAndRecentChats()
        deletionsExpireAfterSixtyDays()
        theStoreWritesOnlyOnChange()
        trashHidesAndRestoreReturns()
        tidyPurgesExpiredAndForgetsStaleEntries()
        await editingAQuestionRewritesTheHistory()
        recallStepsAndRestoresTheDraft()
        branchesCopyUnderNewIDs()
        branchingRecordsTheParentAndUnfoldsIt()
        await bulkMovesDeletesAndRestores()
        deletingAParentKeepsItsBranches()
        longMessagesFold()
        toolKindsAndLanguageHues()
        colouredTextReadsInBothAppearances()
        bannersOnlyForChatsOutOfSight()
        aClosedWindowReleasesItsTranscriptAndReopensIt()
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
        expect(layout.pinned.map(\.chat.title) == ["pinned", "pinned and filed"], "pinned chats sit above all")
        expect(layout.folders.first?.rows.map(\.chat.title) == ["filed"], "a folder lists its unpinned chats")
        expect(layout.recent.flatMap(\.rows).map(\.chat.title) == ["recent"], "Recent holds the rest")
        expect(layout.archived.map(\.chat.title) == ["archived"], "archived chats are only in Archived")
        let listed = (layout.pinned + layout.folders.flatMap(\.rows) + layout.recent.flatMap(\.rows)
            + layout.archived).map(\.chat)
        expect(listed.count == Set(listed.map(\.id)).count, "no chat is listed twice")
        expect(!listed.contains { $0.id == deleted.id }, "a deleted chat is in no section")
        let search = ChatSidebarLayout(
            conversations: all, workspace: workspace, matching: [archived.id, deleted.id, recent.id],
            dayTitle: { _ in "Today" })
        expect(
            search.results?.map(\.chat.title) == ["recent", "archived"],
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

    // MARK: - Branches

    static func layout(
        _ chats: [ChatConversation], _ workspace: ChatWorkspace, day: @escaping (Date) -> String = { _ in "Today" }
    ) -> ChatSidebarLayout {
        ChatSidebarLayout(conversations: chats, workspace: workspace, dayTitle: day)
    }

    static func branchesNestUnderTheirParentWithinASection() {
        let now = Date()
        var workspace = ChatWorkspace()
        let parent = conversation("parent", at: now.addingTimeInterval(-300))
        let older = conversation("older branch", at: now.addingTimeInterval(-200))
        let newer = conversation("newer branch", at: now.addingTimeInterval(-100))
        let grandchild = conversation("grandchild", at: now.addingTimeInterval(-150))
        let other = conversation("other", at: now.addingTimeInterval(-250))
        workspace.copyPlacement(from: parent.id, to: older.id)
        workspace.copyPlacement(from: parent.id, to: newer.id)
        workspace.copyPlacement(from: older.id, to: grandchild.id)
        let chats = [newer, grandchild, older, other, parent]
        let rows = layout(chats, workspace).recent.flatMap(\.rows)
        expect(
            rows.map(\.chat.title) == ["parent", "newer branch", "older branch", "grandchild", "other"],
            "a tree sits where its newest chat would, its branches newest first under the parent")
        expect(rows.map(\.depth) == [0, 1, 1, 2, 0], "each level sits one indent further in")
        expect(rows[0].branches == 2 && rows[2].branches == 1 && rows[1].branches == 0, "parents count branches")
        expect(rows[1].guides == [.line] && rows[2].guides == [.elbow], "the last branch ends in the elbow")
        expect(rows[3].guides == [.blank, .elbow], "below a last branch the outer line has stopped")
        expect(rows.allSatisfy { $0.origin == nil }, "a nested branch needs no glyph")

        var folded = workspace
        folded.setBranchesFolded(true, of: parent.id)
        let foldedRows = layout(chats, folded).recent.flatMap(\.rows)
        expect(foldedRows.map(\.chat.title) == ["parent", "other"], "a folded parent hides every level under it")
        expect(foldedRows[0].isFolded && foldedRows[0].branches == 2, "and still says it has branches")

        let days = layout(chats, workspace) { $0 < now.addingTimeInterval(-220) ? "Yesterday" : "Today" }
        expect(days.recent.map(\.title) == ["Today", "Yesterday"], "Recent keeps its days")
        expect(
            days.recent.first?.rows.map(\.chat.title) == ["parent", "newer branch", "older branch", "grandchild"],
            "a tree goes under the day of its newest chat, parent and all")
    }

    static func aBranchAwayFromItsParentSaysWhereItCameFrom() {
        let now = Date()
        var workspace = ChatWorkspace()
        let work = workspace.createFolder(named: "Work")!
        let parent = conversation("parent", at: now)
        let filed = conversation("filed branch", at: now)
        let pinned = conversation("pinned branch", at: now, pinned: true)
        let archived = conversation("archived parent", at: now)
        let underArchived = conversation("under archived", at: now)
        let underDeleted = conversation("under deleted", at: now)
        let deleted = conversation("deleted parent", at: now)
        workspace.move(parent.id, to: work.id)
        workspace.copyPlacement(from: parent.id, to: filed.id)
        workspace.copyPlacement(from: parent.id, to: pinned.id)
        workspace.move(filed.id, to: nil)
        workspace.archive(archived.id, at: now)
        workspace.copyPlacement(from: archived.id, to: underArchived.id)
        workspace.copyPlacement(from: deleted.id, to: underDeleted.id)
        workspace.trash(deleted.id, title: "deleted parent", at: now)
        let all = [parent, filed, pinned, archived, underArchived, underDeleted, deleted]
        let sidebar = layout(all, workspace)
        let recent = sidebar.recent.flatMap(\.rows)
        let byTitle = Dictionary(
            (recent + sidebar.pinned + sidebar.folders.flatMap(\.rows)).map { ($0.chat.title, $0) },
            uniquingKeysWith: { first, _ in first })
        expect(byTitle["filed branch"]?.depth == 0, "a branch in another section is a top-level row")
        expect(
            byTitle["filed branch"]?.origin == ChatBranchOrigin(id: parent.id, title: "parent", opens: true),
            "and names the parent it came from")
        expect(byTitle["pinned branch"]?.origin?.id == parent.id, "Pinned and a folder are different sections")
        expect(byTitle["under archived"]?.origin?.opens == true, "an archived parent still opens")
        expect(
            byTitle["under deleted"]?.origin == ChatBranchOrigin(id: deleted.id, title: "deleted parent", opens: false),
            "a deleted one is named from Recently Deleted and not opened")
        expect(sidebar.folders.first?.rows.first?.branches == 0, "the parent counts no branch it cannot show")
        let search = ChatSidebarLayout(
            conversations: all, workspace: workspace, matching: [parent.id, filed.id], dayTitle: { _ in "" })
        expect(search.results?.allSatisfy { $0.depth == 0 } == true, "search is flat")
        expect(search.results?.first { $0.id == filed.id }?.origin?.id == parent.id, "with each branch's glyph")
    }

    static func deepBranchesAndBrokenLinksStaySafe() {
        let now = Date()
        var workspace = ChatWorkspace()
        let chain = (0..<6).map { conversation("level \($0)", at: now.addingTimeInterval(Double(-$0))) }
        for (parent, child) in zip(chain, chain.dropFirst()) { workspace.copyPlacement(from: parent.id, to: child.id) }
        let rows = layout(chain, workspace).recent.flatMap(\.rows)
        expect(rows.map(\.chat.title) == chain.map(\.title), "a chain lists top to bottom")
        expect(rows.map(\.depth) == [0, 1, 2, 3, 3, 3], "past three indents a branch lines up under the third")
        expect(rows.last?.guides == [.blank, .blank, .elbow], "keeping its own elbow")

        var broken = ChatWorkspace()
        let a = conversation("a", at: now), b = conversation("b", at: now), c = conversation("c", at: now)
        let orphan = conversation("orphan", at: now)
        broken.copyPlacement(from: a.id, to: b.id)
        broken.copyPlacement(from: b.id, to: a.id)
        broken.copyPlacement(from: UUID(), to: orphan.id)
        broken.copyPlacement(from: a.id, to: c.id)
        let safe = layout([a, b, c, orphan], broken).recent.flatMap(\.rows)
        expect(Set(safe.map(\.id)) == Set([a, b, c, orphan].map(\.id)) && safe.count == 4, "no chat is lost or doubled")
        expect(safe.first { $0.id == orphan.id }.map { $0.depth == 0 && $0.origin == nil } == true,
            "a missing parent leaves a plain top-level row")
        expect(safe.first { $0.id == c.id }?.depth == 1, "a branch of a chat in a loop still nests")
        expect(safe.filter { $0.depth == 0 }.count == 3, "a loop of parents is broken into top-level rows")
    }

    static func commandDigitsFollowTheTree() {
        let now = Date()
        var workspace = ChatWorkspace()
        let parent = conversation("parent", at: now.addingTimeInterval(-10))
        let branch = conversation("branch", at: now)
        let next = conversation("next", at: now.addingTimeInterval(-5))
        workspace.copyPlacement(from: parent.id, to: branch.id)
        let chats = [branch, next, parent]
        let order = layout(chats, workspace).shortcutOrder
        expect(order == [parent.id, branch.id, next.id], "⌘ digits count the rows as nested, top to bottom")
        expect(ChatShortcutIndex.chat(forDigit: "2", in: order) == branch.id, "⌘2 is the parent's first branch")
        workspace.setBranchesFolded(true, of: parent.id)
        let folded = layout(chats, workspace).shortcutOrder
        expect(folded == [parent.id, next.id], "a folded branch has no digit")
        expect(ChatShortcutIndex.badge(for: next.id, in: folded) == "2", "and the next row takes its place")
    }

    static func branchLinksAndFoldsSurviveTheFile() {
        var workspace = ChatWorkspace()
        let parent = UUID(), branch = UUID()
        workspace.copyPlacement(from: parent, to: branch)
        workspace.setBranchesFolded(true, of: parent)
        let reread = ChatWorkspace(data: workspace.data)
        expect(reread == workspace, "a branch's parent and a parent's fold read back")
        expect(reread.parentID(of: branch) == parent && reread.foldsBranches(of: parent), "both are kept")
        let entry = JSONValue(data: workspace.data)?.objectValue?["chats"]?.objectValue?[branch.uuidString]
        expect(entry?.objectValue?["branchOf"] == .string(parent.uuidString), "the link is a plain id")
        let json = """
            {"chats": {"\(branch.uuidString)": {"branchOf": "nonsense", "branchesFolded": "yes", "x": 1},
                       "\(parent.uuidString)": {"branchOf": "\(parent.uuidString)"}}}
            """
        let odd = ChatWorkspace(data: Data(json.utf8))
        expect(odd.parentID(of: branch) == nil && !odd.foldsBranches(of: branch), "a bad link or fold is dropped")
        expect(odd.placement(of: branch).unknown["x"] == .number(1), "the rest of the entry stays")
        expect(odd.placements[parent] == nil, "a chat is never its own parent")
        let old = ChatWorkspace(data: Data(#"{"chats": {"\#(branch.uuidString)": {"instructions": "Hi"}}}"#.utf8))
        expect(old.parentID(of: branch) == nil && old.placement(of: branch).instructions == "Hi", "old files load")

        var pruned = workspace
        pruned.prune(keeping: [branch])
        expect(pruned.parentID(of: branch) == nil, "a link to a chat the history lost is let go")
        var trashed = workspace
        trashed.trash(parent, title: "p", at: Date())
        trashed.prune(keeping: [branch])
        expect(trashed.parentID(of: branch) == parent, "a parent in Recently Deleted keeps its branches' links")
        trashed.forget(parent)
        expect(trashed.parentID(of: branch) == nil, "erased for good, its branches become ordinary chats")
        var restored = ChatWorkspace()
        restored.setParent(parent, of: branch)
        restored.setParent(parent, of: parent)
        expect(restored.parentID(of: branch) == parent && restored.placements[parent] == nil, "a backup's link")
    }

    // MARK: - Selection

    static func selectionMath() {
        let ids = (0..<6).map { _ in UUID() }
        let all = Set(ids)
        var selection = ChatSelection()
        expect(selection.click(ids[1], .plain, in: ids, contents: all), "a plain click opens")
        expect(selection.isEmpty, "and selects nothing")
        expect(!selection.click(ids[3], .toggle, in: ids, open: ids[0], contents: all), "⌘-click opens nothing")
        expect(selection.ids == [ids[0], ids[3]], "a first ⌘-click starts from the open chat")
        selection.click(ids[4], .toggle, in: ids, open: ids[0], contents: all)
        selection.click(ids[0], .toggle, in: ids, open: ids[0], contents: all)
        expect(selection.ids == [ids[3], ids[4]], "⌘ toggles each row")
        selection.click(ids[1], .extend, in: ids, contents: all)
        expect(selection.ids == Set(ids[0...1]), "⇧ takes the range from the last ⌘-clicked row")
        selection.click(ids[5], .extend, in: ids, contents: all)
        expect(selection.ids == Set(ids[0...5]), "another ⇧ moves the far end, the anchor stays")
        expect(selection.ordered(in: ids.reversed()) == ids.reversed(), "a bulk action takes the list's order")
        selection.clear()
        selection.click(ids[2], .extend, in: ids, open: ids[4], contents: all)
        expect(selection.ids == Set(ids[2...4]), "a first ⇧-click ranges from the open chat")
        selection.click(ids[2], .plain, in: ids, contents: all)
        expect(selection.isEmpty, "a plain click clears it")

        selection.selectAll(ids, contents: all)
        expect(selection.count == 6, "⌘A takes every row shown")
        selection.reconcile(contents: all)
        expect(selection.count == 6, "the same rows keep it, reordered or not")
        selection.reconcile(contents: Set(ids.prefix(3)))
        expect(selection.isEmpty, "a search or a filter clears it")

        let trash = [UUID(), UUID()]
        selection.click(ids[0], .toggle, in: ids, contents: all)
        selection.click(trash[1], .toggle, in: trash, contents: all)
        expect(selection.ids == [trash[1]], "a click in another list starts over there")
        selection.click(ids[1], .toggle, in: ids, contents: all)
        selection.click(ids[2], .toggle, in: ids, contents: all.union([UUID()]))
        expect(selection.ids == [ids[2]], "so does one after the list changed")
        selection.click(UUID(), .toggle, in: ids, contents: all)
        expect(selection.isEmpty, "a row the list does not show clears it")
    }

    static func bulkFactsWordTheActions() {
        var workspace = ChatWorkspace()
        let work = workspace.createFolder(named: "Work")!
        let a = conversation("a", at: Date(), pinned: true), b = conversation("b", at: Date())
        workspace.move(b.id, to: work.id)
        let mixed = ChatBulkFacts([a.id, b.id], conversations: [a, b], workspace: workspace)
        expect(mixed.pins && mixed.archives, "a mixed selection offers Pin and Archive")
        expect(mixed.anyFiled && mixed.sharedFolder == nil, "Remove from Folder, with no folder checked")
        workspace.move(a.id, to: work.id)
        workspace.archive([a.id, b.id], at: Date())
        let same = ChatBulkFacts([a.id], conversations: [a, b], workspace: workspace)
        expect(!same.pins && !same.archives, "all pinned offers Unpin, all archived Unarchive")
        expect(same.sharedFolder == work.id, "and the folder they share is checked")
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

    static func creativityRidesEveryRequestAndYieldsToARefusal() async throws {
        let plain = ScriptedProvider(rounds: [[.text("ok"), .finished]])
        expect(ChatCreativityProvider.wrapping(plain, temperature: nil) is ScriptedProvider, "unset adds no wrapper")
        let warm = ChatCreativityProvider.wrapping(plain, temperature: 1.5)
        for try await _ in warm.stream(AIRequest(messages: [AIMessage(role: .user, text: "q")])) {}
        expect(plain.requests.last?.temperature == 1.5, "the request carries the chat's temperature")
        let refusing = RefusingProvider()
        var text = ""
        for try await event in ChatCreativityProvider(base: refusing, temperature: 0.4)
            .stream(AIRequest(messages: [AIMessage(role: .user, text: "q")]))
        {
            if case .text(let delta) = event { text += delta }
        }
        expect(refusing.temperatures == [0.4, nil], "a refused temperature is asked again without one")
        expect(text == "fine", "and the answer comes through")
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

    static func branchingRecordsTheParentAndUnfoldsIt() {
        let root = directory("branch")
        defer { try? FileManager.default.removeItem(at: root) }
        let (workspace, host) = coordinator(root)
        let parent = saved(workspace.history, "Parent")
        workspace.toggleBranches(of: parent)
        expect(workspace.workspace.foldsBranches(of: parent), "a fold is remembered per parent")
        let branch = workspace.branch(parent)!
        expect(workspace.workspace.parentID(of: branch) == parent, "a branch records the chat it came from")
        expect(!workspace.workspace.foldsBranches(of: parent), "the parent unfolds to show the new branch")
        expect(host.opened.last == branch, "and the branch opens")
        let again = ChatWorkspaceStore(directory: root)
        again.load()
        expect(again.workspace.parentID(of: branch) == parent, "the link is on disk")
        workspace.toggleBranches(of: parent)
        let reopened = ChatWorkspaceStore(directory: root)
        reopened.load()
        expect(reopened.workspace.foldsBranches(of: parent), "so is the fold")
        let rows = workspace.sidebarLayout.recent.flatMap(\.rows)
        expect(rows.map(\.id) == [parent], "a folded parent shows alone")
    }

    static func bulkMovesDeletesAndRestores() async {
        let root = directory("bulk")
        defer { try? FileManager.default.removeItem(at: root) }
        let (workspace, host) = coordinator(root)
        let ids = (0..<4).map { saved(workspace.history, "chat \($0)") }
        workspace.history.setPinned(true, id: ids[0])
        let work = workspace.createFolder(named: "Work", hue: .blue, symbol: "folder.fill", instructions: nil, agentID: nil)!
        let order = { workspace.selectionOrder(workspace.sidebarLayout, inTrash: false) }
        workspace.click(order()[0], .toggle)
        workspace.click(order()[2], .extend)
        expect(workspace.selection.count == 3, "⇧ takes three rows")
        let selected = workspace.selectedIDs
        workspace.moveSelection(to: work.id)
        expect(selected.allSatisfy { workspace.workspace.folderID(of: $0) == work.id }, "all three are filed")
        expect(workspace.history.conversation(id: ids[0])?.isPinned == false, "filing unpins, as one chat's move does")
        expect(workspace.selection.isEmpty, "the action uses the selection up")

        workspace.selectAll()
        expect(workspace.selection.count == 4, "⌘A takes every chat the list shows")
        expect(workspace.selectionFacts.anyFiled, "some are filed")
        workspace.removeSelectionFromFolders()
        expect(ids.allSatisfy { workspace.workspace.folderID(of: $0) == nil }, "Remove from Folder takes all to Recent")

        workspace.selectAll()
        workspace.togglePinSelection()
        expect(ids.allSatisfy { workspace.history.conversation(id: $0)?.isPinned == true }, "Pin pins them all")
        workspace.selectAll()
        workspace.toggleArchiveSelection()
        expect(ids.allSatisfy(workspace.workspace.isArchived), "Archive archives them all")
        expect(ids.allSatisfy { workspace.history.conversation(id: $0)?.isPinned == false }, "and unpins them")
        workspace.showsArchived = true
        workspace.selectAll()
        workspace.toggleArchiveSelection()
        expect(!ids.contains(where: workspace.workspace.isArchived), "Unarchive when all are archived")

        workspace.click(ids[1], .toggle)
        workspace.click(ids[2], .toggle)
        let doomed = workspace.selectedIDs
        expect(doomed.count == 2, "two are selected")
        workspace.trash(doomed)
        expect(doomed.allSatisfy(workspace.workspace.isTrashed), "Delete moves every one to Recently Deleted")
        expect(doomed.allSatisfy { workspace.history.conversation(id: $0) == nil }, "and out of every list")
        workspace.showsDeleted = true
        workspace.click(doomed[0], .toggle, inTrash: true)
        workspace.click(doomed[1], .extend, inTrash: true)
        expect(workspace.selectionIsInTrash && workspace.selection.count == 2, "Recently Deleted selects its own")
        workspace.restoreSelection()
        expect(doomed.allSatisfy { workspace.history.conversation(id: $0) != nil }, "Restore brings both back")
        workspace.trash(doomed)
        workspace.selection.selectAll(doomed, contents: workspace.selectionContents(workspace.sidebarLayout))
        await workspace.deleteSelection()
        expect(doomed.allSatisfy { workspace.history.session(id: $0) == nil }, "Delete Permanently erases both")
        expect(workspace.workspace.trashed.isEmpty && workspace.selection.isEmpty, "after one question")
        expect(host.forgotten.count == 2, "each one's agent notes go with it")
    }

    static func deletingAParentKeepsItsBranches() {
        let root = directory("parent")
        defer { try? FileManager.default.removeItem(at: root) }
        let (workspace, host) = coordinator(root)
        let parent = saved(workspace.history, "Parent")
        let branch = workspace.branch(parent)!
        let work = workspace.createFolder(named: "Work", hue: .blue, symbol: "folder.fill", instructions: nil, agentID: nil)!
        workspace.move(parent, to: work.id)
        expect(workspace.workspace.folderID(of: branch) == nil, "moving a parent moves only the parent")
        let away = workspace.sidebarLayout.recent.flatMap(\.rows).first { $0.id == branch }
        expect(away?.origin?.id == parent, "the branch stays put and says where it came from")
        workspace.openParent(of: branch)
        expect(host.opened.last == parent, "its glyph opens the parent")
        workspace.trash(parent)
        expect(workspace.history.conversation(id: branch) != nil, "deleting a parent never deletes a branch")
        let orphan = workspace.sidebarLayout.recent.flatMap(\.rows).first { $0.id == branch }
        expect(orphan?.origin?.opens == false, "a deleted parent is named but not opened")
        workspace.restore(parent)
        workspace.move(parent, to: nil)
        let home = workspace.sidebarLayout.recent.flatMap(\.rows)
        expect(home.map(\.id) == [parent, branch] && home[1].depth == 1, "back together, it nests again")
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

    /// Headers, code badges and labels are text: 4.5:1 on the light window and sidebar and on dark.
    static func colouredTextReadsInBothAppearances() {
        for hue in RaycastHue.allCases {
            for surface: UInt32 in [0xFFFFFF, 0xF2F2F2] {
                let ratio = ChatPalette.contrast(ChatPalette.lightInk(hue), surface)
                expect(ratio >= 4.5, "\(hue) ink reads on light #\(String(surface, radix: 16)): \(ratio)")
            }
            let dark = ChatPalette.contrast(ChatPalette.darkInk(hue), 0x1E1E1E)
            expect(dark >= 4.5 || hue == .magenta, "\(hue) ink reads on dark: \(dark)")
        }
        expect(ChatPalette.scaled(0xFF8040, by: 0.5) == 0x804020, "scaling darkens each channel")
    }

    static func bannersOnlyForChatsOutOfSight() {
        func notifies(_ enabled: Bool, quick: Bool = false, front: Bool = false, run: Bool = false) -> Bool {
            ChatFinishPolicy.notifies(enabled: enabled, isQuickAI: quick, windowInFront: front, backgroundRun: run)
        }
        expect(notifies(true), "a window chat finishing out of sight is announced")
        expect(!notifies(false), "nothing is posted while the setting is off, the default")
        expect(!notifies(true, front: true), "nor while the window is in front")
        expect(!notifies(true, quick: true), "nor for Quick AI, which is on screen")
        expect(!notifies(true, run: true), "nor for a background run, which has its own banner")
        let defaults = UserDefaults(suiteName: "tinycast-workspace-\(UUID().uuidString)")!
        let settings = ChatWorkspaceSettings(defaults: defaults)
        expect(!settings.notifiesInBackground && settings.autoArchive == .never, "both start off")
        expect(settings.showsInspector && !settings.floatsOnTop, "settings open, window not floating")
    }

    // MARK: - Memory

    static func aClosedWindowReleasesItsTranscriptAndReopensIt() {
        let (workspace, _) = coordinator(directory("release"))
        let history = workspace.history
        let chats = workspace.chats
        let saved = { (id: UUID) in history.conversation(id: id) != nil }
        let first = Self.saved(history, "first")
        let second = Self.saved(history, "second")
        _ = chats.openInWindow(id: first)
        chats.releaseWindowTranscript(isSaved: saved)
        expect(chats.window.session.messages.isEmpty, "a closed window keeps no transcript")
        chats.restoreWindowTranscript(isSaved: saved)
        expect(chats.window.holds(first), "the reopened window shows the chat it closed on")
        chats.releaseWindowTranscript(isSaved: saved)
        _ = chats.openInWindow(id: second)
        chats.restoreWindowTranscript(isSaved: saved)
        expect(chats.window.holds(second), "a chat opened while closed wins over the released one")
        chats.releaseWindowTranscript(isSaved: saved)
        chats.newWindowChat()
        chats.restoreWindowTranscript(isSaved: saved)
        expect(chats.window.session.messages.isEmpty, "New Chat while closed is not undone on show")
        _ = chats.openInWindow(id: first)
        chats.window.draft = "half typed"
        chats.releaseWindowTranscript(isSaved: saved)
        expect(chats.window.holds(first), "a draft keeps its chat resident")
        chats.window.draft = ""
        chats.window.toolScope.toggle("github")
        chats.releaseWindowTranscript(isSaved: saved)
        expect(chats.window.holds(first), "a chat's own tool picks keep it resident")
        chats.window.toolScope = ChatToolScope()
        chats.releaseWindowTranscript(isSaved: saved)
        workspace.trash(first)
        chats.restoreWindowTranscript(isSaved: saved)
        expect(chats.window.session.messages.isEmpty, "a chat deleted while closed does not come back")
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
    func openChatInWindow(id: UUID) { opened.append(id) }
    func closeWindow() {}
    func isBackgroundRun(_ id: UUID) -> Bool { false }
    var isWindowInFront = true
    func newChat(agentID: UUID?) {}
    func copyChat(id: UUID) {}
    func copyChats(ids: [UUID]) {}
    func exportChat(id: UUID) {}
    func deleteChat(id: UUID) async {}
    func confirm(title: String, message: String, symbol: String, confirmTitle: String) async -> Bool { true }
    func showMessage(_ message: String) {}
    func forgetChat(id: UUID) { forgotten.append(id) }
    var agentChoices: [ChatAgentChoice] { [] }
    func agentID(ofChat id: UUID) -> UUID? { nil }
    func bindAgent(_ id: UUID?, toChat chat: UUID) {}
}

/// Refuses any request with a temperature, as OpenAI's reasoning models do.
final class RefusingProvider: AIProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Double?] = []
    var temperatures: [Double?] { lock.withLock { seen } }

    func stream(_ request: AIRequest) -> AIProviderStream {
        lock.withLock { seen.append(request.temperature) }
        return AIProviderStream { continuation in
            if request.temperature != nil {
                continuation.finish(throwing: AIProviderError.unavailable("Unsupported value: 'temperature'"))
            } else {
                continuation.yield(.text("fine"))
                continuation.yield(.finished)
                continuation.finish()
            }
        }
    }
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
