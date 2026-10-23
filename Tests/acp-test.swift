import Foundation

@main
@MainActor
struct ACPTests {
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
        framingRoundTrips()
        updatesDecode()
        permissionsOfferAllowsFirst()
        promptsCarryContextOnlyWhenFresh()
        theBriefingSaysNobodyMayAnswer()
        eventsSettleEachCallOnce()
        toolContentIsCompactedOnce()
        toolOutputReachesItsRowOnce()
        commandsDecodeMatchAndComplete()
        aCommandLeadsItsPrompt()
        configOptionsDecodeAndSlot()
        rememberedChoicesApplyAndPersist()
        runtimesParseTheirArguments()
        await aRealProcessStreamsATurn()
        await stoppingLeavesNoProcessBehind()
        await twoAgentsSharingASessionIDStayApart()
        await toolContentReachesItsRows()
        await commandsReachTheChatAndLeadTheirTurn()
        await aFreshProcessWaitsForItsCommands()
        await configOptionsApplyBeforeTheFirstPrompt()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Pure

    static func framingRoundTrips() {
        let request = ACPProtocol.request(id: 7, method: "session/prompt", params: ["text": "a\nb"])
        expect(request.last == 0x0A, "a message ends with its newline")
        expect(
            !request.dropLast().contains(0x0A),
            "and holds no other, even when a string carries one")
        guard case .request(let id, let method, _) = ACPProtocol.parse(
            Data(#"{"jsonrpc":"2.0","id":"p-1","method":"session/request_permission","params":{}}"#.utf8))
        else { return expect(false, "a string-numbered request parses") }
        expect(id == .string("p-1") && method == "session/request_permission", "keeping its id as given")
        guard case .failure(let failed, let code, let message) = ACPProtocol.parse(
            Data(#"{"jsonrpc":"2.0","id":3,"error":{"code":-32000,"message":"auth_required"}}"#.utf8))
        else { return expect(false, "an error response parses") }
        expect(failed == 3 && code == -32000 && message == "auth_required", "with its code and text")
        guard case .notification = ACPProtocol.parse(
            Data(#"{"jsonrpc":"2.0","method":"session/update","params":{}}"#.utf8))
        else { return expect(false, "a message without an id is a notification") }
        guard case .invalid = ACPProtocol.parse(Data("not json".utf8)) else {
            return expect(false, "noise is invalid, not a crash")
        }
        passes += 1
    }

    static func updatesDecode() {
        func decoded(_ json: String) -> ACPUpdate? {
            ACPUpdate.decode(JSONValue(data: Data(json.utf8)) ?? .null)?.update
        }
        expect(
            decoded(#"{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}}}"#)
                == .messageChunk("hi"),
            "a message chunk carries its text")
        expect(
            decoded(#"{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"image","data":"x"}}}"#)
                == .messageChunk(""),
            "an image chunk carries no text into a text transcript")
        guard case .toolCall(let call) = decoded(
            (#"{"sessionId":"s","update":{"sessionUpdate":"tool_call","toolCallId":"c","# + 
                #""title":"Run","kind":"execute","status":"in_progress","# + 
                #""rawInput":{"command":"npm test"},"content":[{"type":"diff","path":"/a","# + 
                #""oldText":null,"newText":"x"}]}}"#))
        else { return expect(false, "a tool call decodes") }
        expect(call.status == .inProgress && call.kind == "execute", "with its status and kind")
        expect(call.diffs == [ACPDiff(path: "/a", oldText: nil, newText: "x")], "and its diff, new file included")
        expect(call.summary.hasPrefix("npm test"), "its summary leads with the command")
        expect(
            decoded((#"{"sessionId":"s","update":{"sessionUpdate":"usage_update","used":5,"size":9,"# + 
                #""cost":{"amount":0.5,"currency":"usd"}}}"#))
                == .usage(used: 5, size: 9, costUSD: 0.5),
            "usage carries tokens and a dollar cost")
        expect(
            decoded(#"{"sessionId":"s","update":{"sessionUpdate":"current_mode_update","currentModeId":"plan"}}"#)
                == .mode("plan"),
            "the agent moving to another mode is reported")
        expect(
            decoded(#"{"sessionId":"s","update":{"sessionUpdate":"session_info_update","title":"x"}}"#)
                == .other("session_info_update"),
            "an update not drawn yet is kept as known, not dropped as malformed")
        expect(
            decoded((#"{"sessionId":"s","update":{"sessionUpdate":"available_commands_update","# +
                #""availableCommands":[{"name":"web","description":"Search","input":{"hint":"query"}}]}}"#))
                == .commands([ACPCommand(name: "web", description: "Search", hint: "query")]),
            "a session's slash commands decode with their hints")
        guard case .options(let listed) = decoded(
            (#"{"sessionId":"s","update":{"sessionUpdate":"config_option_update","configOptions":[{"id":"m","# +
                #""name":"Model","category":"model","type":"select","currentValue":"a","options":[{"value":"a","# +
                #""name":"A"}]}]}}"#))
        else { return expect(false, "a config option update decodes") }
        expect(listed.map(\.id) == ["m"] && listed.first?.category == .model, "with the agent's whole list")
        expect(decoded(#"{"update":{"sessionUpdate":"plan"}}"#) == nil, "an update names its session")
    }

    static func permissionsOfferAllowsFirst() {
        let json = (#"{"sessionId":"s","toolCall":{"toolCallId":"c","title":"Edit"},"# + 
            #""options":[{"optionId":"r","name":"Reject","kind":"reject_once"},"# + 
            #"{"optionId":"ra","name":"Never","kind":"reject_always"},{"optionId":"a","# + 
            #""name":"Always","kind":"allow_always"},{"optionId":"o","name":"Once","# + 
            #""kind":"allow_once"}]}"#)
        guard let request = ACPPermissionRequest(JSONValue(data: Data(json.utf8)) ?? .null) else {
            return expect(false, "a permission request decodes")
        }
        expect(
            request.dialogOptions.map(\.id) == ["o", "a", "ra", "r"],
            "allow once first, refuse once last where a dialog puts its cancel")
        let cancelled = ACPPermissionRequest.result(selecting: nil)
        expect(
            (cancelled["outcome"] as? [String: String])?["outcome"] == "cancelled",
            "no choice answers as cancelled")
        let selected = ACPPermissionRequest.result(selecting: "o")
        expect((selected["outcome"] as? [String: String])?["optionId"] == "o", "a choice names its option")
        expect(request.refusalIndex == 3, "the dialog's cancel, and Return in the background, is refuse once")
        expect(request.optionID(answering: 0) == "o" && request.optionID(answering: 3) == "r", "an answer is its option")
        expect(request.optionID(answering: nil) == "r", "no answer refuses once, never always")
        expect(request.optionID(answering: 9) == nil, "an answer out of range picks nothing")
        func offering(_ options: String) -> ACPPermissionRequest? {
            let json = #"{"sessionId":"s","toolCall":{"toolCallId":"c"},"options":["# + options + "]}"
            return ACPPermissionRequest(JSONValue(data: Data(json.utf8)) ?? .null)
        }
        let neverOnly = offering(
            #"{"optionId":"ra","name":"Never","kind":"reject_always"},"#
                + #"{"optionId":"o","name":"Once","kind":"allow_once"}"#)
        expect(
            neverOnly?.refusalIndex == 1 && neverOnly?.optionID(answering: nil) == nil,
            "with no refuse-once, no answer cancels rather than leave a rule nobody chose")
        let allowsOnly = offering(#"{"optionId":"o","name":"Once","kind":"allow_once"}"#)
        expect(allowsOnly?.refusalIndex == nil, "an agent that offers no refusal has no cancel to put on Return")
    }

    static func theBriefingSaysNobodyMayAnswer() {
        let briefing = AgentBackgroundBriefing.acp
        expect(briefing.hasPrefix("# Running unattended"), "the briefing is its own section")
        expect(
            briefing.contains("declined unless someone at the Mac answers them"),
            "it says permission requests are declined unless someone answers")
        expect(briefing.contains("final message"), "and that the result is the final message")
    }

    static func promptsCarryContextOnlyWhenFresh() {
        let message = AIMessage(
            role: .user, text: "Fix it",
            images: [AIImage(data: Data([1, 2]), mimeType: "image/png")],
            documents: [AIDocument(data: Data("a,b".utf8), mimeType: "text/csv", name: "t.csv")])
        let history = [
            AIMessage(role: .user, text: "Hello"), AIMessage(role: .assistant, text: "Hi there")
        ]
        let full = ACPPrompt.blocks(
            for: message, context: "CONTEXT", earlier: ACPPrompt.transcript(of: history),
            capabilities: .init(image: true, embeddedContext: true))
        expect(full.first?["type"] as? String == "text", "context and history lead the prompt")
        let lead = full.first?["text"] as? String ?? ""
        expect(
            lead.contains("CONTEXT") && lead.contains("User: Hello")
                && lead.contains("Assistant: Hi there"),
            "a fresh session hears who it is and what was said")
        expect(full.contains { $0["type"] as? String == "image" }, "an image goes to an agent that takes one")
        expect(full.contains { $0["type"] as? String == "resource" }, "a file goes as an embedded resource")
        expect(full.last?["text"] as? String == "Fix it", "and the request itself comes last")
        let plain = ACPPrompt.blocks(
            for: message, context: nil, earlier: "", capabilities: .init())
        expect(!plain.contains { $0["type"] as? String == "image" }, "no image to an agent that cannot see")
        expect(
            plain.contains { ($0["text"] as? String)?.contains("Attached file t.csv") == true },
            "a file is inlined for an agent without embedded resources")
        expect(plain.count == 2, "a continuing session gets only the message and its file")
        let long = (0..<500).map { AIMessage(role: .user, text: "turn \($0) " + String(repeating: "x", count: 100)) }
        let transcript = ACPPrompt.transcript(of: long)
        expect(transcript.utf8.count <= ACPPrompt.maxHistoryBytes + 64, "history is held to its budget")
        expect(
            transcript.hasPrefix("[Earlier turns cut.]") && transcript.contains("turn 499"),
            "keeping the newest turns and saying the rest were cut")
    }

    static func eventsSettleEachCallOnce() {
        var mapper = ACPEventMapper(origin: "Agent")
        let call = ACPToolCall(["toolCallId": .string("c"), "title": .string("Run"), "status": .string("pending")])!
        expect(
            mapper.events(for: .toolCall(call)) == [.toolCall(id: "c", origin: "Agent", title: "Run")],
            "a call opens a row")
        let done = ACPToolCall(["toolCallId": .string("c"), "status": .string("completed")])!
        expect(mapper.events(for: .toolCallUpdate(done)) == [.toolResult(id: "c", isError: false)], "and closes it")
        expect(mapper.events(for: .toolCallUpdate(done)).isEmpty, "only once")
        let orphan = ACPToolCall(["toolCallId": .string("d"), "status": .string("failed")])!
        expect(
            mapper.events(for: .toolCallUpdate(orphan))
                == [.toolCall(id: "d", origin: "Agent", title: "tool"), .toolResult(id: "d", isError: true)],
            "an update for a call never announced still draws and closes its row")
        _ = mapper.events(for: .toolCall(ACPToolCall(["toolCallId": .string("e")])!))
        expect(mapper.unsettled() == [.toolResult(id: "e", isError: true)], "an open call is settled at the end")
        _ = mapper.events(for: .usage(used: 10, size: 1_000, costUSD: nil))
        let closing = mapper.closing(
            result: JSONValue(data: Data((#"{"stopReason":"end_turn","usage":{"inputTokens":3,"outputTokens":4,"# + 
                #""cachedReadTokens":5,"thoughtTokens":1}}"#).utf8)) ?? .null)
        expect(
            closing == [.usage(AIUsage(
                inputTokens: 3, outputTokens: 4, cachedInputTokens: 5, reasoningTokens: 1,
                contextWindow: 1_000))],
            "the turn's usage comes from its result, with the window from the last update")
        let plan = [ACPPlanEntry(.object(["content": .string("Look"), "status": .string("completed")]))!]
        expect(mapper.events(for: .plan(plan)).count == 1, "a plan shows")
        expect(mapper.events(for: .plan(plan)).isEmpty, "and the same plan again does not")
    }

    static func runtimesParseTheirArguments() {
        expect(
            AgentRuntime.arguments(parsing: #"-y "@scope/pkg name" --flag  x"#)
                == ["-y", "@scope/pkg name", "--flag", "x"],
            "arguments split on spaces, quoted runs kept whole")
        expect(AgentRuntime.arguments(parsing: #"a "" b"#) == ["a", "", "b"], "an empty quoted argument stays")
        expect(
            AgentRuntime.preset(.claudeCode).commandLine == "npx -y @agentclientprotocol/claude-agent-acp",
            "Claude Code runs through its ACP adapter")
        expect(AgentRuntime.preset(.hermes).arguments == ["acp"], "Hermes speaks ACP itself")
    }

    // MARK: - A real process

    static func aRealProcessStreamsATurn() async {
        guard let node = await ExecutableLocator.locate("node") else {
            print("SKIP: node not found, the process half of acp-test did not run")
            return
        }
        let fixture = FileManager.default.currentDirectoryPath + "/Tests/acp-fixtures/fake-agent.mjs"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ACPTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AgentStore(directory: root.appendingPathComponent("support"))
        let agent = AgentProfile(
            name: "Fake", directory: root.path,
            runtime: AgentRuntime(kind: .custom, command: node.path, arguments: [fixture]))
        let asked = Asked()
        let answer = Answer()
        let seen = SeenOptions()
        let unattended = UUID()
        let host = AgentACPHost(
            store: store,
            permit: { _, request in
                asked.requests.append(request)
                return answer.choice ?? request.dialogOptions.first?.id
            },
            context: { _ in "# Context from Tinycast\nYou are Fake." },
            briefing: { $0 == unattended ? AgentBackgroundBriefing.acp : nil })
        host.onOptions = { _, _, options in if let options { seen.options.append(options) } }
        let server = AIToolServer(
            handle: "files", title: "Files", transport: .command(path: "/bin/echo", arguments: [], environment: [:]))
        func turn(
            _ text: String, chat: UUID, history: [AIMessage] = [], host: AgentACPHost
        ) async -> (events: [AIStreamEvent], error: Error?) {
            let request = AIRequest(
                messages: history + [AIMessage(role: .user, text: text, images: [
                    AIImage(data: Data([1]), mimeType: "image/png")
                ])],
                conversationID: chat)
            let provider = ACPAgentProvider(host: host, agent: agent, servers: { [server] })
            var events: [AIStreamEvent] = []
            do {
                for try await event in provider.stream(request) { events.append(event) }
            } catch {
                return (events, error)
            }
            return (events, nil)
        }
        func text(_ events: [AIStreamEvent]) -> String {
            events.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
        }

        let chat = UUID()
        let first = await turn("Hello", chat: chat, history: [AIMessage(role: .assistant, text: "earlier")], host: host)
        expect(first.error == nil, "a turn completes, got \(String(describing: first.error))")
        let reply = text(first.events)
        expect(reply.contains("turn 1 in \(root.path)"), "in the agent's folder, got \(reply)")
        expect(reply.contains("once"), "the dialog's first answer, Allow once, reached the agent")
        expect(reply.contains("with context") && reply.contains("with history"), "a fresh session hears both")
        expect(!reply.contains("briefed"), "a chat someone started is not told it runs unattended")
        expect(reply.contains("images 1"), "the image went to an agent that takes one")
        expect(reply.contains("servers 1"), "and the chat's MCP servers went with the session")
        expect(asked.requests.first?.toolCall.summary.contains("/tmp/notes.md") == true, "the dialog saw the diff")
        expect(first.events.contains(.reasoning("Thinking it over.")), "thinking streams as reasoning")
        expect(first.events.contains { if case .usage = $0 { true } else { false } }, "usage streams")
        expect(first.events.contains(.toolResult(id: "call_1", isError: false)), "the allowed edit closes its row")
        expect(
            first.events.contains(.toolResult(id: "call_2", isError: true)),
            "a call the agent never finished is settled when the turn ends")
        expect(first.events.last == .finished, "and the stream ends with finished")

        let offered = seen.options.first
        expect(
            offered?.mode?.choices.map(\.value) == ["default", "plan"] && offered?.mode?.current == "default"
                && offered?.mode?.setter == .legacyMode,
            "a new session reports the modes it offers and the one it is in")
        expect(
            offered?.model?.choices.map(\.value) == ["m-small", "m-large"] && offered?.model?.current == "m-small"
                && offered?.model?.setter == .legacyModel && offered?.reasoning == nil,
            "and the older models as the model select, with no reasoning of its own")
        try? await host.setOption("plan", for: .mode, chatID: chat)
        expect(seen.options.last?.mode?.current == "plan", "switching a live session's mode reports it")
        _ = await turn("LEAVEPLAN", chat: chat, host: host)
        expect(seen.options.last?.mode?.current == "default", "and so does the agent moving itself")
        try? await host.setOption("m-large", for: .model, chatID: chat)
        expect(seen.options.last?.model?.current == "m-large", "a live session switches model with set_model")

        let second = await turn("Again", chat: chat, host: host)
        let again = text(second.events)
        expect(
            again.contains("turn 3") && again.contains("without context") && again.contains("no history"),
            "the next turn reuses the session without repeating context, got \(again)")

        let alone = text(await turn("Alone", chat: unattended, host: host).events)
        expect(
            alone.contains("with context") && alone.contains("briefed"),
            "an unattended turn leads with its context, then the briefing, got \(alone)")
        let aloneAgain = text(await turn("Alone again", chat: unattended, host: host).events)
        expect(
            aloneAgain.contains("without context") && aloneAgain.contains("briefed"),
            "the briefing rides every unattended turn, even on a session that knows the context")

        answer.choice = "reject"
        let rejected = await turn("Once more", chat: chat, host: host)
        expect(rejected.events.contains(.toolResult(id: "call_1", isError: true)), "a refusal fails the call")
        answer.choice = nil

        let refused = await turn("REFUSE", chat: UUID(), host: host)
        expect(refused.error != nil, "an agent's refusal surfaces as an error")

        let slowChat = UUID()
        let slow = Task { await turn("SLOW", chat: slowChat, host: host) }
        try? await Task.sleep(for: .milliseconds(600))
        slow.cancel()
        let stopped = await slow.value
        expect(stopped.error == nil, "a stopped turn ends quietly")
        expect(text(stopped.events).hasPrefix("Working"), "after what had already streamed")

        let stored = store.acpSession(forChat: chat)
        expect(stored != nil, "a chat's session is remembered")
        host.stopAll()
        let relaunched = AgentACPHost(
            store: store, permit: { _, request in request.dialogOptions.first?.id },
            context: { _ in "# Context from Tinycast" })
        let reloaded = await turn("After relaunch", chat: chat, host: relaunched)
        let afterRelaunch = text(reloaded.events)
        expect(
            afterRelaunch.contains("turn 11") && !afterRelaunch.contains("REPLAYED"),
            "a relaunch reloads the session and drops its replay, got \(afterRelaunch)")
        expect(afterRelaunch.contains("without context"), "a reloaded session needs no context again")

        store.setACPSession("gone_1", forChat: chat)
        relaunched.stopAll()
        let lost = await turn("Lost", chat: chat, host: relaunched)
        let fresh = text(lost.events)
        expect(
            fresh.contains("with context") && store.acpSession(forChat: chat) != "gone_1",
            "a session the agent lost starts fresh, with context, got \(fresh)")
        relaunched.stopAll()

        var planner = agent
        planner.acpMode = "plan"
        planner.acpModel = "m-large"
        let planned = ACPAgentProvider(host: relaunched, agent: planner, servers: { [] })
        let plannerChat = UUID()
        seen.options.removeAll()
        relaunched.onOptions = { _, _, options in if let options { seen.options.append(options) } }
        var planReply = ""
        do {
            for try await event in planned.stream(
                AIRequest(messages: [AIMessage(role: .user, text: "Hi")], conversationID: plannerChat))
            {
                if case .text(let chunk) = event { planReply += chunk }
            }
        } catch {
            expect(false, "a planner's turn completes, got \(error)")
        }
        expect(
            seen.options.last?.mode?.current == "plan" && seen.options.last?.model?.current == "m-large",
            "an agent's chosen mode and model are applied as its session starts")
        expect(
            planReply.contains("on m-large; sets model=m-large,mode=plan"),
            "through the older methods, model first, before the first prompt, got \(planReply)")
        relaunched.stopAll()

        let missing = AgentProfile(
            name: "Missing", directory: root.path,
            runtime: AgentRuntime(kind: .custom, command: "definitely-not-an-agent-cli", arguments: []))
        let broken = ACPAgentProvider(host: relaunched, agent: missing, servers: { [] })
        var failure: Error?
        do {
            for try await _ in broken.stream(
                AIRequest(messages: [AIMessage(role: .user, text: "hi")], conversationID: UUID()))
            {}
        } catch {
            failure = error
        }
        expect(
            failure?.localizedDescription.contains("definitely-not-an-agent-cli") == true,
            "a missing command names itself, got \(String(describing: failure?.localizedDescription))")
    }
}

extension ACPTests {
    static func stoppingLeavesNoProcessBehind() async {
        guard let node = await ExecutableLocator.locate("node") else { return }
        let fixture = FileManager.default.currentDirectoryPath + "/Tests/acp-fixtures/fake-agent.mjs"
        let connection = ACPConnection(
            runtime: AgentRuntime(kind: .custom, command: node.path, arguments: [fixture]),
            directory: FileManager.default.temporaryDirectory.path)
        do {
            try await connection.start()
            let spawned = try await connection.request("_fake/spawn", params: [:])
            guard let pid = spawned.objectValue?["pid"]?.intValue.map(pid_t.init) else {
                return expect(false, "the agent reports its stubborn child")
            }
            let tree = ProcessTree.members(under: getpid())
            expect(tree.contains { $0.pid == pid }, "the tree walk finds a grandchild")
            connection.stop()
            try? await Task.sleep(for: .milliseconds(3_600))
            expect(kill(pid, 0) != 0, "a child that ignores SIGTERM is gone after stop")
            expect(!connection.isRunning, "and so is the agent")
        } catch {
            expect(false, "the teardown check runs, got \(error)")
        }
    }
}

extension ACPTests {
    /// Two copies of one CLI both call their first session `sess_1`: turns and asks still stay apart.
    static func twoAgentsSharingASessionIDStayApart() async {
        guard let node = await ExecutableLocator.locate("node") else { return }
        let fixture = FileManager.default.currentDirectoryPath + "/Tests/acp-fixtures/fake-agent.mjs"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ACPTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func agent(_ name: String) -> AgentProfile {
            let folder = root.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return AgentProfile(
                name: name, directory: folder.path,
                runtime: AgentRuntime(kind: .custom, command: node.path, arguments: [fixture]))
        }
        let first = agent("First")
        let second = agent("Second")
        let routed = Routed()
        let host = AgentACPHost(
            store: AgentStore(directory: root.appendingPathComponent("support")),
            permit: { agent, request in
                routed.sessions[agent.id] = request.sessionID
                routed.chats[agent.id] = routed.host?.chatID(forSession: request.sessionID, of: agent.id)
                // Both turns stay in flight until both have asked, so their sessions coexist.
                for _ in 0..<100 where routed.chats.count < 2 { try? await Task.sleep(for: .milliseconds(50)) }
                return request.dialogOptions.first?.id
            },
            context: { _ in nil })
        routed.host = host
        defer { host.stopAll() }
        func turn(_ agent: AgentProfile, chat: UUID) async -> String {
            let provider = ACPAgentProvider(host: host, agent: agent, servers: { [] })
            var text = ""
            let request = AIRequest(messages: [AIMessage(role: .user, text: "Hi")], conversationID: chat)
            do {
                for try await event in provider.stream(request) {
                    if case .text(let chunk) = event { text += chunk }
                }
            } catch {
                return "error: \(error)"
            }
            return text
        }
        let firstChat = UUID()
        let secondChat = UUID()
        async let firstReply = turn(first, chat: firstChat)
        async let secondReply = turn(second, chat: secondChat)
        let replies = await (firstReply, secondReply)
        expect(
            routed.sessions[first.id] == routed.sessions[second.id] && routed.sessions[first.id] != nil,
            "both agents named their session alike, got \(routed.sessions)")
        expect(
            routed.chats[first.id] == firstChat && routed.chats[second.id] == secondChat,
            "each permission request maps back to its own agent's chat")
        expect(
            replies.0.contains(first.directory) && !replies.0.contains(second.directory)
                && replies.1.contains(second.directory) && !replies.1.contains(first.directory),
            "and each turn streams only its own agent's reply, got \(replies)")
    }
}

@MainActor
final class Routed {
    weak var host: AgentACPHost?
    var sessions: [UUID: String] = [:]
    var chats: [UUID: UUID] = [:]
}

@MainActor
final class Asked {
    var requests: [ACPPermissionRequest] = []
}

@MainActor
final class SeenOptions {
    var options: [ACPSessionOptions] = []
}

@MainActor
final class Answer {
    var choice: String?
}

extension ACPTests {
    static func toolContentIsCompactedOnce() {
        func rows(_ old: String?, _ new: String) -> [String] {
            ChatToolContent.compactDiff(old: old, new: new).map { row in
                switch row {
                case .context(let text): " " + text
                case .removed(let text): "-" + text
                case .added(let text): "+" + text
                case .cut(let count): "~\(count)"
                }
            }
        }
        let numbered = (1...20).map { "line \($0)" }
        var edited = numbered
        edited[4] = "LINE 5"
        edited[15] = "LINE 16"
        edited.insert("inserted", at: 10)
        expect(
            rows(numbered.joined(separator: "\n"), edited.joined(separator: "\n")) == [
                "~2", " line 3", " line 4", "-line 5", "+LINE 5", " line 6", " line 7", " line 8", " line 9",
                " line 10", "+inserted", " line 11", " line 12", " line 13", " line 14", " line 15", "-line 16",
                "+LINE 16", " line 17", " line 18", "~2",
            ],
            "each change on its own lines with two of context, a fold of one line left as the line")
        var apart = (1...30).map { "line \($0)" }
        apart[4] = "five"
        apart[24] = "twenty-five"
        let folded = rows((1...30).map { "line \($0)" }.joined(separator: "\n"), apart.joined(separator: "\n"))
        expect(
            folded.contains("~15") && folded.first == "~2" && folded.last == "~3",
            "a long unchanged run between two changes folds into its count, got \(folded)")
        let created = rows(nil, (1...200).map { "row \($0)" }.joined(separator: "\n"))
        expect(
            created.count == ChatToolContent.maxDiffLines && created.first == "+row 1"
                && created.last == "~\(200 - ChatToolContent.maxDiffLines + 1)",
            "a new file is additions, cut to the row's lines with the rest counted, got \(created.suffix(2))")
        expect(rows("same\nlines", "same\nlines").isEmpty, "a diff that changes nothing shows no lines")
        expect(rows("a\r\nb\r\n", "a\r\nc\r\n") == [" a", "-b", "+c"], "CRLF lines compare as lines")
        expect(
            ChatToolContent.lines(of: ChatToolContent.Diff(path: "p", lines: "-a\r\n+b\n\u{1F}3"))
                == [.removed("a"), .added("b"), .cut(3)],
            "and read back as lines, whatever ended them")
        let wide = rows(
            (1...400).map { "old \($0)" }.joined(separator: "\n"),
            (1...400).map { "new \($0)" }.joined(separator: "\n"))
        expect(
            wide.first == "-old 1" && wide.count == ChatToolContent.maxDiffLines,
            "past the line diff's budget the old block shows, then the new, still capped")

        let output = ChatToolContent.compactOutput(
            "```console\n\u{1B}[32mok\u{1B}[0m 3 tests\r\ndownloading 10%\rdownloaded\n\u{1B}]0;title\u{07}done\n```",
            keepsTail: true)
        expect(
            output == [.context("ok 3 tests"), .context("downloaded"), .context("done")],
            "escapes, one wrapping fence and overwritten progress are gone, got \(String(describing: output))")
        expect(ChatToolContent.compactOutput("\n  \n", keepsTail: false) == nil, "blank output is no output")
        let long = (1...500).map { "out \($0)" }.joined(separator: "\n")
        let command = ChatToolContent.compactOutput(long, keepsTail: true) ?? []
        expect(
            command.count == ChatToolContent.maxOutputLines + 1 && command.last == .context("out 500")
                && command.contains(.cut(500 - ChatToolContent.maxOutputLines)),
            "a command's output keeps its end, where errors land")
        let read = ChatToolContent.compactOutput(long, keepsTail: false) ?? []
        expect(read.first == .context("out 1") && read.count == command.count, "anything else keeps its start")

        let huge = String(repeating: "x", count: 5_000)
        var call = ACPToolCall([
            "toolCallId": .string("c"), "kind": .string("execute"),
            "content": .array(
                (0..<10).map { index in
                    .object([
                        "type": .string("diff"), "path": .string("/p/\(index).txt"), "oldText": .null,
                        "newText": .string((1...300).map { "\($0) \(huge)" }.joined(separator: "\n"))
                    ])
                } + [
                    .object([
                        "type": .string("content"),
                        "content": .object(["type": .string("text"), "text": .string(long)])
                    ])
                ])
        ])
        guard let content = call.flatMap(ChatToolContent.init(call:)) else {
            return expect(false, "a call with content compacts")
        }
        expect(content.diffs.count == ChatToolContent.maxDiffs, "diffs stop at the row's count")
        expect(content.omittedDiffs == 10 - ChatToolContent.maxDiffs, "and the ones left out are counted")
        expect(content.output != nil, "a call with both keeps room for its output")
        let stored = content.encoded ?? ""
        expect(
            stored.utf8.count <= ChatToolContent.maxBytes + 2_048,
            "what a row persists is bounded, got \(stored.utf8.count) bytes")
        expect(ChatToolContent(encoded: stored) == content, "and reads back as it was written")
        expect(
            ChatToolContent.lines(of: content.diffs[0]).last.map { if case .cut = $0 { true } else { false } } == true,
            "a diff cut by the budget ends in a count of what it left out")
        expect(
            ChatToolContent(encoded: #"{"output":"a","later":true}"#) == ChatToolContent(output: "a"),
            "a row written by a later build, with fields this one does not know, still opens")
        expect(ChatToolContent(encoded: "{}")?.isEmpty == true, "and one missing every field is empty")
        call = ACPToolCall(["toolCallId": .string("c"), "content": .array([])])
        expect(call.flatMap(ChatToolContent.init(call:)) == nil, "content with nothing to show is no content")
    }

    static func toolOutputReachesItsRowOnce() {
        var mapper = ACPEventMapper(origin: "Agent")
        let diff: JSONValue = .array([
            .object([
                "type": .string("diff"), "path": .string("/a"), "oldText": .string("x"),
                "newText": .string("y")
            ])
        ])
        let opened = mapper.events(for: .toolCall(ACPToolCall([
            "toolCallId": .string("c"), "title": .string("Edit"), "content": diff
        ])!))
        guard opened.count == 2, case .toolOutput(let id, let content) = opened[1] else {
            return expect(false, "a call with content opens its row, then fills it, got \(opened)")
        }
        expect(id == "c" && content.diffs.first?.lines == "-x\n+y", "with the diff, got \(content)")
        expect(
            mapper.events(for: .toolCallUpdate(ACPToolCall(["toolCallId": .string("c"), "content": diff])!))
                .isEmpty,
            "the same content again sends nothing")
        expect(
            mapper.events(for: .toolCallUpdate(ACPToolCall(["toolCallId": .string("c")])!)).isEmpty,
            "an update without content leaves the row's as it was")
        let done = mapper.events(for: .toolCallUpdate(ACPToolCall([
            "toolCallId": .string("c"), "status": .string("completed"),
            "content": .array([
                .object(["type": .string("content"), "content": .object(["type": .string("text"), "text": .string("ok")])])
            ])
        ])!))
        expect(
            done == [.toolOutput(id: "c", content: ChatToolContent(output: "ok")), .toolResult(id: "c", isError: false)],
            "new content replaces the old before the row closes, got \(done)")
    }

    static func commandsDecodeMatchAndComplete() {
        let listed = ACPCommand.list(
            JSONValue(data: Data((#"[{"name":"/review","description":"Review\nchanges","input":{"hint":"what"}},"# +
                #"{"name":"compact"},{"name":"bad name"},{"name":"a/b"},{"name":"Review"},"# +
                #"{"name":"pr-comments","description":"Comments","input":null}]"#).utf8)))
        expect(
            listed.map(\.name) == ["review", "compact", "pr-comments"],
            "a leading slash goes, and names that could never be typed back or repeat are dropped, got \(listed)")
        expect(listed.first?.description == "Review changes" && listed.first?.hint == "what", "one line, with its hint")
        expect(listed[1].hint == nil && listed[1].description.isEmpty, "a command may have neither")
        let many = ACPCommand.list(.array((0..<500).map { .object(["name": .string("c\($0)")]) }))
        expect(many.count == ACPCommand.maxCount, "a list is held to its cap")
        expect(ACPCommand.typedName(in: "/rev") == "rev", "a draft after its slash is a name being typed")
        expect(ACPCommand.typedName(in: "/review now") == nil, "until a space ends it")
        expect(ACPCommand.typedName(in: "review") == nil, "and a draft without a slash types none")
        expect(ACPCommand.matches(for: "/", in: listed) == listed, "a bare slash offers every command")
        expect(
            ACPCommand.matches(for: "/CO", in: listed).map(\.name) == ["compact", "pr-comments"],
            "names it starts come first, then the ones it appears in, in any case")
        expect(ACPCommand.matches(for: "/zzz", in: listed).isEmpty, "a name nothing has offers nothing")
        let longerFirst = ACPCommand.list(.array(["statusline", "status", "my-status"].map {
            .object(["name": .string($0)])
        }))
        let typed = ACPCommand.matches(for: "/Status", in: longerFirst)
        expect(
            typed.map(\.name) == ["status", "statusline", "my-status"],
            "a name typed out in full leads, wherever the agent listed it, got \(typed.map(\.name))")
        expect(
            typed.first?.isTypedOut(in: "/status") == true && typed.first?.isTypedOut(in: "/Status") == false,
            "so Return sends it as typed, and a name in another case completes to the agent's spelling")
        expect(typed[1].isTypedOut(in: "/status") == false, "while a longer one is only ever completed")
        expect(listed[0].completion == "/review ", "completing leaves the name and room for its input")
        expect(ACPCommand.invocation(in: "/review the diff", offered: listed) == "review", "an offered command runs")
        expect(ACPCommand.invocation(in: "/Review", offered: listed) == "review", "in any case")
        expect(ACPCommand.invocation(in: "/unknown x", offered: listed) == nil, "a name the agent never offered is text")
        expect(ACPCommand.invocation(in: "/etc/hosts", offered: []) == nil, "and a path is never a command")
        expect(ACPCommand.invocation(in: "/compact", offered: []) == "compact", "before any list, a bare name is one")
        expect(ACPCommand.invocation(in: "compact", offered: listed) == nil, "text without its slash is text")
    }

    static func aCommandLeadsItsPrompt() {
        let message = AIMessage(
            role: .user, text: "/review now",
            documents: [AIDocument(data: Data("a".utf8), mimeType: "text/plain", name: "a.txt")])
        let blocks = ACPPrompt.blocks(
            for: message, context: "CONTEXT", earlier: "User: Hello", capabilities: .init(), asCommand: true)
        expect(blocks.first?["text"] as? String == "/review now", "the command is the first block, where agents look")
        expect(blocks.count == 2, "followed by its files, with no briefing or history")
    }
}

extension ACPTests {
    /// A scripted agent's edit and command fill their rows once, between opening and closing them.
    static func toolContentReachesItsRows() async {
        guard let (agent, host, root) = await fakeAgent() else { return }
        defer {
            host.stopAll()
            try? FileManager.default.removeItem(at: root)
        }
        let events = await stream("DIFF", chat: UUID(), agent: agent, host: host)
        let outputs = events.compactMap { event -> (String, ChatToolContent)? in
            if case .toolOutput(let id, let content) = event { (id, content) } else { nil }
        }
        expect(outputs.map(\.0) == ["call_d", "call_x"], "each call's content arrives once, got \(outputs.map(\.0))")
        expect(
            outputs.first?.1.diffs.first.map { $0.path == "/tmp/a.txt" && $0.lines == " keep\n-old\n+new\n keep 2" }
                == true,
            "the edit's diff, with its context, got \(String(describing: outputs.first?.1))")
        expect(
            outputs.last?.1.output == "ok 3 tests",
            "the command's output, cleaned, got \(String(describing: outputs.last?.1))")
        let callOpens = events.firstIndex(of: .toolCall(id: "call_x", origin: "Fake", title: "npm test"))
        let callCloses = events.firstIndex(of: .toolResult(id: "call_x", isError: false))
        let filled = events.firstIndex { if case .toolOutput(id: "call_x", _) = $0 { true } else { false } }
        expect(
            callOpens != nil && filled != nil && callCloses != nil && callOpens! < filled! && filled! < callCloses!,
            "a row opens, fills, then closes")
    }

    /// The fake agent lists its commands just after `session/new` answers, before the chat binds.
    static func commandsReachTheChatAndLeadTheirTurn() async {
        guard let (agent, host, root) = await fakeAgent() else { return }
        defer {
            host.stopAll()
            try? FileManager.default.removeItem(at: root)
        }
        let listed = Listed()
        host.onCommands = { chat, _, commands in listed.events.append((chat, commands?.map(\.name))) }
        let chat = UUID()
        let command = replyText(await stream("/review the diff", chat: chat, agent: agent, host: host))
        expect(
            command.contains("ran /review the diff; without context; blocks 1"),
            "a command on a fresh session goes first and alone, got \(command)")
        try? await Task.sleep(for: .milliseconds(200))
        expect(
            listed.events.contains { $0.chat == chat && $0.names == ["review", "compact"] },
            "the session's commands reach its chat even when they beat its binding, got \(listed.events)")
        let ran = [AIMessage(role: .user, text: "/review the diff"), AIMessage(role: .assistant, text: command)]
        let next = replyText(await stream("Hello", chat: chat, history: ran, agent: agent, host: host))
        expect(
            next.contains("with context; no history"),
            "the briefing the command skipped rides the next turn, without the session's own turns, got \(next)")
        let older = UUID()
        let before = [AIMessage(role: .user, text: "Before"), AIMessage(role: .assistant, text: "Earlier reply")]
        _ = await stream("/compact", chat: older, history: before, agent: agent, host: host)
        let compacted = [AIMessage(role: .user, text: "/compact"), AIMessage(role: .assistant, text: "ran /compact")]
        let later = replyText(await stream("Hello", chat: older, history: before + compacted, agent: agent, host: host))
        expect(
            later.contains("with context; with history of 2 turns"),
            "a chat older than its session hears only the turns from before it, got \(later)")
        let other = replyText(await stream("/unknown thing", chat: UUID(), agent: agent, host: host))
        expect(
            other.contains("turn 1") && other.contains("with context"),
            "a name the agent never offered is an ordinary first turn, got \(other)")
        host.release(agentID: agent.id)
        expect(
            listed.events.last.map { $0.chat != nil && $0.names == nil } == true,
            "a chat's list goes with its agent's process, so only the agent's last one is kept")
    }

    static func aFreshProcessWaitsForItsCommands() async {
        guard let (agent, _, root) = await fakeAgent() else { return }
        let unattended = UUID()
        let host = AgentACPHost(
            store: AgentStore(directory: root.appendingPathComponent("support")),
            permit: { _, _ in nil }, context: { _ in "# Context from Tinycast" },
            briefing: { $0 == unattended ? AgentBackgroundBriefing.acp : nil })
        defer {
            host.stopAll()
            try? FileManager.default.removeItem(at: root)
        }
        let word = replyText(
            await stream("/tmp is full, find what is big", chat: unattended, agent: agent, host: host))
        expect(
            word.contains("turn 1") && word.contains("with context") && word.contains("briefed"),
            "on a fresh process, a name the agent does not offer is an ordinary, briefed turn, got \(word)")
        host.release(agentID: agent.id)
        let command = replyText(await stream("/review the diff", chat: UUID(), agent: agent, host: host))
        expect(
            command.contains("ran /review the diff; without context"),
            "after a release, a command the new process offers still goes as typed, got \(command)")
    }

    private static func fakeAgent() async -> (AgentProfile, AgentACPHost, URL)? {
        guard let node = await ExecutableLocator.locate("node") else { return nil }
        let fixture = FileManager.default.currentDirectoryPath + "/Tests/acp-fixtures/fake-agent.mjs"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ACPTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let agent = AgentProfile(
            name: "Fake", directory: root.path,
            runtime: AgentRuntime(kind: .custom, command: node.path, arguments: [fixture]))
        let host = AgentACPHost(
            store: AgentStore(directory: root.appendingPathComponent("support")),
            permit: { _, request in request.dialogOptions.first?.id },
            context: { _ in "# Context from Tinycast" })
        return (agent, host, root)
    }

    private static func stream(
        _ text: String, chat: UUID, history: [AIMessage] = [], agent: AgentProfile, host: AgentACPHost
    ) async -> [AIStreamEvent] {
        let provider = ACPAgentProvider(host: host, agent: agent, servers: { [] })
        var events: [AIStreamEvent] = []
        let request = AIRequest(messages: history + [AIMessage(role: .user, text: text)], conversationID: chat)
        do {
            for try await event in provider.stream(request) { events.append(event) }
        } catch {
            expect(false, "\(text) completes, got \(error)")
        }
        return events
    }

    private static func replyText(_ events: [AIStreamEvent]) -> String {
        events.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
    }
}

@MainActor
final class Listed {
    var events: [(chat: UUID?, names: [String]?)] = []
}

extension ACPTests {
    static func configOptionsDecodeAndSlot() {
        let result = JSONValue(data: Data(#"""
            {"sessionId":"s",
             "modes":{"currentModeId":"default","availableModes":[{"id":"default","name":"Manual"}]},
             "models":{"currentModelId":"x[low]","availableModels":[{"modelId":"x[low]","name":"X (low)"}]},
             "configOptions":[
              {"id":"mode","name":"Mode","category":"mode","type":"select","currentValue":"default",
               "options":[{"value":"default","name":"Manual"},{"value":"plan","name":"Plan","description":"Plans\nfirst"}]},
              {"id":"model","name":"Model","category":"model","type":"select","currentValue":"gone",
               "options":[{"group":"fast","name":"Fast","options":[{"value":"small","name":"Small"}]},
                          {"group":"smart","name":"Smart","options":[{"value":"large","name":"Large"}]}]},
              {"id":"effort","name":"Effort","category":"thought_level","type":"select","currentValue":"low",
               "options":[{"value":"low","name":"Low"},{"value":"high","name":"High"}]},
              {"id":"fast","name":"Fast mode","category":"model_config","type":"select","currentValue":"off",
               "options":[{"value":"off","name":"Off"},{"value":"on","name":"On"}]},
              {"id":"agent","name":"Agent","type":"select","currentValue":"default",
               "options":[{"value":"default","name":"Default"}]},
              {"id":"beta","name":"Beta","type":"boolean","currentValue":false},
              {"id":"empty","name":"Empty","type":"select","currentValue":"","options":[]}
             ]}
            """#.utf8)) ?? .null
        guard let options = ACPSessionOptions(result: result) else {
            return expect(false, "a session's config options decode")
        }
        expect(
            options.options.map(\.id) == ["mode", "model", "effort", "fast", "agent"],
            "selects in the agent's order; a boolean and an empty select are left out, got \(options.options.map(\.id))")
        expect(
            options.model?.id == "model" && options.reasoning?.id == "effort" && options.mode?.id == "mode",
            "the model, thought level and mode categories fill the composer's own pickers")
        expect(
            options.others.map(\.id) == ["fast", "agent"] && options.slot(of: options.others[1]) == .option("agent"),
            "every other select, with a category or none, goes under the overflow by its id")
        expect(
            options.model?.groups.map(\.name) == ["Fast", "Smart"]
                && options.model?.choices.map(\.value) == ["small", "large"],
            "grouped choices keep their groups")
        expect(options.model?.currentTitle == "gone", "a current value the list lacks shows as itself")
        expect(
            options.mode?.choices.last?.description == "Plans first" && options.mode?.setter == .configOption,
            "a description is one line, and the config option wins over the older modes")

        let older = ACPSessionOptions(result: JSONValue(data: Data(#"""
            {"modes":{"currentModeId":"ask","availableModes":[{"id":"ask","name":"Ask"},{"id":"code","name":"Code"}]},
             "models":{"currentModelId":"or:a","availableModels":[{"modelId":"or:a","name":"A"},{"modelId":"or:b"}]}}
            """#.utf8)) ?? .null)
        expect(
            older?.model?.setter == .legacyModel && older?.model?.choices.map(\.name) == ["A", "or:b"]
                && older?.mode?.setter == .legacyMode && older?.reasoning == nil,
            "an agent with only the older shapes still offers a model and a mode")
        let byModel = older?.model?.request(setting: "or:b", session: "s")
        expect(
            byModel?.method == "session/set_model" && byModel?.params["modelId"] as? String == "or:b",
            "an older model goes by set_model")
        expect(older?.mode?.request(setting: "code", session: "s").method == "session/set_mode", "a mode by set_mode")
        let byConfig = options.reasoning?.request(setting: "high", session: "s")
        expect(
            byConfig?.method == "session/set_config_option" && byConfig?.params["configId"] as? String == "effort"
                && byConfig?.params["value"] as? String == "high",
            "and a config option by its id and value")

        expect(options.step(for: .reasoning, wanting: "low") == .keep, "a value in effect is not sent again")
        expect(options.step(for: .model, wanting: "gone") == .keep, "even one the list no longer names")
        expect(options.step(for: .reasoning, wanting: "high") == .send(options.reasoning!), "an offered one is sent")
        expect(options.step(for: .reasoning, wanting: "max") == .forget, "a vanished one is forgotten")
        expect(older?.step(for: .reasoning, wanting: "max") == .keep, "a select nobody offers keeps its value")
        expect(options.step(for: .option("fast"), wanting: "on") == .send(options.others[0]), "by id for the rest")

        var replaced = older!
        replaced.replace(with: [options.model!])
        expect(
            replaced.model?.setter == .configOption && replaced.mode?.setter == .legacyMode,
            "an update replaces what it covers and keeps an older select it does not")
        let before = replaced
        replaced.replace(with: [])
        expect(replaced == before, "an empty list, as Hermes answers a set, wipes nothing")
        var settled = options
        settled.settle("high", in: "effort", answer: .object([:]))
        expect(settled.reasoning?.current == "high", "an answer without a list moves only the picked value")
        settled.settle(
            "large", in: "model",
            answer: .object(["configOptions": .array([JSONValue(data: Data(
                (#"{"id":"model","name":"Model","category":"model","type":"select","currentValue":"large","# +
                    #""options":[{"value":"large","name":"Large"}]}"#).utf8))!])]))
        expect(
            settled.options.map(\.id) == ["model"] && settled.model?.current == "large",
            "an answer with a list is the agent's whole state")
        var moved = options
        moved.moveMode(to: "plan")
        expect(moved.mode?.current == "plan", "the agent moving its mode moves the config option")
        moved.moveMode(to: "nowhere")
        expect(moved.mode?.current == "plan", "but never onto a mode it does not offer")

        let many = JSONValue.object([
            "configOptions": .array((0..<40).map { index in
                .object([
                    "id": .string("o\(index)"), "name": .string(String(repeating: "n", count: 300)),
                    "type": .string("select"), "currentValue": .string("v0"),
                    "options": .array((0..<600).map { .object(["value": .string("v\($0)")]) })
                ])
            })
        ])
        let capped = ACPSessionOptions(result: many)
        expect(
            capped?.options.count == ACPConfigOption.maxOptions
                && capped?.options.first?.choices.count == ACPConfigOption.maxChoices
                && (capped?.options.first?.name.count ?? 0) <= ACPConfigOption.maxNameLength,
            "a list is held to its caps")
    }

    static func rememberedChoicesApplyAndPersist() {
        var agent = AgentProfile(name: "A", directory: "/tmp")
        agent.acpChoices[.model] = "large"
        agent.acpChoices[.reasoning] = "high"
        agent.acpChoices[.mode] = "nope"
        agent.acpChoices[.option("fast")] = "on"
        agent.acpChoices[.option("agent")] = "x"
        expect(
            agent.acpChoices.wishes.map(\.slot) == [.model, .reasoning, .mode, .option("agent"), .option("fast")],
            "the model is applied first, since the levels and the rest follow it")
        let offered = ACPSessionOptions(options: [
            option("mode", .mode, current: "default", values: ["default", "plan"]),
            option("model", .model, current: "small", values: ["small", "large"]),
            option("effort", .thoughtLevel, current: "low", values: ["low", "high"]),
            option("fast", .other, current: "off", values: ["off", "on"]),
        ])
        let shown = offered.applying(agent.acpChoices)
        expect(
            shown.model?.current == "large" && shown.reasoning?.current == "high"
                && shown.others.first?.current == "on" && shown.mode?.current == "default",
            "a chat with no session shows the agent's list on what it remembers, unknown values left out")
        expect(
            ACPChoices(shown) == ACPChoices(model: "large", reasoning: "high", mode: "default", options: ["fast": "on"]),
            "what a session is on is every select's current value, by its slot")
        var moved = agent
        moved.acpChoices = ACPChoices()
        expect(moved.acpChoices.wishes.isEmpty, "another program under Runs on starts with nothing remembered")
        agent.acpChoices[.option("fast")] = nil
        agent.acpChoices[.option("agent")] = nil
        expect(agent.acpOptions == nil, "no other choice left stores none")

        let encoder = JSONEncoder()
        let untouched = AgentProfile(name: "B", directory: "/tmp")
        let plain = (try? encoder.encode(untouched)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        expect(
            !plain.contains("acpModel") && !plain.contains("acpReasoning") && !plain.contains("acpOptions"),
            "an agent that never picked writes none of the new keys")
        agent.acpChoices[.option("fast")] = "on"
        guard let data = try? encoder.encode(agent),
            let back = try? JSONDecoder().decode(AgentProfile.self, from: data)
        else { return expect(false, "an agent with choices round-trips") }
        expect(
            back.acpModel == "large" && back.acpReasoning == "high" && back.acpOptions == ["fast": "on"]
                && back.acpMode == "nope",
            "and reads back what it remembered")
        struct PreviousBuild: Decodable {
            let id: UUID
            let acpMode: String?
        }
        expect(
            (try? JSONDecoder().decode(PreviousBuild.self, from: data))?.acpMode == "nope",
            "a build that knows only the mode still reads the file")
        chatChoicesLiveWithTheirSession()
    }

    static func chatChoicesLiveWithTheirSession() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ACPTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentStore(directory: root)
        guard let agent = try? store.add(AgentProfile(name: "A", directory: "/tmp")) else {
            return expect(false, "the agent saves")
        }
        let own = ACPChoices(model: "huge", reasoning: "max", mode: "plan", options: ["fast": "on"])
        let (chat, sessionless) = (UUID(), UUID())
        store.setAgent(agent.id, forChat: chat)
        store.setAgent(agent.id, forChat: sessionless)
        store.setACPChoices(own, forChat: sessionless)
        expect(store.acpChoices(forChat: sessionless) == nil, "a chat without a session keeps no picks")
        store.setACPSession("s1", forChat: chat)
        store.setACPChoices(own, forChat: chat)
        let reread = AgentStore(directory: root)
        reread.load()
        expect(reread.acpChoices(forChat: chat) == own, "a chat's picks are read back after a relaunch")
        reread.setACPSession("s2", forChat: chat)
        expect(reread.acpChoices(forChat: chat) == own, "and kept when the agent lost the session for another")
        reread.setACPSession(nil, forChat: chat)
        let forgotten = AgentStore(directory: root)
        forgotten.load()
        expect(
            reread.acpChoices(forChat: chat) == nil && forgotten.acpChoices.isEmpty,
            "a chat's picks go with its session, on disk too")
    }

    private static func option(
        _ id: String, _ category: ACPConfigOption.Category, current: String, values: [String]
    ) -> ACPConfigOption {
        ACPConfigOption(
            id: id, name: id, description: nil, category: category, setter: .configOption, current: current,
            groups: [.init(id: "", name: nil, choices: values.map { .init(value: $0, name: $0, description: nil) })])
    }

    /// A remembered model, level, mode and other select reach a new or reloaded session first.
    static func configOptionsApplyBeforeTheFirstPrompt() async {
        guard let node = await ExecutableLocator.locate("node") else { return }
        let fixture = FileManager.default.currentDirectoryPath + "/Tests/acp-fixtures/fake-agent.mjs"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ACPTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let support = root.appendingPathComponent("support")
        let store = AgentStore(directory: support)
        var draft = AgentProfile(
            name: "Configured", directory: root.path,
            runtime: AgentRuntime(kind: .custom, command: node.path, arguments: [fixture, "config"]))
        draft.acpModel = "large"
        draft.acpReasoning = "high"
        draft.acpMode = "plan"
        draft.acpOptions = ["fast": "on"]
        guard let agent = try? store.add(draft) else { return expect(false, "the agent saves") }
        let unattended = UUID()
        let seen = SeenOptions()
        func host() -> AgentACPHost {
            let made = AgentACPHost(
                store: store, permit: { _, request in request.dialogOptions.first?.id },
                context: { _ in "# Context from Tinycast" },
                briefing: { $0 == unattended ? AgentBackgroundBriefing.acp : nil })
            made.onOptions = { _, _, options in if let options { seen.options.append(options) } }
            return made
        }
        let first = host()
        defer {
            first.stopAll()
            try? FileManager.default.removeItem(at: root)
        }

        let chat = UUID()
        let opened = replyText(await stream("Hello", chat: chat, agent: agent, host: first))
        expect(
            opened.contains("on large/high/plan/on; sets model=large,effort=high,mode=plan,fast=on"),
            "every remembered choice reaches a new session before its first prompt, model first, got \(opened)")
        let applied = seen.options.last
        expect(
            applied?.model?.current == "large" && applied?.reasoning?.choices.map(\.value) == ["low", "medium", "high"]
                && applied?.others.map(\.id) == ["fast"] && applied?.mode?.setter == .configOption,
            "the composer sees the list the last answer carried, got \(String(describing: applied))")

        try? await first.setOption("small", for: .model, chatID: chat)
        expect(
            seen.options.last?.model?.current == "small" && seen.options.last?.reasoning?.current == "medium",
            "a live switch shows the agent's answer, its level clamped by the agent")
        let shownBefore = seen.options.count
        do {
            try await first.setOption("max", for: .reasoning, chatID: chat)
            expect(false, "a level the model lacks is refused")
        } catch {
            expect(
                seen.options.count == shownBefore + 1 && seen.options.last?.reasoning?.current == "medium",
                "a refused pick puts the session's own state back in front of the composer")
        }
        _ = await stream("SWITCHMODEL", chat: chat, agent: agent, host: first)
        expect(
            seen.options.last?.model?.current == "huge" && seen.options.last?.reasoning?.current == "high",
            "and the agent's own change arrives as config_option_update")

        guard var stored = store.agent(id: agent.id) else { return expect(false, "the agent is stored") }
        stored.acpModel = "retired"
        stored.acpReasoning = "max"
        try? store.update(stored)
        let alone = replyText(await stream("Alone", chat: unattended, agent: agent, host: first))
        expect(
            alone.contains("briefed") && alone.contains("on small/low/plan/on; sets mode=plan,fast=on"),
            "an unattended run starts the same way, values the agent no longer offers not sent, got \(alone)")
        let kept = AgentStore(directory: support)
        kept.load()
        let reread = kept.agent(id: agent.id)
        expect(
            reread?.acpModel == nil && reread?.acpReasoning == nil && reread?.acpMode == "plan"
                && reread?.acpOptions == ["fast": "on"],
            "and they are forgotten on the agent, on disk, while the rest stays")

        stored = store.agent(id: agent.id) ?? stored
        stored.acpModel = "small"
        try? store.update(stored)
        let other = UUID()
        let started = replyText(await stream("Hello", chat: other, agent: agent, host: first))
        expect(started.contains("on small/low/plan/on"), "another chat starts on the agent's latest, got \(started)")
        first.stopAll()
        let relaunched = host()
        defer { relaunched.stopAll() }
        let reloaded = replyText(await stream("After relaunch", chat: chat, agent: agent, host: relaunched))
        expect(
            reloaded.contains("turn 11") && reloaded.contains("on huge/high/plan/on; sets model=huge,effort=high"),
            "a reloaded chat is put back on its own picks, not another chat's, got \(reloaded)")
        let otherAgain = replyText(await stream("After relaunch", chat: other, agent: agent, host: relaunched))
        expect(otherAgain.contains("on small/low/plan/on"), "and so is the other chat, got \(otherAgain)")
        expect(store.agent(id: agent.id)?.acpModel == "small", "a reload leaves the agent's own picks alone")

        stored = store.agent(id: agent.id) ?? stored
        stored.acpModel = "large"
        try? store.update(stored)
        let earlier = UUID()
        store.setACPSession("sess_earlier", forChat: earlier)
        let older = replyText(await stream("Continue", chat: earlier, agent: agent, host: relaunched))
        expect(
            older.contains("turn 11") && older.contains("sets model=large,mode=plan,fast=on"),
            "a chat from a build before its own picks reloads on the agent's, got \(older)")
    }
}
