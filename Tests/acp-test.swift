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
        eventsSettleEachCallOnce()
        runtimesParseTheirArguments()
        await aRealProcessStreamsATurn()
        await stoppingLeavesNoProcessBehind()
        await twoAgentsSharingASessionIDStayApart()

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
            decoded(#"{"sessionId":"s","update":{"sessionUpdate":"available_commands_update","availableCommands":[]}}"#)
                == .other("available_commands_update"),
            "an update not drawn yet is kept as known, not dropped as malformed")
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

    static func promptsCarryContextOnlyWhenFresh() {
        let message = AIMessage(
            role: .user, text: "Fix it",
            images: [AIImage(data: Data([1, 2]), mimeType: "image/png")],
            documents: [AIDocument(data: Data("a,b".utf8), mimeType: "text/csv", name: "t.csv")])
        let history = [
            AIMessage(role: .user, text: "Hello"), AIMessage(role: .assistant, text: "Hi there")
        ]
        let full = ACPPrompt.blocks(
            for: message, context: "CONTEXT", history: history,
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
            for: message, context: nil, history: [], capabilities: .init())
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
        let seen = SeenModes()
        let host = AgentACPHost(
            store: store,
            permit: { _, request in
                asked.requests.append(request)
                return answer.choice ?? request.dialogOptions.first?.id
            },
            context: { _ in "# Context from Tinycast\nYou are Fake." })
        host.onModes = { _, _, modes in seen.modes.append(modes) }
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

        expect(
            seen.modes.first?.available.map(\.id) == ["default", "plan"]
                && seen.modes.first?.current == "default",
            "a new session reports the modes it offers and the one it is in")
        try? await host.setMode("plan", chatID: chat)
        expect(seen.modes.last?.current == "plan", "switching a live session's mode reports it")
        _ = await turn("LEAVEPLAN", chat: chat, host: host)
        expect(seen.modes.last?.current == "default", "and so does the agent moving itself")

        let second = await turn("Again", chat: chat, host: host)
        let again = text(second.events)
        expect(
            again.contains("turn 3") && again.contains("without context") && again.contains("no history"),
            "the next turn reuses the session without repeating context, got \(again)")

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
        let planned = ACPAgentProvider(host: relaunched, agent: planner, servers: { [] })
        let plannerChat = UUID()
        seen.modes.removeAll()
        relaunched.onModes = { _, _, modes in seen.modes.append(modes) }
        do {
            for try await _ in planned.stream(
                AIRequest(messages: [AIMessage(role: .user, text: "Hi")], conversationID: plannerChat))
            {}
        } catch {
            expect(false, "a planner's turn completes, got \(error)")
        }
        expect(seen.modes.last?.current == "plan", "an agent's chosen mode is applied as its session starts")
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
final class SeenModes {
    var modes: [ACPModes] = []
}

@MainActor
final class Answer {
    var choice: String?
}
