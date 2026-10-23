import Foundation

@main
@MainActor
struct AIProviderTests {
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

    static func instructionsFollowTheSetting() {
        for prompt in [nil, "", "   \n\t "] as [String?] {
            expect(
                AIInstructions.compose(userPrompt: prompt, isEnabled: true, offersChoices: false)
                    == AIPreamble.text,
                "an absent or blank user prompt with choices off sends the preamble alone")
        }
        expect(
            AIInstructions.compose(
                userPrompt: "  Answer only in haiku.  ", isEnabled: true, offersChoices: true)
                == AIPreamble.text + "\n\n" + AIPreamble.choices + "\n\nAnswer only in haiku.",
            "instructions put the preamble and its choices before the trimmed user prompt")
        for prompt in [nil, "Answer only in haiku."] as [String?] {
            expect(
                AIInstructions.compose(userPrompt: prompt, isEnabled: false, offersChoices: true)
                    == nil,
                "disabled instructions withhold the preamble, its choices and the user prompt")
        }
        expect(
            (AIPreamble.text + AIPreamble.choices).count < 1_800,
            "the preamble stays within its per-turn budget")
    }

    /// A wrong document shape must fail here rather than mid-conversation.
    static func requestBodiesCarryDocuments() {
        let pdf = AIDocument(
            data: Data("%PDF-1.4".utf8), mimeType: "application/pdf", name: "report.pdf")
        let image = AIImage(data: Data([0x89, 0x50]), mimeType: "image/png")
        let turn = AIRequest(
            messages: [
                AIMessage(role: .user, text: "summarise", images: [image], documents: [pdf])
            ])

        let anthropic = AIRequestBody.make(
            turn,
            configuration: AIHTTPConfiguration(
                provider: .anthropic, baseURL: URL(string: "https://api.anthropic.com")!,
                model: "claude"))
        let blocks =
            (anthropic["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]] ?? []
        expect(
            blocks.map { $0["type"] as? String } == ["image", "document", "text"],
            "Anthropic takes image then document, with the text block last")
        let source =
            blocks.first { $0["type"] as? String == "document" }?["source"]
            as? [String: Any]
        expect(
            source?["type"] as? String == "base64"
                && source?["media_type"] as? String == "application/pdf",
            "as a base64 document source naming its media type")
        expect(
            (source?["data"] as? String)?.contains("\n") == false,
            "whose base64 carries no newlines")

        let openAI = AIRequestBody.make(
            turn,
            configuration: AIHTTPConfiguration(
                provider: .openAI, baseURL: URL(string: "https://api.openai.com/v1")!,
                model: "gpt"))
        let parts =
            (openAI["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]] ?? []
        expect(
            parts.map { $0["type"] as? String } == ["text", "image_url", "file"],
            "OpenAI keeps its text part first and appends the file part")
        let file = parts.first { $0["type"] as? String == "file" }?["file"] as? [String: Any]
        expect(
            file?["filename"] as? String == "report.pdf",
            "the file part names the document")
        expect(
            (file?["file_data"] as? String)?.hasPrefix("data:application/pdf;base64,") == true,
            "and carries it as a data URL")

        // A turn that is only a document must not collapse to the plain-string fast path.
        let documentOnly = AIRequestBody.make(
            AIRequest(messages: [AIMessage(role: .user, text: "", documents: [pdf])]),
            configuration: AIHTTPConfiguration(
                provider: .openAI, baseURL: URL(string: "https://api.openai.com/v1")!,
                model: "gpt"))
        expect(
            ((documentOnly["messages"] as? [[String: Any]])?.first?["content"]
                as? [[String: Any]])?.count == 1,
            "a document-only turn still sends, as content parts")
    }

    /// The fork's extension `creativity`: sent only when asked, within Anthropic's narrower range.
    static func temperatureIsSentOnlyWhenAsked() {
        func body(_ provider: AIProviderKind, _ temperature: Double?) -> [String: Any] {
            AIRequestBody.make(
                AIRequest(messages: [AIMessage(role: .user, text: "hi")], temperature: temperature),
                configuration: AIHTTPConfiguration(
                    provider: provider, baseURL: URL(string: provider.defaultBaseURL)!, model: "m"))
        }
        expect(
            body(.openAI, 1.5)["temperature"] as? Double == 1.5
                && body(.gemini, 0.4)["temperature"] as? Double == 0.4
                && body(.openRouter, 0)["temperature"] as? Double == 0,
            "OpenAI-shaped bodies carry the temperature as given")
        expect(
            body(.anthropic, 1.5)["temperature"] as? Double == 1
                && body(.anthropic, 0.4)["temperature"] as? Double == 0.4,
            "Anthropic's is held to its 0–1 range")
        expect(
            [AIProviderKind.openAI, .anthropic, .gemini].allSatisfy { body($0, nil)["temperature"] == nil },
            "no temperature is sent unless asked, so every route keeps its default")
        let turn = AIRequest(messages: [], temperature: 0.7)
        expect(turn.continuing(with: [], tools: []).temperature == 0.7, "a continued turn keeps it")
    }

    static func main() {
        instructionsFollowTheSetting()
        providerPresetsResolveEndpoints()
        modelCatalogBuildsProviderRequests()
        requestHeadersAreValidated()
        modelCatalogDecodesProviderResponses()
        modelCatalogSearchesWithoutRenderingEverything()
        exactMatchNamesOnlyAWholeModel()
        endpointPolicyRejectsUnsafeRemoteURLs()
        storedKeysDoNotFollowARetargetedConnection()
        savingAConnectionDecidesItsKey()
        sseFramesSurviveSplits()
        openAIAndAnthropicStreamsDecode()
        capturedStreamsDecodeHoweverTheyArrive()
        thinkTagStreamsDecodeHoweverTheyArrive()
        brokenStreamsFailLoudly()
        refusalsShowTheProvidersOwnWords()
        brandsResolveFromModelIDs()
        requestBodiesCarryDocuments()
        claudeRoutesMarkTheirCachedPrefix()
        temperatureIsSentOnlyWhenAsked()
        codexProtocolFramesRoundTrip()
        installedCLIStreamsDecode()
        settingsPersistAndRepairSelections()
        installedModelLoadingPreferencePersists()
        shownModelsFilterThePicker()
        switchedOffRoutesLeaveTheDefault()
        installedOverridesPersistAndResolve()
        aFailedKeychainReadIsNeverSavedOver()
        aLaunchInheritsTheReadersVariablesNotTinycastsOwn()
        subscriptionSelectionsReconcile()
        onDeviceSelectionsRoundTripAndLead()
        conversationSettingsPersistAndDecide()
        toolCatalogsAndTurnsEncodePerProvider()
        toolArgumentsSurviveArrivingInFragments()
        geminiThoughtSignaturesRoundTrip()
        toolCapabilitiesFollowTheRoute()
        codexLaunchNamesServersAndKeepsSecretsOffArgv()
        codexLaunchHandsAServerItsOwnVariableNames()
        codexVariablesNeverCollide()
        claudeConfigurationCarriesServersAndRoutesToolNames()
        codexElicitationsAreOnlyToolCalls()
        claudeControlFramesAnswerOneTool()
        aGatewayOffersNoneAsItsReasoningEffort()
        declaredLevelsNeverReachAVendorOrOutliveTheirDeclaration()
        cachedTokensCountApartFromInput()
        reasoningDetailsMergeAsTheyStream()
        reasoningContentIsKeptInItsOwnField()
        thinkTagsAreKeptAsTags()
        anthropicThinkingBlocksKeepTheirSignatures()
        signedCallsStampTheirReply()
        eachProviderIsSentItsOwnReasoningBack()
        aReplyTheCapCutSaysSo()
        anAgentRoundCarriesItsOwnCap()
        failuresSayWhetherTheyMayPass()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Fork: reasoning round-trip and cache hits

    private static func lastUsage(_ shape: AIHTTPConfiguration.APIShape, _ stream: String) -> AIUsage? {
        var decoder = AIStreamDecoder(shape: shape)
        let events = ((try? decoder.feed(Data(stream.utf8))) ?? []) + ((try? decoder.finish()) ?? [])
        return events.reversed().lazy.compactMap { event -> AIUsage? in
            if case .usage(let usage) = event { return usage }
            return nil
        }.first
    }

    /// A hit counts outside `inputTokens` on both shapes, so prompt = input + cached everywhere.
    static func cachedTokensCountApartFromInput() {
        let routed = lastUsage(
            .openAICompatible,
            """
            data: {"choices":[],"usage":{"prompt_tokens":1000,"completion_tokens":10,\
            "prompt_tokens_details":{"cached_tokens":800},"cost":0.001}}

            data: [DONE]

            """)
        expect(
            routed?.inputTokens == 200 && routed?.cachedInputTokens == 800 && routed?.outputTokens == 10,
            "OpenRouter's and OpenAI's cached_tokens leave the prompt as a hit, got \(String(describing: routed))")
        let deepSeek = lastUsage(
            .openAICompatible,
            """
            data: {"choices":[],"usage":{"prompt_tokens":1000,"completion_tokens":5,\
            "prompt_cache_hit_tokens":900,"prompt_cache_miss_tokens":100}}

            data: [DONE]

            """)
        expect(
            deepSeek?.inputTokens == 100 && deepSeek?.cachedInputTokens == 900,
            "DeepSeek's prompt_cache_hit_tokens are its hits")
        let cold = lastUsage(
            .openAICompatible,
            """
            data: {"choices":[],"usage":{"prompt_tokens":1000,"completion_tokens":5,\
            "prompt_tokens_details":{"cached_tokens":0}}}

            data: [DONE]

            """)
        expect(
            cold?.inputTokens == 1000 && cold?.cachedInputTokens == nil, "a cold prompt reports no hit")
        let anthropic = lastUsage(
            .anthropic,
            """
            data: {"type":"message_start","message":{"usage":{"input_tokens":50,\
            "cache_read_input_tokens":400,"cache_creation_input_tokens":30}}}

            data: {"type":"message_stop"}

            """)
        expect(
            anthropic?.inputTokens == 80 && anthropic?.cachedInputTokens == 400,
            "Anthropic's read is the hit and its write is new input, got \(String(describing: anthropic))")
        let written = lastUsage(
            .anthropic,
            """
            data: {"type":"message_start","message":{"usage":{"input_tokens":50,\
            "cache_creation_input_tokens":30}}}

            data: {"type":"message_stop"}

            """)
        expect(
            written?.inputTokens == 80 && written?.cachedInputTokens == nil,
            "a first request that only writes the cache reports no hit")
    }

    private static func json(_ text: String) -> JSONValue { JSONValue(data: Data(text.utf8)) ?? .null }

    private static func replays(_ events: [AIStreamEvent]) -> [AIReasoningReplay] {
        events.compactMap { event -> AIReasoningReplay? in
            if case .reasoningReplay(let replay) = event { return replay }
            return nil
        }
    }

    private static func decode(
        _ shape: AIHTTPConfiguration.APIShape, _ stream: String, slice: Int = .max,
        route: String = "api.example.com", model: String = "m"
    ) -> [AIStreamEvent] {
        let data = Data(stream.utf8)
        var decoder = AIStreamDecoder(shape: shape, model: model, route: route)
        var events: [AIStreamEvent] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + min(slice, data.count), data.count)
            events += (try? decoder.feed(data[offset..<end])) ?? []
            offset = end
        }
        return events + ((try? decoder.finish()) ?? [])
    }

    /// pi's merge: neighbouring text and summary deltas join, an encrypted entry stays whole.
    static func reasoningDetailsMergeAsTheyStream() {
        guard
            let data = FileManager.default.contents(
                atPath: "Tests/ai-fixtures/openrouter-reasoning-details-stream.txt")
        else { return expect(false, "the reasoning-details fixture is readable") }
        let expected = AIReasoningReplay(
            route: "openrouter.ai", model: "google/gemini-3.8-flash", form: .details, text: "Search first.",
            items: [
                json(#"{"type":"reasoning.text","text":"Search first.","format":"google-gemini-v1","index":0}"#),
                json(
                    #"{"type":"reasoning.encrypted","data":"CiQB+opaque/sig==","id":"tool_c1","#
                        + #""format":"google-gemini-v1","index":0}"#),
                json(#"{"type":"reasoning.summary","summary":"Plan: search.","index":1}"#)
            ])
        for slice in [data.count, 7] {
            let events = decode(
                .openAICompatible, String(bytes: data, encoding: .utf8) ?? "", slice: slice, route: "openrouter.ai",
                model: "google/gemini-3.8-flash")
            expect(
                replays(events) == [expected],
                "one replay per reply, merged, ordered and stamped with its route and model "
                    + "(\(slice)-byte slices), got \(replays(events))")
            let replayAt = events.firstIndex { if case .reasoningReplay = $0 { true } else { false } }
            let callAt = events.firstIndex { if case .toolCallRequested = $0 { true } else { false } }
            expect(
                replayAt != nil && callAt != nil && replayAt! < callAt!,
                "and it arrives before the calls it belongs with")
            expect(
                events.contains(.reasoning("Search")) && !events.contains(.text("Search")),
                "while the fold still shows the reasoning as it streams")
        }
        let split = decode(
            .openAICompatible,
            """
            data: {"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.text","id":"reasoning-text-1",\
            "format":"MiniMax-response-v1","index":0,"text":"Check the "}]}}]}

            data: {"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.text","id":"reasoning-text-1",\
            "format":"MiniMax-response-v1","index":0,"text":"file."}]}}]}

            data: {"choices":[{"delta":{"content":"Done."},"finish_reason":"stop"}]}

            data: [DONE]

            """, route: "api.minimax.io", model: "MiniMax-M2.7")
        expect(
            replays(split) == [
                AIReasoningReplay(
                    route: "api.minimax.io", model: "MiniMax-M2.7", form: .details, text: "Check the file.",
                    items: [
                        json(
                            #"{"type":"reasoning.text","id":"reasoning-text-1","format":"MiniMax-response-v1","#
                                + #""index":0,"text":"Check the file."}"#)
                    ])
            ],
            "MiniMax's split output merges the same way, and its text is the entries', got \(replays(split))")
        expect(
            split.last == .finished && split.dropLast().last.map { if case .reasoningReplay = $0 { true } else { false } }
                == true,
            "a reply that called nothing still hands over its reasoning, last before it finishes")
    }

    /// DeepSeek, Qwen, Kimi, MiniMax and GLM stream `reasoning_content`; it comes back as that field.
    static func reasoningContentIsKeptInItsOwnField() {
        let stream = """
            data: {"choices":[{"delta":{"role":"assistant","reasoning_content":"Read "}}]}

            data: {"choices":[{"delta":{"reasoning_content":"it first."}}]}

            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function",\
            "function":{"name":"read_file","arguments":"{}"}}]}}]}

            data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

            data: [DONE]

            """
        for slice in [Int.max, 5] {
            let events = decode(
                .openAICompatible, stream, slice: slice, route: "api.deepseek.com", model: "deepseek-flash")
            expect(
                replays(events) == [
                    AIReasoningReplay(
                        route: "api.deepseek.com", model: "deepseek-flash", form: .reasoningContent,
                        text: "Read it first.")
                ],
                "reasoning_content is kept whole, in its own field (\(slice)-byte slices), got \(replays(events))")
            expect(
                events.contains(.reasoning("Read ")), "and the fold still shows it as it streams")
        }
        let plain = decode(
            .openAICompatible,
            """
            data: {"choices":[{"delta":{"reasoning":"Think."}}]}

            data: {"choices":[{"delta":{"content":"Hi."},"finish_reason":"stop"}]}

            data: [DONE]

            """)
        expect(
            replays(plain).map(\.form) == [.reasoning],
            "OpenRouter's and vLLM's plain `reasoning` field is kept as that field")
    }

    /// MiniMax M2 and local Qwen3 lead the answer with `<think>`; it goes back inside the content.
    static func thinkTagsAreKeptAsTags() {
        guard let data = FileManager.default.contents(atPath: "Tests/ai-fixtures/openai-think-tags.txt")
        else { return expect(false, "the think-tags fixture is readable") }
        for slice in [data.count, 3] {
            let events = decode(
                .openAICompatible, String(bytes: data, encoding: .utf8) ?? "", slice: slice, route: "api.minimax.io",
                model: "MiniMax-M2.5")
            expect(
                replays(events) == [
                    AIReasoningReplay(
                        route: "api.minimax.io", model: "MiniMax-M2.5", form: .thinkTags, text: "Plan carefully.")
                ],
                "the tagged reasoning is kept as tags (\(slice)-byte slices), got \(replays(events))")
            expect(events.contains(.text("The answer.")), "while the answer reads without them")
        }
    }

    /// Anthropic's blocks, Claude's own and the gateways', go back whole: text, signature and redaction.
    static func anthropicThinkingBlocksKeepTheirSignatures() {
        let stream = """
            data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}

            data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}

            data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Read "}}

            data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"it."}}

            data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqMB"}}

            data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"Ckal=="}}

            data: {"type":"content_block_stop","index":0}

            data: {"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking","data":"EmwKAhgB"}}

            data: {"type":"content_block_stop","index":1}

            data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"t1","name":"read_file"}}

            data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{}"}}

            data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}

            data: {"type":"message_stop"}

            """
        for slice in [Int.max, 9] {
            let events = decode(.anthropic, stream, slice: slice, route: "api.anthropic.com", model: "claude-opus-5-5")
            expect(
                replays(events) == [
                    AIReasoningReplay(
                        route: "api.anthropic.com", model: "claude-opus-5-5", form: .blocks, text: "Read it.",
                        items: [
                            json(#"{"type":"thinking","thinking":"Read it.","signature":"EqMBCkal=="}"#),
                            json(#"{"type":"redacted_thinking","data":"EmwKAhgB"}"#)
                        ], layout: [.item(0), .item(1), .call("t1")])
                ],
                "thinking and its signature, then the redacted block, in order (\(slice)-byte slices), got "
                    + "\(replays(events))")
            expect(
                events.contains(.toolCallRequested(AIToolCall(id: "t1", name: "read_file", arguments: "{}"))),
                "beside the call they led to")
        }
        let omitted = decode(
            .anthropic,
            """
            data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}

            data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"Es8C"}}

            data: {"type":"message_stop"}

            """, route: "api.anthropic.com", model: "claude-opus-5-5")
        expect(
            replays(omitted).first?.items == [json(#"{"type":"thinking","thinking":"","signature":"Es8C"}"#)],
            "Claude 5's omitted thinking, empty but signed, is kept too: it must still go back")
        let tool = AITool(name: "f", description: "", parameters: .object([:]), origin: "")
        let progress = AIReasoningReplay(
            route: "api.anthropic.com", model: "claude-opus-5-5", form: .blocks, text: "",
            items: [
                json(#"{"type":"thinking","thinking":"","signature":"a"}"#),
                json(#"{"type":"thinking","thinking":"Now B.","signature":"b"}"#)
            ],
            layout: [.item(0), .text, .call("c1"), .item(1), .call("c2")])
        let sent = AIRequestBody.make(
            AIRequest(
                messages: [
                    AIMessage(role: .user, text: "go"),
                    AIMessage(
                        role: .assistant, text: "Both.",
                        toolCalls: [
                            AIToolCall(id: "c1", name: "f", arguments: "{}"), AIToolCall(id: "c2", name: "f", arguments: "{}")
                        ],
                        reasoning: progress)
                ],
                tools: [tool]),
            configuration: AIHTTPConfiguration(
                provider: .anthropic, baseURL: URL(string: "https://api.anthropic.com")!, model: "claude-opus-5-5"))
        let content = ((sent["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]] ?? []).map {
            ($0["type"] as? String ?? "") + ":" + ($0["signature"] as? String ?? $0["id"] as? String ?? "")
        }
        expect(
            content == ["thinking:a", "text:", "tool_use:c1", "thinking:b", "tool_use:c2"],
            "a progress block between parallel calls goes back between them, where it was signed, got \(content)")
    }

    /// Gemini 3 signs its calls; the reply is stamped so no other model is ever sent the signature.
    static func signedCallsStampTheirReply() {
        let events = decode(
            .openAICompatible,
            """
            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"f","arguments":"{}"},\
            "extra_content":{"google":{"thought_signature":"sig=="}}}]}}]}

            data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

            data: [DONE]

            """, route: "generativelanguage.googleapis.com", model: "gemini-3.5-flash")
        expect(
            replays(events) == [
                AIReasoningReplay(
                    route: "generativelanguage.googleapis.com", model: "gemini-3.5-flash", form: nil, text: "")
            ],
            "a signed call stamps its reply with no reasoning of its own, got \(replays(events))")
    }

    // MARK: Fork: request bodies per provider

    /// One conversation per provider: an earlier turn of its own, one of another model, then a tool round.
    private static func replayConversation(
        _ form: AIReasoningReplay.Form?, route: String, model: String, items: [JSONValue] = [],
        signature: String? = nil
    ) -> [AIMessage] {
        let stored = form.flatMap { form in
            AIReasoningReplay(route: route, model: model, form: form, text: "Earlier thought.", items: items).stored
        }
        let theirs = AIReasoningReplay(
            route: route, model: "another-model", form: .reasoningContent, text: "Their thought.", isStored: true)
        return [
            AIMessage(role: .user, text: "What is in notes.txt?"),
            AIMessage(role: .assistant, text: "It lists milk.", reasoning: stored),
            AIMessage(role: .user, text: "Which model wrote that?"),
            AIMessage(role: .assistant, text: "Another one.", reasoning: theirs),
            AIMessage(role: .user, text: "And now?"),
            AIMessage(
                role: .assistant, text: "",
                toolCalls: [
                    AIToolCall(
                        id: "c1", name: "read_file", arguments: #"{"path":"notes.txt"}"#, thoughtSignature: signature)
                ],
                reasoning: AIReasoningReplay(
                    route: route, model: model, form: form, text: form == nil ? "" : "Read it again.", items: items)),
            AIMessage(
                role: .tool, text: "", toolResult: AIToolResult(callID: "c1", content: "milk, eggs", isError: false))
        ]
    }

    /// Each provider's documented rules, pinned by the body they produce for one conversation.
    static func eachProviderIsSentItsOwnReasoningBack() {
        guard
            let data = FileManager.default.contents(atPath: "Tests/ai-fixtures/reasoning-replay-bodies.json"),
            let fixtures = JSONValue(data: data)?.objectValue
        else { return expect(false, "the reasoning-replay fixture is readable") }
        let tool = AITool(
            name: "read_file", description: "Read a file.", parameters: .object(["type": .string("object")]),
            origin: "Files")
        let opaque = [
            json(#"{"type":"reasoning.text","text":"Read it again.","format":"google-gemini-v1","index":0}"#),
            json(#"{"type":"reasoning.encrypted","data":"CiQB+opaque/sig==","id":"c1","format":"google-gemini-v1","index":0}"#)
        ]
        let blocks = [
            json(#"{"type":"thinking","thinking":"Read it again.","signature":"EqMBCkal=="}"#),
            json(#"{"type":"redacted_thinking","data":"EmwKAhgB"}"#)
        ]
        let minimaxDetails = [
            json(
                #"{"type":"reasoning.text","id":"reasoning-text-1","format":"MiniMax-response-v1","index":0,"#
                    + #""text":"Read it again."}"#)
        ]
        typealias Case = (
            name: String, provider: AIProviderKind, base: String, model: String, form: AIReasoningReplay.Form?,
            items: [JSONValue], signature: String?, mode: AIConnection.ReasoningReplay?
        )
        let cases: [Case] = [
            ("deepseek", .openAICompatible, "https://api.deepseek.com", "deepseek-flash", .reasoningContent, [], nil, nil),
            ("deepseek-never", .openAICompatible, "https://api.deepseek.com", "deepseek-flash", .reasoningContent, [],
             nil, .never),
            ("qwen", .openAICompatible, "https://dashscope-intl.aliyuncs.com/compatible-mode/v1", "qwen3.7-plus",
             .reasoningContent, [], nil, nil),
            ("qwen-always", .openAICompatible, "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
             "qwen3.7-plus", .reasoningContent, [], nil, .always),
            ("moonshot", .openAICompatible, "https://api.moonshot.ai/v1", "kimi-k2.6", .reasoningContent, [], nil, nil),
            ("minimax", .openAICompatible, "https://api.minimax.io/v1", "MiniMax-M3", .reasoningContent, [], nil, nil),
            ("minimax-details", .openAICompatible, "https://api.minimax.io/v1", "MiniMax-M2.7", .details,
             minimaxDetails, nil, nil),
            ("minimax-tags", .openAICompatible, "https://api.minimax.io/v1", "MiniMax-M2.5", .thinkTags, [], nil, nil),
            ("zai", .openAICompatible, "https://api.z.ai/api/paas/v4", "glm-4.7", .reasoningContent, [], nil, nil),
            ("zai-always", .openAICompatible, "https://api.z.ai/api/paas/v4", "glm-4.7", .reasoningContent, [], nil,
             .always),
            ("openrouter", .openRouter, "https://openrouter.ai/api/v1", "google/gemini-3.8-flash", .details, opaque,
             nil, nil),
            ("gemini", .gemini, "https://generativelanguage.googleapis.com/v1beta/openai", "gemini-3.5-flash", nil, [],
             "sig==", nil),
            ("openai", .openAI, "https://api.openai.com/v1", "gpt-5.5", .reasoningContent, [], nil, nil),
            ("other", .openAICompatible, "https://llm.example.com/v1", "qwen3-32b", .reasoningContent, [], nil, nil),
            ("other-always", .openAICompatible, "https://llm.example.com/v1", "qwen3-32b", .reasoningContent, [], nil,
             .always),
            ("anthropic", .anthropic, "https://api.anthropic.com", "claude-opus-5-5", .blocks, blocks, nil, nil),
            ("anthropic-gateway", .anthropic, "https://api.minimax.io/anthropic", "MiniMax-M3", .blocks,
             [json(#"{"type":"thinking","thinking":"Read it again.","signature":"a1b2"}"#)], nil, nil)
        ]
        for item in cases {
            let configuration = AIHTTPConfiguration(
                provider: item.provider, baseURL: URL(string: item.base)!, model: item.model,
                reasoningReplay: item.mode)
            let made = AIRequestBody.make(
                AIRequest(
                    instructions: "Be brief.",
                    messages: replayConversation(
                        item.form, route: configuration.route, model: item.model, items: item.items,
                        signature: item.signature),
                    tools: [tool]),
                configuration: configuration)
            let body = (try? JSONSerialization.data(withJSONObject: made)).flatMap(JSONValue.init(data:))
            let got = (try? JSONSerialization.data(withJSONObject: made, options: [.sortedKeys]))
                .flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
            expect(
                body != nil && body == fixtures[item.name], "\(item.name): the body matches its fixture, got \(got)")
        }
        let thinkingOff = AIHTTPConfiguration(
            provider: .openAICompatible, baseURL: URL(string: "https://api.deepseek.com/v1")!,
            model: "deepseek-flash", effort: "none", disablesThinking: true)
        let off = AIRequestBody.make(
            AIRequest(
                messages: replayConversation(.reasoningContent, route: "api.deepseek.com", model: "deepseek-flash"),
                tools: [tool]),
            configuration: thinkingOff)
        expect(
            (off["messages"] as? [[String: Any]])?.allSatisfy { $0["reasoning_content"] == nil } == true,
            "with DeepSeek's thinking off nothing is sent back, not even the empty field")
    }

    /// A call from a reply the output cap cut may hold half its arguments, so the loop is told.
    static func aReplyTheCapCutSaysSo() {
        var openAI = AIStreamDecoder(shape: .openAICompatible)
        let cut = Data(
            """
            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"write_file",\
            "arguments":"{\\"path\\":\\"r.md\\",\\"content\\":\\"# Rep"}}]}}]}

            data: {"choices":[{"delta":{},"finish_reason":"length"}]}

            data: [DONE]

            """.utf8)
        let events = ((try? openAI.feed(cut)) ?? []) + ((try? openAI.finish()) ?? [])
        let limit = events.firstIndex(of: .outputLimit)
        let call = events.firstIndex { if case .toolCallRequested = $0 { true } else { false } }
        expect(
            limit != nil && call != nil && limit! < call!,
            "OpenAI's finish_reason length is said before the half-written call, got \(events)")

        var anthropic = AIStreamDecoder(shape: .anthropic)
        let stopped = Data(
            """
            data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"write_file"}}

            data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"pa"}}

            data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":16384}}

            data: {"type":"message_stop"}

            """.utf8)
        let anthropicEvents = ((try? anthropic.feed(stopped)) ?? []) + ((try? anthropic.finish()) ?? [])
        expect(
            anthropicEvents.contains(.outputLimit)
                && anthropicEvents.contains(.toolCallRequested(AIToolCall(id: "t1", name: "write_file", arguments: #"{"pa"#))),
            "and so is Anthropic's max_tokens stop")
        var whole = AIStreamDecoder(shape: .openAICompatible)
        let finished = Data(
            "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8)
        expect(
            !((try? whole.feed(finished)) ?? []).contains(.outputLimit),
            "while a reply that ended on its own says nothing of the kind")
    }

    /// An agent round asks for room on every shape, under the name each API takes.
    static func anAgentRoundCarriesItsOwnCap() {
        func body(_ provider: AIProviderKind, _ base: String, cap: Int?) -> [String: Any] {
            AIRequestBody.make(
                AIRequest(messages: [AIMessage(role: .user, text: "hi")], outputCap: cap),
                configuration: AIHTTPConfiguration(provider: provider, baseURL: URL(string: base)!, model: "m"))
        }
        expect(
            body(.openAICompatible, "https://api.deepseek.com", cap: 16_384)["max_tokens"] as? Int == 16_384,
            "DeepSeek and other OpenAI-shaped routes take max_tokens")
        let openAI = body(.openAI, "https://api.openai.com/v1", cap: 16_384)
        expect(
            openAI["max_completion_tokens"] as? Int == 16_384 && openAI["max_tokens"] == nil,
            "OpenAI's own API takes max_completion_tokens, which its reasoning models require")
        expect(
            body(.anthropic, "https://api.anthropic.com", cap: 16_384)["max_tokens"] as? Int == 16_384
                && body(.anthropic, "https://api.anthropic.com", cap: nil)["max_tokens"] as? Int
                    == AIRequest.defaultMaxOutputTokens,
            "Anthropic's cap is the round's, else the request's default")
        expect(
            body(.openRouter, "https://openrouter.ai/api/v1", cap: nil)["max_tokens"] == nil
                && body(.openAI, "https://api.openai.com/v1", cap: nil)["max_completion_tokens"] == nil,
            "and a request without one is sent as it always was")
        let turn = AIRequest(messages: [], outputCap: 9)
        expect(
            turn.continuing(with: [], tools: []).outputCap == 9 && turn.capped(at: nil).outputCap == nil,
            "a continued turn keeps its cap, and a capped copy replaces it")
    }

    /// A run retries what may pass on its own and sheds a full window; a key or a quota stands.
    static func failuresSayWhetherTheyMayPass() {
        func kind(_ status: Int, _ body: String, retryAfter: String? = nil) -> AIProviderRecoverableError.Kind? {
            AIProviderFailure.recoverable(
                status: status, body: Data(body.utf8), retryAfter: retryAfter, message: "m")?.kind
        }
        expect(
            kind(503, "") == .transient(retryAfter: nil) && kind(529, #"{"error":{"message":"Overloaded"}}"#)
                == .transient(retryAfter: nil) && kind(408, "") == .transient(retryAfter: nil),
            "a server error, an overloaded API and a timeout may pass")
        expect(
            kind(429, #"{"error":{"message":"Rate limit reached"}}"#, retryAfter: "7")
                == .transient(retryAfter: .seconds(7)),
            "a rate limit may too, after the wait it names")
        expect(
            kind(429, #"{"error":{"code":"insufficient_quota","message":"You exceeded your current quota"}}"#)
                == nil && kind(402, #"{"error":{"message":"Insufficient Balance"}}"#) == nil,
            "a spent quota or balance never passes by waiting")
        expect(
            kind(400, #"{"error":{"message":"This endpoint's maximum context length is 65536 tokens."}}"#)
                == .overflow
                && kind(
                    400,
                    #"{"type":"error","error":{"type":"invalid_request_error","#
                        + #""message":"prompt is too long: 213462 tokens > 200000 maximum"}}"#)
                    == .overflow && kind(413, "") == .overflow,
            "a full window in OpenRouter's, Anthropic's or a proxy's words is an overflow")
        expect(
            kind(401, "") == nil && kind(400, #"{"error":{"message":"Unknown model"}}"#) == nil,
            "and a rejected key or request is just a failure")
        let recoverable = AIProviderFailure.recoverable(
            status: 503, body: Data(), retryAfter: nil, message: "The provider is temporarily unavailable (HTTP 503).")
        expect(
            recoverable?.localizedDescription == "The provider is temporarily unavailable (HTTP 503).",
            "and it reads exactly as the failure it stands for")

        func midStream(_ frames: String) -> (any Error)? {
            var decoder = AIStreamDecoder(shape: .openAICompatible)
            do { _ = try decoder.feed(Data(frames.utf8)) } catch { return error }
            return nil
        }
        expect(
            (midStream(#"data: {"error":{"message":"Provider returned error","code":502}}"# + "\n\n")
                as? AIProviderRecoverableError)?.kind == .transient(retryAfter: nil),
            "OpenRouter's upstream failure before any answer may pass")
        expect(
            (midStream(#"data: {"error":{"message":"Rate limit exceeded","code":"rate_limit_exceeded"}}"# + "\n\n")
                as? AIProviderRecoverableError) != nil,
            "and a string code is read by what the message says")
        expect(
            midStream(#"data: {"error":{"message":"Invalid model","code":400}}"# + "\n\n") as? AIProviderError
                == .responseFailed("Invalid model"),
            "while a refused request stands")
        var anthropic = AIStreamDecoder(shape: .anthropic)
        var thrown: (any Error)?
        do {
            _ = try anthropic.feed(
                Data(#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#.utf8)
                    + Data("\n\n".utf8))
        } catch { thrown = error }
        expect(
            (thrown as? AIProviderRecoverableError)?.kind == .transient(retryAfter: nil),
            "as an overloaded Anthropic stream may pass")
    }

    /// Both providers stream a call's arguments in pieces; a half-parsed call would be uncallable.
    static func toolArgumentsSurviveArrivingInFragments() {
        var openAI = AIStreamDecoder(shape: .openAICompatible)
        let openAIData = Data(
            """
            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1",\
            "function":{"name":"fs__read","arguments":"{\\"pa"}}]}}]}

            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\\":\\"/tmp\\"}"}}]}}]}

            data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

            data: [DONE]

            """.utf8)
        var events = (try? openAI.feed(openAIData)) ?? []
        events += (try? openAI.finish()) ?? []
        expect(
            events.contains(
                .toolCallRequested(
                    AIToolCall(id: "call_1", name: "fs__read", arguments: #"{"path":"/tmp"}"#))),
            "OpenAI fragments reassemble into one whole call before it leaves the decoder")
        expect(events.last == .finished, "and the stream still terminates")

        var anthropic = AIStreamDecoder(shape: .anthropic)
        let anthropicData = Data(
            """
            data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"fs__read"}}

            data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"path"}}

            data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\":\\"/tmp\\"}"}}

            data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}

            """.utf8)
        var anthropicEvents = (try? anthropic.feed(anthropicData)) ?? []
        anthropicEvents += (try? anthropic.finish()) ?? []
        expect(
            anthropicEvents.contains(
                .toolCallRequested(
                    AIToolCall(id: "toolu_1", name: "fs__read", arguments: #"{"path":"/tmp"}"#))),
            "an Anthropic tool_use block reassembles the same way")
        expect(
            !anthropicEvents.contains(.finished),
            "a tool turn ends without message_stop, so the loop decides whether the turn is over")

        var plain = AIStreamDecoder(shape: .openAICompatible)
        let none = (try? plain.feed(Data("data: [DONE]\n\n".utf8))) ?? []
        expect(
            none == [.finished],
            "a turn that called nothing emits no tool event at all")
    }

    /// Gemini 3 400s on the follow-up turn if a call's signature doesn't come back unchanged.
    static func geminiThoughtSignaturesRoundTrip() {
        var decoder = AIStreamDecoder(shape: .openAICompatible)
        let data = Data(
            """
            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1",\
            "function":{"name":"exa__search","arguments":"{}"},\
            "extra_content":{"google":{"thought_signature":"sig=="}}},\
            {"index":1,"id":"c2","function":{"name":"exa__fetch","arguments":"{}"}}]}}]}

            data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

            data: [DONE]

            """.utf8)
        var events = (try? decoder.feed(data)) ?? []
        events += (try? decoder.finish()) ?? []
        let calls = events.compactMap { event -> AIToolCall? in
            if case .toolCallRequested(let call) = event { return call }
            return nil
        }
        expect(
            calls.first?.thoughtSignature == "sig==",
            "the signature Gemini attaches to a call survives decoding")
        expect(
            calls.count == 2 && calls.last?.thoughtSignature == nil,
            "and a parallel call that arrived without one stays without one")

        let body = AIRequestBody.make(
            AIRequest(messages: [
                AIMessage(role: .user, text: "search"),
                AIMessage(role: .assistant, text: "", toolCalls: calls)
            ]),
            configuration: AIHTTPConfiguration(
                provider: .gemini,
                baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!,
                model: "gemini-3.5-flash-lite"))
        let encoded =
            (body["messages"] as? [[String: Any]])?
            .first { $0["tool_calls"] != nil }?["tool_calls"] as? [[String: Any]] ?? []
        let google =
            (encoded.first?["extra_content"] as? [String: Any])?["google"] as? [String: Any]
        expect(
            google?["thought_signature"] as? String == "sig==",
            "and goes back on the assistant turn exactly as it arrived")
        expect(
            encoded.count == 2 && encoded.last?["extra_content"] == nil,
            "while a call with no signature sends no extra_content at all")
    }

    /// Only a route that can actually run one is ever offered a tool.
    static func toolCapabilitiesFollowTheRoute() {
        let connection = AIConnection(provider: .anthropic, models: ["claude"])
        expect(
            connection.capabilities(for: "claude").tools,
            "both HTTP shapes speak tool calling natively")
        expect(
            !AIModelCapabilities.appleIntelligence.tools,
            "the on-device model reaches nothing, so it is offered nothing to reach with")
        expect(
            !AIModelCapabilities.chatGPT.tools,
            "and the hosted ChatGPT route declines tools by design")
        expect(
            AIModelCapabilities.codex.tools && AIModelCapabilities.claudeCommand.tools,
            "the two CLI routes are offered servers, which their own client runs")
        expect(!AIModelCapabilities.none.tools, "an unconfigured route offers nothing either")
        expect(
            AIModelSelection.codex(model: "gpt", effort: nil).runsItsOwnTools
                && AIModelSelection.claude(model: "sonnet", effort: nil).runsItsOwnTools,
            "and they are the routes Tinycast never wraps in its own loop")
        expect(
            !AIModelSelection.grok(model: "grok", effort: nil).runsItsOwnTools
                && !AIModelSelection.cursor(model: "auto", effort: nil).runsItsOwnTools
                && !AIModelSelection.openCode(model: "m", effort: nil).runsItsOwnTools
                && !AIModelSelection.appleIntelligence.runsItsOwnTools
                && !AIModelSelection.api(connection: UUID(), model: "m", effort: nil)
                    .runsItsOwnTools,
            "every other route either runs Tinycast's loop or has nothing to call")

        expect(
            AIRequest(messages: []).tools.isEmpty,
            "a request carries no tools unless a caller put them there")
    }

    /// Every provider 400s on a call without its result, or a result without its call.
    static func toolCatalogsAndTurnsEncodePerProvider() {
        let tool = AITool(
            name: "fs__read", description: "Reads a file.",
            parameters: .object(["type": .string("object")]), origin: "Files", title: "read")
        let call = AIToolCall(id: "c1", name: "fs__read", arguments: #"{"path":"/tmp"}"#)
        let turn = AIRequest(
            messages: [
                AIMessage(role: .user, text: "read it"),
                AIMessage(role: .assistant, text: "", toolCalls: [call]),
                AIMessage(
                    role: .tool, text: "",
                    toolResult: AIToolResult(callID: "c1", content: "hi", isError: false)),
                AIMessage(
                    role: .tool, text: "",
                    toolResult: AIToolResult(callID: "c2", content: "no", isError: true))
            ],
            tools: [tool])

        let openAI = AIRequestBody.make(
            turn,
            configuration: AIHTTPConfiguration(
                provider: .openAI, baseURL: URL(string: "https://api.openai.com/v1")!,
                model: "gpt-5"))
        let catalog = (openAI["tools"] as? [[String: Any]])?.first
        expect(
            catalog?["type"] as? String == "function",
            "OpenAI takes a tool wrapped as a function")
        expect(
            (catalog?["function"] as? [String: Any])?["parameters"] is [String: Any],
            "and the server's own schema is handed through as the parameters, unrewritten")
        let openAIMessages = openAI["messages"] as? [[String: Any]] ?? []
        let assistant = openAIMessages.first { $0["tool_calls"] != nil }
        expect(
            ((assistant?["tool_calls"] as? [[String: Any]])?.first?["id"] as? String) == "c1",
            "the assistant turn keeps the id its result has to quote")
        let results = openAIMessages.filter { $0["role"] as? String == "tool" }
        expect(results.count == 2, "each result is its own tool turn")
        expect(
            results.first?["tool_call_id"] as? String == "c1",
            "addressed by the call it answers")

        let anthropic = AIRequestBody.make(
            turn,
            configuration: AIHTTPConfiguration(
                provider: .anthropic, baseURL: URL(string: "https://api.anthropic.com")!,
                model: "claude"))
        let anthropicTool = (anthropic["tools"] as? [[String: Any]])?.first
        expect(
            anthropicTool?["input_schema"] != nil && anthropicTool?["type"] == nil,
            "Anthropic names the same schema input_schema and takes no wrapper")
        let anthropicMessages = anthropic["messages"] as? [[String: Any]] ?? []
        let use =
            (anthropicMessages.first { $0["role"] as? String == "assistant" }?["content"]
            as? [[String: Any]])?.first
        expect(use?["type"] as? String == "tool_use", "a call is a content block, not a field")
        expect(
            (use?["input"] as? [String: Any])?["path"] as? String == "/tmp",
            "and its arguments are parsed back into the object Anthropic expects")
        let resultBlocks =
            anthropicMessages.last?["content"] as? [[String: Any]] ?? []
        expect(
            anthropicMessages.last?["role"] as? String == "user",
            "Anthropic takes results as a user turn")
        expect(
            resultBlocks.count == 2,
            "and a run of them arrives as one turn, because two would be rejected")
        expect(
            resultBlocks.last?["is_error"] as? Bool == true,
            "a tool's own failure stays marked so the model can work around it")

        let plain = AIRequestBody.make(
            AIRequest(messages: [AIMessage(role: .user, text: "hi")]),
            configuration: AIHTTPConfiguration(
                provider: .openAI, baseURL: URL(string: "https://api.openai.com/v1")!,
                model: "gpt-5"))
        expect(plain["tools"] == nil, "a turn with no tools sends no tools key at all")

        let router = AIRequestBody.make(
            AIRequest(messages: [AIMessage(role: .user, text: "hi")]),
            configuration: AIHTTPConfiguration(
                provider: .openRouter, baseURL: URL(string: "https://openrouter.ai/api/v1")!,
                model: "openai/gpt-5", effort: "low"))
        expect(
            (router["reasoning"] as? [String: String])?["effort"] == "low",
            "OpenRouter receives the reasoning effort its catalog offered")
    }

    /// A body that named the default would 400 on every endpoint without a thinking mode.
    static func aGatewayOffersNoneAsItsReasoningEffort() {
        let gateway = AIConnection(
            provider: .openAI, baseURL: "https://gateway.example/v1", models: ["m"])
        expect(
            gateway.reasoningOptions(for: "m")?.efforts == ["default", "none"],
            "a preset pointed away from its own API offers the one effort a gateway can honour")
        expect(
            gateway.reasoningOptions(for: "m")?.resolvedEffort(nil) == "default",
            "and reasoning stays on until the reader picks None")
        expect(
            AIConnection(provider: .openAI, models: ["m"]).reasoningOptions(for: "m") == nil,
            "a preset on its own API offers none, because a vendor rejects what it does not define")
        expect(
            AIConnection(provider: .anthropic, baseURL: "https://gateway.example", models: ["m"])
                .reasoningOptions(for: "m") == nil,
            "the Anthropic shape is out of scope whatever it points at")

        let catalogued = AIConnection(
            id: UUID(), provider: .openRouter, baseURL: "https://gateway.example", models: ["m"],
            reasoningOptions: ["m": .init(efforts: ["high", "low"], defaultEffort: "high")])
        expect(
            catalogued.reasoningOptions(for: "m")?.efforts == ["high", "low"],
            "a published catalog always wins over the synthesized switch")

        let turn = AIRequest(messages: [AIMessage(role: .user, text: "hi")])
        let url = URL(string: "https://gateway.example/v1")!
        let on = AIRequestBody.make(
            turn,
            configuration: AIHTTPConfiguration(provider: .openAI, baseURL: url, model: "m"))
        expect(on["thinking"] == nil, "reasoning left alone sends no key at all")

        let off = AIRequestBody.make(
            turn,
            configuration: AIHTTPConfiguration(
                provider: .openAI, baseURL: url, model: "m", effort: "none",
                disablesThinking: true))
        expect(
            (off["thinking"] as? [String: String])?["type"] == "disabled",
            "None asks the endpoint to answer directly")
        expect(off["reasoning_effort"] == nil, "None sends no effort field beside it")

        var declared = AIConnection(
            provider: .openAI, baseURL: "https://gateway.example/v1", models: ["m"])
        declared.declareLevels(["high", "low", "bogus"], for: "m")
        expect(
            declared.reasoningOptions(for: "m")?.efforts == ["default", "low", "high", "none"],
            "declared levels sit in ladder order between Default and None, and strangers drop")
        expect(
            declared.reasoningOptions(for: "m")?.resolvedEffort(nil) == "default",
            "a declaration leaves reasoning alone until the reader picks a level")
        expect(declared.declaredLevels(for: "m") == ["low", "high"], "the declaration reads back")
        declared.declareLevels([], for: "m")
        expect(
            declared.reasoningOptions(for: "m")?.efforts == ["default", "none"],
            "clearing it returns to the Default/None pair")

        let level = AIRequestBody.make(
            turn,
            configuration: AIHTTPConfiguration(
                provider: .openAI, baseURL: url, model: "m", effort: "low"))
        expect(
            level["reasoning_effort"] as? String == "low",
            "a declared level goes out as OpenAI's own reasoning_effort")
        expect(level["reasoning"] == nil, "and not as OpenRouter's reasoning object")
        let unset = AIRequestBody.make(
            turn,
            configuration: AIHTTPConfiguration(
                provider: .openAI, baseURL: url, model: "m", effort: "default"))
        expect(unset["reasoning_effort"] == nil, "Default still sends no field")
    }

    static func declaredLevelsNeverReachAVendorOrOutliveTheirDeclaration() {
        var gateway = AIConnection(
            provider: .openAI, baseURL: "https://gateway.example/v1", models: ["m"])
        gateway.declareLevels(["low", "high"], for: "m")
        expect(gateway.offeredEffort("high", for: "m") == "high", "a declared level is sent")
        expect(gateway.offeredEffort(nil, for: "m") == nil, "no saved effort sends none")

        gateway.declareLevels(["low"], for: "m")
        expect(
            gateway.offeredEffort("high", for: "m") == nil,
            "a chat still holding an unticked level stops sending it")

        var vendor = gateway
        vendor.baseURL = AIProviderKind.openAI.defaultBaseURL
        expect(
            vendor.reasoningOptions(for: "m") == nil,
            "levels declared for a gateway are not offered once the URL is the vendor's own")
        expect(vendor.offeredEffort("low", for: "m") == nil, "nor sent to the vendor")

        let openRouter = AIConnection(
            id: UUID(), provider: .openRouter, models: ["m"],
            reasoningOptions: ["m": .init(efforts: ["high", "low"], defaultEffort: "high")])
        expect(
            openRouter.offeredEffort("high", for: "m") == "high",
            "OpenRouter's own catalog still reaches its default URL")
        expect(
            openRouter.offeredEffort("xhigh", for: "m") == nil,
            "a level its catalog dropped is not sent")
        expect(
            AIConnection(provider: .openAI, models: ["m"]).offeredEffort("high", for: "m") == nil,
            "an old OpenRouter effort left on a vendor connection is not sent")

        var retargeted = gateway
        retargeted.dropDeclaredLevels()
        expect(
            retargeted.reasoningOptions == nil,
            "levels declared for one gateway are dropped when the URL moves")
        var movedOpenRouter = openRouter
        movedOpenRouter.dropDeclaredLevels()
        expect(
            movedOpenRouter.reasoningOptions == openRouter.reasoningOptions,
            "OpenRouter's catalog is no declaration, so a moved URL keeps it")

        expect(gateway.takesDeclaredLevels, "a gateway takes declared levels")
        expect(!vendor.takesDeclaredLevels, "a vendor URL does not")
        expect(
            !AIConnection(provider: .openRouter, baseURL: "https://proxy.example/v1")
                .takesDeclaredLevels,
            "OpenRouter at any URL does not, because its catalog names the levels")
    }

    static func providerPresetsResolveEndpoints() {
        let expected: [(AIProviderKind, String)] = [
            (.openAI, "https://api.openai.com/v1/chat/completions"),
            (.anthropic, "https://api.anthropic.com/v1/messages"),
            (.gemini, "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"),
            (.openRouter, "https://openrouter.ai/api/v1/chat/completions"),
            (.openAICompatible, "https://api.openai.com/v1/chat/completions")
        ]
        for (provider, endpoint) in expected {
            let configuration = AIHTTPConfiguration(
                provider: provider,
                baseURL: URL(string: provider.defaultBaseURL)!,
                model: "model")
            expect(
                configuration.endpointURL.absoluteString == endpoint,
                "\(provider.title) resolves its documented streaming endpoint")
        }
        let explicit = AIHTTPConfiguration(
            provider: .openAICompatible,
            baseURL: URL(string: "https://example.com/chat/completions")!,
            model: "model")
        expect(
            explicit.endpointURL.absoluteString == "https://example.com/chat/completions",
            "an explicit completion endpoint is not appended twice")
    }

    static func modelCatalogBuildsProviderRequests() {
        let expected: [(AIProviderKind, String)] = [
            (.openAI, "https://api.openai.com/v1/models"),
            (.anthropic, "https://api.anthropic.com/v1/models?limit=1000"),
            (.gemini, "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000"),
            (.openRouter, "https://openrouter.ai/api/v1/models/user"),
            (.openAICompatible, "https://api.openai.com/v1/models")
        ]
        for (provider, endpoint) in expected {
            let query = try? AIModelDiscovery.query(
                provider: provider, baseURL: URL(string: provider.defaultBaseURL)!,
                apiKey: "secret", appTitle: "Tinycast")
            expect(
                query?.request.url?.absoluteString == endpoint,
                "\(provider.title) resolves its model catalog endpoint")
        }

        let anthropic = try? AIModelDiscovery.query(
            provider: .anthropic, baseURL: URL(string: "https://api.anthropic.com")!,
            apiKey: "secret", appTitle: "Tinycast"
        ).request
        expect(
            anthropic?.value(forHTTPHeaderField: "x-api-key") == "secret",
            "Anthropic model discovery uses x-api-key authentication")
        let gemini = try? AIModelDiscovery.query(
            provider: .gemini, baseURL: URL(string: AIProviderKind.gemini.defaultBaseURL)!,
            apiKey: "secret", appTitle: "Tinycast"
        ).request
        expect(
            gemini?.value(forHTTPHeaderField: "x-goog-api-key") == "secret",
            "Gemini model discovery uses native API-key authentication")
        let openAI = try? AIModelDiscovery.query(
            provider: .openAI, baseURL: URL(string: AIProviderKind.openAI.defaultBaseURL)!,
            apiKey: "secret", appTitle: "Tinycast"
        ).request
        expect(
            openAI?.value(forHTTPHeaderField: "Authorization") == "Bearer secret",
            "OpenAI-compatible discovery uses bearer authentication")
        let local = try? AIModelDiscovery.query(
            provider: .openAICompatible, baseURL: URL(string: "http://localhost:11434/")!,
            apiKey: "", appTitle: "Tinycast"
        ).request
        expect(
            local?.url?.absoluteString == "http://localhost:11434/models",
            "a root endpoint appends one model path separator")
        let headerOnly = try? AIModelDiscovery.query(
            provider: .anthropic, baseURL: URL(string: "https://gateway.example.com")!,
            apiKey: "", appTitle: "Tinycast",
            headers: ["anthropic-version": "2024-01-01", "X-Tenant": "acme"]
        ).request
        expect(
            headerOnly?.value(forHTTPHeaderField: "x-api-key") == nil,
            "an empty key sends no credential header")
        expect(
            headerOnly?.value(forHTTPHeaderField: "Anthropic-Version") == "2024-01-01"
                && headerOnly?.value(forHTTPHeaderField: "x-tenant") == "acme",
            "custom headers are sent and replace a default of the same name in any case")
    }

    static func requestHeadersAreValidated() {
        typealias Headers = AIRequestHeaders
        expect(
            (try? Headers.validated([
                (" X-Tenant ", " acme\n"), ("", " "), ("Authorization", "Bearer\ttoken")
            ])) == ["X-Tenant": "acme", "Authorization": "Bearer\ttoken"],
            "names and values are trimmed, a blank row is dropped and a tab is kept")
        expect(
            (try? Headers.validated([("", "value")])) == nil
                && (try? Headers.validated([("X Tenant", "acme")])) == nil,
            "a missing name or one outside the HTTP token set is refused")
        expect(
            (try? Headers.validated([("X-Tenant", "a"), ("x-tenant", "b")])) == nil,
            "a name repeated in another case is refused")
        expect(
            (try? Headers.validated([("X-Tenant", "a\r\nX-Injected: b")])) == nil,
            "a value cannot carry a line break into another header")
    }

    static func modelCatalogDecodesProviderResponses() {
        let openAI = Data(
            """
            {"data":[
                {"id":"model-a"},
                {"id":"model-b","name":"Model B",
                 "architecture":{"input_modalities":["text","image"]},
                 "reasoning":{"supported_efforts":["high","medium","low"],
                              "default_effort":"medium"}},
                {"id":"model-a"}
            ]}
            """.utf8)
        let openAIModels = try? AIModelDiscovery.decode(openAI, shape: .openAI)
        expect(
            openAIModels == [
                .init(id: "model-a", name: "model-a"),
                .init(
                    id: "model-b", name: "Model B", inputModalities: ["text", "image"],
                    reasoningOptions: .init(
                        efforts: ["high", "medium", "low"], defaultEffort: "medium"))
            ],
            "OpenAI-compatible model lists are named and deduplicated")
        expect(
            openAIModels?.map(\.acceptsImages) == [nil, true],
            "only a catalog that lists modalities says whether a model takes images")
        expect(
            openAIModels?.last?.reasoningOptions?.resolvedEffort(nil) == "medium",
            "OpenRouter reasoning metadata keeps the model's advertised default")

        let gateway = Data(
            """
            {"data":[
                {"id":"model-c","name":"Model C","reasoning":true,
                 "architecture":{"input_modalities":["text","image"]}},
                {"id":"model-d","reasoning":"high"},
                {"id":"model-e","reasoning":{"supported_efforts":["low"],"default_effort":"low"}}
            ]}
            """.utf8)
        let gatewayModels = try? AIModelDiscovery.decode(gateway, shape: .openAI)
        expect(
            gatewayModels == [
                .init(id: "model-c", name: "Model C", inputModalities: ["text", "image"]),
                .init(id: "model-d", name: "model-d"),
                .init(
                    id: "model-e", name: "model-e",
                    reasoningOptions: .init(efforts: ["low"], defaultEffort: "low"))
            ],
            "a reasoning field that is not an object is ignored, and the catalog still loads")

        let router = AIConnection(
            provider: .openRouter, models: ["model-a", "model-b"], visionModels: ["model-b"])
        expect(
            !router.capabilities(for: "model-a").images
                && router.capabilities(for: "model-b").images
                && router.capabilities(for: "model-a").webSearch,
            "OpenRouter gates images by the catalog and searches for every model")
        let direct = AIConnection(provider: .openAI, models: ["model-a"])
        expect(
            direct.capabilities(for: "model-a").images
                && !direct.capabilities(for: "model-a").webSearch,
            "a vendor API takes images and has no search switch")

        let gemini = Data(
            """
            {"models":[
                {"name":"models/gemini-chat","displayName":"Gemini Chat",\
                 "supportedGenerationMethods":["generateContent"]},
                {"name":"models/gemini-embed","displayName":"Gemini Embed",\
                 "supportedGenerationMethods":["embedContent"]}
            ]}
            """.utf8)
        let geminiModels = try? AIModelDiscovery.decode(gemini, shape: .gemini)
        expect(
            geminiModels == [.init(id: "gemini-chat", name: "Gemini Chat")],
            "Gemini discovery keeps generation models and strips the resource prefix")
    }

    static func modelCatalogSearchesWithoutRenderingEverything() {
        let models = [
            AIModelDiscovery.Model(id: "openai/gpt-small", name: "GPT Small"),
            AIModelDiscovery.Model(id: "anthropic/claude", name: "Claude"),
            AIModelDiscovery.Model(id: "openai/gpt-large", name: "GPT Large"),
            AIModelDiscovery.Model(id: "google/gemini", name: "Gemini")
        ]
        expect(
            AIModelDiscovery.search(models, query: "").isEmpty,
            "an empty search never renders the complete provider catalog")
        expect(
            AIModelDiscovery.search(models, query: "openai").map(\.id)
                == ["openai/gpt-small", "openai/gpt-large"],
            "a provider name finds its models in provider order")
        expect(
            AIModelDiscovery.search(models, query: "GPT Large").first?.id
                == "openai/gpt-large",
            "an exact display-name match ranks first")
        expect(
            AIModelDiscovery.search(
                models, query: "gpt", excluding: ["openai/gpt-small"], limit: 1
            ).map(\.id) == ["openai/gpt-large"],
            "search excludes selected models and caps visible results")
    }

    static func exactMatchNamesOnlyAWholeModel() {
        let models = [
            AIModelDiscovery.Model(id: "gpt-5.4-mini", name: "GPT-5.4 Mini"),
            AIModelDiscovery.Model(id: "claude-sonnet-4-20250514", name: "Claude Sonnet 4")
        ]
        expect(
            AIModelDiscovery.exactMatch(models, query: " GPT-5.4-MINI ")?.id == "gpt-5.4-mini",
            "an exact ID matches regardless of case and surrounding spaces")
        expect(
            AIModelDiscovery.exactMatch(models, query: "claude sonnet 4")?.id
                == "claude-sonnet-4-20250514",
            "a display name resolves to its model ID")
        expect(
            AIModelDiscovery.exactMatch(models, query: "gpt-5") == nil,
            "a short ID that a listed ID contains is not an exact match")
        expect(
            AIModelDiscovery.exactMatch(models, query: "  ") == nil,
            "a blank query matches nothing")
        let aliased = [
            AIModelDiscovery.Model(id: "gateway-default", name: "gpt-5"),
            AIModelDiscovery.Model(id: "gpt-5", name: "GPT-5")
        ]
        expect(
            AIModelDiscovery.exactMatch(aliased, query: "gpt-5")?.id == "gpt-5",
            "an exact ID wins over an earlier model whose display name matches")
    }

    static func endpointPolicyRejectsUnsafeRemoteURLs() {
        expect(
            (try? AIEndpointPolicy.validate("https://example.com/v1")) != nil,
            "remote HTTPS endpoints are accepted")
        expect(
            (try? AIEndpointPolicy.validate("http://localhost:11434/v1")) != nil,
            "local HTTP endpoints are accepted")
        expect(
            (try? AIEndpointPolicy.validate("http://127.0.0.1:1234/v1")) != nil,
            "IPv4 loopback endpoints are accepted")
        expect(
            (try? AIEndpointPolicy.validate("http://example.com/v1")) == nil,
            "remote plaintext endpoints are rejected")
        expect(
            (try? AIEndpointPolicy.validate("not a url")) == nil,
            "malformed endpoints are rejected")
        expect(
            (try? AIEndpointPolicy.validate("ftp://localhost/v1")) == nil,
            "a loopback host does not excuse a scheme the transport cannot speak")
        expect(
            (try? AIEndpointPolicy.validate("file:///etc/hosts")) == nil,
            "file URLs are not a provider")
    }

    static func storedKeysDoNotFollowARetargetedConnection() {
        var saved = AIConnection()
        saved.provider = .openAI
        saved.baseURL = "https://api.openai.com/v1"
        expect(
            AIEndpointPolicy.sameDestination(saved, saved),
            "an untouched connection still points where its key was issued")

        var switchedProvider = saved
        switchedProvider.provider = .anthropic
        expect(
            !AIEndpointPolicy.sameDestination(switchedProvider, saved),
            "a new provider is a new destination, so the OpenAI key must not go to Anthropic")

        var switchedURL = saved
        switchedURL.baseURL = "https://gateway.example.com/v1"
        expect(
            !AIEndpointPolicy.sameDestination(switchedURL, saved),
            "a retyped base URL is a new destination, whatever the provider preset still says")

        var renamed = saved
        renamed.name = "Work key"
        renamed.models = ["gpt-5.4-mini"]
        expect(
            AIEndpointPolicy.sameDestination(renamed, saved),
            "editing a label or the model list is not a retarget and keeps the saved key")
    }

    static func savingAConnectionDecidesItsKey() {
        var remote = AIConnection()
        remote.provider = .openAI
        remote.baseURL = "https://api.openai.com/v1"
        var local = remote
        local.baseURL = "http://localhost:11434/v1"
        var moved = remote
        moved.baseURL = "https://gateway.example.com/v1"
        typealias Policy = AIConnectionKeyPolicy

        expect(
            Policy.resolve(enteredKey: "  sk-new \n", connection: remote, saved: nil, hasStoredKey: false, hasHeaders: false)
                == .store("sk-new"),
            "a typed key is stored trimmed")
        expect(
            Policy.resolve(enteredKey: "sk-new", connection: moved, saved: remote, hasStoredKey: true, hasHeaders: false)
                == .store("sk-new"),
            "a retarget that brings its own key replaces the old one")
        expect(
            Policy.resolve(enteredKey: " ", connection: moved, saved: remote, hasStoredKey: true, hasHeaders: false)
                == .reject("Enter an API key for this endpoint — the saved key stays with the old one."),
            "a remote retarget without a key is refused, so the old key never reaches the new host")
        expect(
            Policy.resolve(enteredKey: "", connection: local, saved: remote, hasStoredKey: true, hasHeaders: false)
                == .removeStored,
            "a retarget to loopback drops the key issued for the remote endpoint")
        expect(
            Policy.resolve(enteredKey: "", connection: remote, saved: nil, hasStoredKey: false, hasHeaders: false)
                == .reject("Enter an API key for this remote provider."),
            "a new remote connection needs a key")
        expect(
            Policy.resolve(enteredKey: "", connection: local, saved: nil, hasStoredKey: false, hasHeaders: false) == .keep,
            "a loopback endpoint saves without a key")
        expect(
            Policy.resolve(enteredKey: "", connection: remote, saved: remote, hasStoredKey: true, hasHeaders: false) == .keep,
            "an unchanged endpoint keeps its saved key")
        expect(
            Policy.resolve(enteredKey: "", connection: moved, saved: remote, hasStoredKey: false, hasHeaders: false)
                == .reject("Enter an API key for this remote provider."),
            "with no saved key there is nothing to retarget, only a missing key")
        expect(
            Policy.resolve(
                enteredKey: "", connection: remote, saved: nil, hasStoredKey: false, hasHeaders: true)
                == .keep,
            "request headers can authenticate a remote endpoint without a key")
        expect(
            Policy.resolve(
                enteredKey: "", connection: moved, saved: remote, hasStoredKey: true, hasHeaders: true)
                == .removeStored,
            "a retarget authenticated by headers drops the old key rather than carry it over")
    }

    static func sseFramesSurviveSplits() {
        var parser = SSEParser()
        expect(parser.feed(Data("data: hel".utf8)).isEmpty, "a partial SSE frame waits")
        expect(
            parser.feed(Data("lo\n\ndata: world\r\n\r\n".utf8)) == ["hello", "world"],
            "split LF and CRLF frames are reassembled")
        expect(
            parser.feed(Data(": keepalive\n\ndata: final".utf8)).isEmpty,
            "comments are ignored and a final unterminated frame waits")
        expect(parser.finish() == ["final"], "finish flushes the final frame")
    }

    static func openAIAndAnthropicStreamsDecode() {
        var openAI = AIStreamDecoder(shape: .openAICompatible)
        let openAIData = Data(
            """
            data: {"choices":[{"delta":{"reasoning":"working"}}]}

            data: {"choices":[{"delta":{"content":"Hello"}}]}

            data: {"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":2}}

            data: [DONE]

            """.utf8)
        var events = (try? openAI.feed(openAIData)) ?? []
        events += (try? openAI.finish()) ?? []
        expect(events.contains(.thinking), "reasoning is surfaced as state, not answer text")
        expect(events.contains(.reasoning("working")), "and its text reaches the reasoning fold")
        expect(events.contains(.text("Hello")), "OpenAI-compatible text is decoded")
        expect(
            events.contains(.usage(AIUsage(inputTokens: 3, outputTokens: 2))),
            "OpenAI-compatible usage is decoded")
        expect(events.last == .finished, "the OpenAI done marker terminates the stream")

        var anthropic = AIStreamDecoder(shape: .anthropic)
        let anthropicData = Data(
            """
            data: {"type":"message_start","message":{"usage":{"input_tokens":4}}}

            data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"Hmm"}}

            data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}

            data: {"type":"message_delta","usage":{"output_tokens":1}}

            data: {"type":"message_stop"}

            """.utf8)
        var anthropicEvents = (try? anthropic.feed(anthropicData)) ?? []
        anthropicEvents += (try? anthropic.finish()) ?? []
        expect(anthropicEvents.contains(.text("Hi")), "Anthropic text is decoded")
        expect(
            anthropicEvents.contains(.reasoning("Hmm")) && !anthropicEvents.contains(.text("Hmm")),
            "Anthropic thinking is reasoning, never answer text")
        expect(
            anthropicEvents.contains(.usage(AIUsage(inputTokens: 4, outputTokens: 1))),
            "Anthropic usage accumulates across events")
        expect(anthropicEvents.last == .finished, "Anthropic message_stop terminates the stream")
    }

    /// Real OpenRouter captures, with the reasoning ones proving thought never leaks into text.
    static func capturedStreamsDecodeHoweverTheyArrive() {
        let captures: [(file: String, text: String?, reasons: Bool)] = [
            ("openrouter-plain", "1, 2, 3.", false),
            ("openrouter-gemma", nil, false),
            ("openrouter-nemotron-reasoning", nil, true),
            ("openrouter-cohere-reasoning", nil, true)
        ]
        for capture in captures {
            guard let data = FileManager.default.contents(atPath: "Tests/ai-fixtures/\(capture.file).txt")
            else {
                expect(false, "\(capture.file) fixture is readable")
                continue
            }
            let whole = decodeAll(data, slice: data.count)
            let sliced = decodeAll(data, slice: 7)
            expect(whole == sliced, "\(capture.file) decodes the same in 7-byte slices")
            let text = whole.compactMap { event -> String? in
                if case .text(let text) = event { return text }
                return nil
            }.joined()
            if let expected = capture.text {
                expect(text == expected, "\(capture.file) yields exactly its answer text")
            } else {
                expect(!text.isEmpty, "\(capture.file) yields answer text")
            }
            expect(
                whole.contains(.thinking) == capture.reasons,
                "\(capture.file) surfaces thinking only when the model reasoned")
            expect(whole.last == .finished, "\(capture.file) ends on the done marker")
            expect(
                whole.contains {
                    if case .usage(let usage) = $0 { return usage.totalTokens != nil } else { return false }
                },
                "\(capture.file) reports final usage")
        }
    }

    static func thinkTagStreamsDecodeHoweverTheyArrive() {
        guard let data = FileManager.default.contents(atPath: "Tests/ai-fixtures/openai-think-tags.txt")
        else {
            expect(false, "think tags: fixture is readable")
            return
        }
        let whole = decodeAll(data, slice: data.count)
        expect(whole == decodeAll(data, slice: 7), "think tags: fixture survives 7-byte slices")
        expect(reasoningText(whole) == "Plan carefully.", "think tags: fixture reasoning is exact")
        expect(answerText(whole) == "The answer.", "think tags: fixture answer is exact")
        expect(whole.contains(.thinking), "think tags: fixture surfaces thinking")
        expect(
            whole.suffix(2) == [.usage(AIUsage(inputTokens: 5, outputTokens: 9)), .finished],
            "think tags: fixture keeps usage before completion")

        let content = Array("<think>reason</think>\n\nanswer")
        for first in 0...content.count {
            for second in first...content.count {
                let fragments = [
                    String(content[..<first]), String(content[first..<second]),
                    String(content[second...])
                ]
                let events = decodeContent(fragments)
                expect(
                    reasoningText(events) == "reason" && answerText(events) == "answer",
                    "think tags: content splits \(first),\(second) preserve reasoning and answer")
            }
        }
        let characters = decodeContent(content.map(String.init))
        expect(
            reasoningText(characters) == "reason" && answerText(characters) == "answer",
            "think tags: one character per delta preserves reasoning and answer")
        let spaced = decodeContent([" \n", "<think> ", "\n", "reason \n</thi", "nk>\n", "\t", "answer", " \n"]
        )
        expect(
            reasoningText(spaced) == " \nreason \n" && answerText(spaced) == "answer \n",
            "think tags: only leading tag space and the answer separator are removed")
        expect(
            decodeContent(["<think>r</think>answer"])
                == [.thinking, .reasoning("r"), .text("answer"), .finished],
            "think tags: a single delta emits reasoning before answer text")
        for literal in [
            "<div>x</div>", "<thinking>…", "\n\nHello", "Hello <think>x</think> world",
            "Hello<think>x</think> world", "</think>answer"
        ] {
            let events = decodeContent(literal.map(String.init))
            expect(
                answerText(events) == literal && !events.contains(.thinking),
                "think tags: literal content stays verbatim: \(literal.debugDescription)")
        }
        for content in ["<think></think>", "<think> \n\t</think>"] {
            expect(
                decodeContent(content.map(String.init)) == [.finished],
                "think tags: empty or whitespace-only reasoning emits nothing")
        }
        let secondBlock = decodeContent(["<think>r</think>", "answer <think>literal</think> world"])
        expect(
            answerText(secondBlock) == "answer <think>literal</think> world",
            "think tags: recognition never resumes after the first block")
        for done in [true, false] {
            let unclosed = decodeContent(["<think>reason</thi"], done: done)
            expect(
                reasoningText(unclosed) == "reason</thi" && answerText(unclosed).isEmpty,
                "think tags: unclosed reasoning flushes at \(done ? "DONE" : "EOF")")
            expect(
                answerText(decodeContent(["<thi"], done: done)) == "<thi",
                "think tags: undecided content flushes at \(done ? "DONE" : "EOF")")
        }
        var decoder = AIStreamDecoder(shape: .openAICompatible)
        _ = try? decoder.feed(contentFrame("<thi"))
        expect((try? decoder.finish()) == [.text("<thi")], "think tags: EOF flushes the held prefix")
        expect((try? decoder.finish()) == [], "think tags: EOF never flushes twice")
        var terminated = AIStreamDecoder(shape: .openAICompatible)
        _ = try? terminated.feed(contentFrame("<think>r</thi"))
        expect(
            (try? terminated.feed(Data("data: [DONE]\n\n".utf8)))?.filter({
                if case .reasoningReplay = $0 { false } else { true }
            }) == [.thinking, .reasoning("</thi"), .finished],
            "think tags: DONE flushes reasoning before completion")
        expect((try? terminated.finish()) == [], "think tags: EOF after DONE never flushes twice")
        let tools = Data(
            """
            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"read","arguments":"{}"}}]}}]}

            data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

            data: {"choices":[],"usage":{"prompt_tokens":2,"completion_tokens":3}}

            data: [DONE]

            """.utf8)
        let toolEvents = decodeAll(contentFrame("<think>r</think>") + tools, slice: 7)
        expect(
            toolEvents == [
                .thinking, .reasoning("r"),
                .toolCallRequested(AIToolCall(id: "c1", name: "read", arguments: "{}")),
                .usage(AIUsage(inputTokens: 2, outputTokens: 3)), .finished
            ],
            "think tags: reasoning precedes tools without changing tool, usage or completion order")
        let native = Data(
            """
            data: {"choices":[{"delta":{"reasoning_content":"native"}}]}

            data: {"choices":[{"delta":{"content":"answer"}}]}

            data: [DONE]

            """.utf8)
        expect(
            decodeAll(native, slice: 7) == [.thinking, .reasoning("native"), .text("answer"), .finished],
            "think tags: reasoning_content retains its original event sequence")
    }

    private static func contentFrame(_ content: String) -> Data {
        guard let encoded = try? JSONEncoder().encode(content),
            let quoted = String(bytes: encoded, encoding: .utf8)
        else {
            preconditionFailure("A content string must encode as JSON")
        }
        return Data("data: {\"choices\":[{\"delta\":{\"content\":\(quoted)}}]}\n\n".utf8)
    }

    private static func decodeContent(_ fragments: [String], done: Bool = true) -> [AIStreamEvent] {
        var data = fragments.reduce(into: Data()) { $0 += contentFrame($1) }
        if done { data += Data("data: [DONE]\n\n".utf8) }
        return decodeAll(data, slice: max(1, data.count))
    }

    private static func reasoningText(_ events: [AIStreamEvent]) -> String {
        events.compactMap { event -> String? in
            if case .reasoning(let text) = event { return text }
            return nil
        }.joined()
    }

    private static func answerText(_ events: [AIStreamEvent]) -> String {
        events.compactMap { event -> String? in
            if case .text(let text) = event { return text }
            return nil
        }.joined()
    }

    private static func decodeAll(_ data: Data, slice: Int) -> [AIStreamEvent] {
        var decoder = AIStreamDecoder(shape: .openAICompatible)
        var events: [AIStreamEvent] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + slice, data.count)
            events += (try? decoder.feed(data[offset..<end])) ?? []
            offset = end
        }
        events += (try? decoder.finish()) ?? []
        // Fork: a reply's reasoning replay is the loop's, and checked on its own above.
        return events.filter { if case .reasoningReplay = $0 { false } else { true } }
    }

    /// A refusal is read, not discarded: the status's line, then what the provider said under it.
    static func refusalsShowTheProvidersOwnWords() {
        func body(_ json: String) -> Data { Data(json.utf8) }
        func shown(_ status: Int, _ json: String, retryAfter: String? = nil) -> String {
            AIProviderFailure.description(
                status: status, body: body(json), retryAfter: retryAfter, secrets: [])
        }
        let general = "The provider rejected the model or request (HTTP 400)."
        expect(
            shown(
                400,
                #"{"error":{"object":"error","type":"invalid_request_error","message":"#
                    + #""Model accounts/fireworks/models/glm-5p3-flash does not support image input."}}"#)
                == "\(general)\n\nModel accounts/fireworks/models/glm-5p3-flash does not support image input.",
            "OpenAI's error shape shows its message under the line")
        expect(
            shown(
                400,
                #"{"error":{"message":"Provider returned error","code":400,"metadata":"#
                    + #"{"raw":"{\"error\":{\"message\":\"Maximum context length is 8192 tokens\"}}","#
                    + #""provider_name":"Fireworks"}}}"#)
                == "\(general)\n\nMaximum context length is 8192 tokens",
            "OpenRouter's nested upstream body is read through its raw string")
        expect(
            shown(
                400,
                #"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long"}}"#)
                == "\(general)\n\nprompt is too long",
            "Anthropic's shape too")
        expect(
            shown(
                400, #"[{"error":{"code":400,"message":"API key not valid.","status":"INVALID_ARGUMENT"}}]"#)
                == "\(general)\n\nAPI key not valid.",
            "and Gemini's array")
        expect(
            shown(404, #"{"object":"error","message":"The model `x` does not exist.","code":404}"#)
                == "The provider rejected the model or request (HTTP 404).\n\nThe model `x` does not exist.",
            "and vLLM's")
        expect(
            shown(429, #"{"error":{"message":"You exceeded your current quota."}}"#, retryAfter: "12")
                == "Rate limit reached — retry after 12 seconds.\n\nYou exceeded your current quota.",
            "a status keeps its own line, with the provider's reason under it")
        expect(
            shown(400, "Bad request: unknown field") == "\(general)\n\nBad request: unknown field",
            "a plain-text body is shown as sent")
        expect(
            shown(502, "<html><body>Bad gateway</body></html>")
                == "The provider is temporarily unavailable (HTTP 502).",
            "an HTML error page is not pasted into the chat")
        expect(
            shown(401, "") == "API key rejected — check it in Settings.",
            "an empty body leaves the line alone")
        expect(
            shown(
                502,
                #"{"error":{"message":"Upstream timed out","metadata":{"raw":"<html>Bad gateway</html>"}}}"#)
                == "The provider is temporarily unavailable (HTTP 502).\n\nUpstream timed out",
            "an HTML page nested in the body gives way to the message beside it")
        expect(
            shown(502, #"{"error":"<html><body>Bad gateway</body></html>"}"#)
                == "The provider is temporarily unavailable (HTTP 502).",
            "and is left out when it is all there is")
        expect(
            shown(400, #"{"error":{"message":"Provider returned error","metadata":{"raw":"{\"code\":7}"}}}"#)
                == "\(general)\n\nProvider returned error",
            "an upstream body with no message falls back to the wrapper's")
        expect(
            shown(400, #""Bad request""#) == "\(general)\n\nBad request",
            "a bare JSON string loses its quotes")
        expect(
            shown(400, "[Errno 111] Connection refused") == "\(general)\n\n[Errno 111] Connection refused",
            "text that only starts like JSON is still text")

        let echo = String(repeating: "A", count: AIProviderFailure.bodyLimit)
        let oversized =
            #"{"detail":[{"type":"string_type","msg":"Input should be a valid string","input":"\#(echo)"}]}"#
        expect(
            AIProviderFailure.description(
                status: 422, body: body(oversized).prefix(AIProviderFailure.bodyLimit), retryAfter: nil,
                secrets: [])
                == "The provider rejected the model or request (HTTP 422).\n\nInput should be a valid string",
            "a body the cap cut still gives up the message near its start")
        expect(
            shown(400, #"{"error":{"message":"Half a mess"#) == general,
            "and one cut inside its message shows no fragment of JSON")
        expect(
            shown(400, "[\n  {\"error\": {\"message\": \"Too long\"}") == "\(general)\n\nToo long",
            "a cut array is read the same way, however it is spaced")
        expect(
            shown(400, #"["first error", "second"#) == general, "and a cut list of strings is not shown raw")
        expect(shown(400, "[1, 2,") == general, "nor a cut list of anything else")
        expect(
            shown(400, #"["model"] is not supported"#) == "\(general)\n\n[\"model\"] is not supported",
            "a sentence that opens with a bracket and closes it is still a sentence")
        expect(
            shown(400, "{model} was not found") == "\(general)\n\n{model} was not found",
            "whichever bracket it is")
        expect(
            shown(400, "[request timed out]") == "\(general)\n\n[request timed out]",
            "and so is one that is bracketed from end to end")
        expect(
            shown(
                400,
                #"{"message":"<html>Bad gateway</html>","detail":"Reduce your prompt","padding":"#)
                == "\(general)\n\nReduce your prompt",
            "a cut body's first candidate being an HTML page does not hide the next one")
        expect(
            shown(
                400,
                #"{"error":{"message":"Provider returned error","metadata":{"raw":"{\"error\":{\"mess"}}}"#)
                == "\(general)\n\nProvider returned error",
            "an upstream body that arrived cut falls back to the wrapper's message")
        expect(
            shown(
                422,
                #"{"detail":[{"input":{"error":"boom from a tool"},"msg":"Input should be a valid string","x":"#
            )
                == "The provider rejected the model or request (HTTP 422).\n\nInput should be a valid string",
            "an `error` echoed back in the request does not pass for the message")

        let long = String(repeating: "x", count: AIProviderFailure.messageLimit + 50)
        expect(
            shown(400, #"{"error":{"message":"\#(long)"}}"#).hasSuffix("x…")
                && shown(400, #"{"error":{"message":"\#(long)"}}"#).count
                    == general.count + 2 + AIProviderFailure.messageLimit + 1,
            "a very long message is cut rather than filling the chat")

        let key = "fw_3c8a7b2e91d04f5a"
        let echoed = AIProviderFailure.description(
            status: 400,
            body: body(#"{"error":{"message":"Bad header: Bearer \#(key), also sk-proj-abcdefghijklmnop"}}"#),
            retryAfter: nil, secrets: [key])
        expect(
            !echoed.contains(key) && !echoed.contains("sk-proj-abcdef") && echoed.contains("[redacted]"),
            "the key, a bearer token and key-shaped strings never reach the transcript")

        let filler = String(repeating: "x", count: AIProviderFailure.messageLimit - 8)
        let straddling = AIProviderFailure.description(
            status: 400, body: body(#"{"error":{"message":"\#(filler) sk-proj-abcdefghijklmnop"}}"#),
            retryAfter: nil, secrets: [])
        expect(
            !straddling.contains("sk-pro"),
            "a key the cut lands inside is redacted first, not left half-shown")
        expect(
            AIProviderFailure.redacted("Invalid key: abc123.", secrets: ["abc123"])
                == "Invalid key: [redacted].",
            "a short key is redacted too")
        expect(
            AIProviderFailure.redacted("Port 7 refused key 7 (70 tries)", secrets: ["7", ""])
                == "Port [redacted] refused key [redacted] (70 tries)",
            "but only as a whole word, so it cannot eat into a longer one")
        expect(
            AIProviderFailure.redacted("Invalid key: abcdef", secrets: ["abcdef"])
                == "Invalid key: [redacted]",
            "a short key with no digit in it is a key all the same")
        expect(
            AIProviderFailure.redacted("Received API Key = sk-1234", secrets: ["sk-1234"])
                == "Received API Key = [redacted]",
            "as is a local proxy's short key, which no key shape would catch")
    }

    static func brokenStreamsFailLoudly() {
        var decoder = AIStreamDecoder(shape: .openAICompatible)
        let failure = Data(
            """
            data: {"choices":[{"delta":{"content":"Par"}}]}

            data: {"error":{"message":"Provider returned error","code":502}}

            data: {"choices":[{"delta":{"content":"never"}}]}

            """.utf8)
        var events: [AIStreamEvent] = []
        var thrown: Error?
        do { events = try decoder.feed(failure) } catch { thrown = error }
        expect(
            thrown as? AIProviderError == .responseFailed("Provider returned error"),
            "a mid-stream error payload fails with the provider's message")
        expect(decoder.isTerminal, "a mid-stream error ends the stream")
        expect(events.isEmpty, "nothing after the error is decoded")

        var relayed = AIStreamDecoder(shape: .openAICompatible, secrets: ["hunter2-gateway-key"])
        let upstream =
            Data(
                (#"data: {"error":{"message":"Provider returned error","code":400,"metadata":{"raw":"#
                    + #""{\"error\":{\"message\":\"Too long for key hunter2-gateway-key\"}}"}}}"#).utf8)
            + Data("\n\n".utf8)
        var relayedError: Error?
        do { _ = try relayed.feed(upstream) } catch { relayedError = error }
        expect(
            relayedError as? AIProviderError == .responseFailed("Too long for key [redacted]"),
            "a mid-stream error reads through to the upstream reason, with the connection's key out")

        var paged = AIStreamDecoder(shape: .openAICompatible)
        let page = Data(#"data: {"error":{"message":"<html>Bad gateway</html>"}}"#.utf8) + Data("\n\n".utf8)
        var pagedError: Error?
        do { _ = try paged.feed(page) } catch { pagedError = error }
        expect(
            pagedError as? AIProviderError
                == .responseFailed("The provider stopped the response with an error."),
            "a mid-stream error that is only an HTML page says so in Tinycast's own words")

        var bracketed = AIStreamDecoder(shape: .openAICompatible)
        let prose =
            Data(#"data: {"error":{"message":"[\"model\"] is not supported"}}"#.utf8) + Data("\n\n".utf8)
        var bracketedError: Error?
        do { _ = try bracketed.feed(prose) } catch { bracketedError = error }
        expect(
            bracketedError as? AIProviderError == .responseFailed(#"["model"] is not supported"#),
            "a mid-stream message that opens with a bracket is still shown")

        var malformed = AIStreamDecoder(shape: .openAICompatible)
        let garbage = Data("data: {not json\n\n".utf8)
        expect(
            (try? malformed.feed(garbage)) == nil,
            "unparseable JSON is rejected rather than skipped")
        expect(malformed.isTerminal, "a malformed frame ends the stream")

        var overloaded = AIStreamDecoder(shape: .anthropic)
        let said =
            Data(
                #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#.utf8)
            + Data("\n\n".utf8)
        var overloadedError: Error?
        do { _ = try overloaded.feed(said) } catch { overloadedError = error }
        expect(
            overloadedError?.localizedDescription
                == "The provider stopped the response with an error.\n\nOverloaded",
            "an Anthropic error event shows what it said under the line")

        var echoing = AIStreamDecoder(shape: .anthropic, secrets: ["hunter2-gateway-key"])
        let echoed =
            Data(
                #"data: {"type":"error","error":{"type":"api_error","message":"Bad key hunter2-gateway-key"}}"#
                    .utf8)
            + Data("\n\n".utf8)
        var echoedError: Error?
        do { _ = try echoing.feed(echoed) } catch { echoedError = error }
        expect(
            echoedError?.localizedDescription.hasSuffix("Bad key [redacted]") == true,
            "and never the key the connection was using")

        var pagedAnthropic = AIStreamDecoder(shape: .anthropic)
        let anthropicPage =
            Data(
                #"data: {"type":"error","error":{"type":"api_error","message":"<html>Bad gateway</html>"}}"#
                    .utf8)
            + Data("\n\n".utf8)
        var pagedAnthropicError: Error?
        do { _ = try pagedAnthropic.feed(anthropicPage) } catch { pagedAnthropicError = error }
        expect(
            pagedAnthropicError?.localizedDescription == "The provider stopped the response with an error.",
            "nor an HTML page in place of a message")

        var anthropic = AIStreamDecoder(shape: .anthropic)
        let rejected = Data(
            "data: {\"type\":\"error\",\"error\":{\"type\":\"authentication_error\"}}\n\n".utf8)
        var anthropicError: Error?
        do { _ = try anthropic.feed(rejected) } catch { anthropicError = error }
        expect(
            anthropicError as? AIProviderError
                == .responseFailed("API key rejected — check it in Settings."),
            "an Anthropic error event names the cause without echoing the key")

        var silent = AIStreamDecoder(shape: .openAICompatible)
        let truncated = Data("data: {\"choices\":[{\"delta\":{\"content\":\"half\"}}]}\n\n".utf8)
        let partial = (try? silent.feed(truncated)) ?? []
        expect(partial == [.text("half")], "text before a cut-off is still delivered")
        expect(!silent.isTerminal, "a stream without a done marker stays open for the caller to fail")
    }

    static func brandsResolveFromModelIDs() {
        let expected: [(String, AIBrand?)] = [
            ("openai/gpt-oss-20b", .openAI), ("o4-mini", .openAI), ("o3", .openAI),
            ("anthropic/claude-sonnet-4", .claude), ("google/gemma-3-27b-it", .gemini),
            ("x-ai/grok-4", .x), ("deepseek/deepseek-r1", .deepSeek), ("qwen/qwq-32b", .qwen),
            ("mistralai/codestral-2501", .mistral), ("meta-llama/llama-3.3-70b", .meta),
            ("moonshotai/kimi-k2", .kimi), ("minimax/minimax-m1", .miniMax),
            ("perplexity/sonar-pro", .perplexity), ("z-ai/glm-4.5", .zai),
            ("openrouter/auto", .openRouter), ("cohere/command-r", nil), ("o10", nil)
        ]
        for (model, brand) in expected {
            expect(
                AIBrand.resolve(model: model) == brand, "\(model) resolves to \(String(describing: brand))")
        }
        expect(
            AIBrand.resolve(provider: .anthropic, model: "whatever") == .claude,
            "a vendor endpoint names its brand regardless of the model id")
        expect(
            AIBrand.resolve(provider: .openAICompatible, model: "deepseek-chat") == .deepSeek,
            "a compatible endpoint resolves the brand from the model id")
    }

    static func codexProtocolFramesRoundTrip() {
        let request = try? CodexAppServerProtocol.request(
            id: 7, method: "account/read", params: ["refreshToken": false])
        let requestObject = request.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        expect((requestObject?["id"] as? Int) == 7, "Codex requests keep numeric IDs")
        expect(
            requestObject?["method"] as? String == "account/read",
            "Codex requests keep their method")

        let response = Data("{\"id\":7,\"result\":{\"ok\":true}}".utf8)
        if case .response(let id, let result) = CodexAppServerProtocol.parse(response) {
            expect(id == 7, "Codex responses route to the pending request")
            expect(result["ok"]?.boolValue == true, "Codex response values preserve booleans")
        } else {
            expect(false, "a valid Codex response parses")
        }
    }

    static func conversationSettingsPersistAndDecide() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func decide(
            _ opensTo: AIOpensTo, _ after: AINewChatAfter, idle: TimeInterval?
        )
            -> AIConversationOpenPolicy.Decision
        {
            AIConversationOpenPolicy.decide(
                opensTo: opensTo, newAfter: after,
                lastActiveAt: idle.map { now.addingTimeInterval(-$0) }, now: now)
        }

        expect(
            decide(.newConversation, .never, idle: 0) == .startNew,
            "A New Conversation always starts fresh")
        expect(
            decide(.recent, .never, idle: 400 * 86_400) == .resume,
            "Never means no amount of idling starts a new chat")
        expect(decide(.recent, .fiveMinutes, idle: nil) == .startNew, "nothing to resume is new")
        expect(
            decide(.recent, .fiveMinutes, idle: 299) == .resume,
            "inside the window the conversation resumes")
        expect(
            decide(.recent, .fiveMinutes, idle: 301) == .startNew,
            "past the window the next summon starts fresh")
        expect(
            decide(.recent, .fiveMinutes, idle: 300) == .startNew,
            "the boundary itself starts fresh, so the window is exclusive at its end")
        // A backwards clock yields a negative interval; it must not strand a reader in a chat.
        expect(
            decide(.recent, .twoMinutes, idle: -3_600) == .resume,
            "a clock that moved backwards resumes rather than misreading the idle time")

        expect(
            AIRetention.allCases.allSatisfy { !$0.title.isEmpty },
            "every retention names itself")
        expect(
            AIRetention.week.cutoff(from: now) == now.addingTimeInterval(-7 * 86_400),
            "a week's cutoff is seven days back")
        expect(
            AINewChatAfter.allCases.filter { $0.rawValue == 0 }.isEmpty,
            "no timeout uses 0, which an unset key would swallow before the default applied")

        let suite = "AIProviderTests.conversations"
        let defaults = isolatedDefaults(suite)
        defer { discardSuite(suite, defaults) }

        let fresh = AISettingsStore(defaults: defaults)
        expect(fresh.retention == .forever, "retention defaults to Forever, so upgrading deletes nothing")
        expect(fresh.opensTo == .recent, "chat reopens on the recent conversation by default")
        expect(fresh.newChatAfter == .fiveMinutes, "the idle window defaults to five minutes")
        expect(fresh.toolRounds == .twentyFive, "a reply's tool rounds default to 25")

        fresh.retention = .week
        fresh.opensTo = .newConversation
        fresh.newChatAfter = .never
        fresh.toolRounds = .fifty
        let reopened = AISettingsStore(defaults: defaults)
        expect(reopened.toolRounds == .fifty, "the tool round cap persists")
        reopened.toolRounds = .unlimited
        expect(
            AISettingsStore(defaults: defaults).toolRounds == .unlimited,
            "Unlimited persists rather than reading as the default")
        expect(AIToolRounds.unlimited.limit == nil, "and hands the loop no cap")
        expect(AIToolRounds.fifty.limit == 50, "while a step hands it its own number")
        defaults.set(7, forKey: AppSettingsKey.aiToolRounds.rawValue)
        expect(
            AISettingsStore(defaults: defaults).toolRounds == .twentyFive,
            "a stored cap no case carries reads as the default rather than an arbitrary number")
        defaults.set(0, forKey: AppSettingsKey.aiToolRounds.rawValue)
        expect(
            AISettingsStore(defaults: defaults).toolRounds == .twentyFive,
            "and so does a 0, which is neither a step nor Unlimited")
        expect(reopened.retention == .week, "retention persists")
        expect(reopened.opensTo == .newConversation, "the open policy persists")
        expect(reopened.newChatAfter == .never, "Never persists rather than reading as the default")
    }

    static func onDeviceSelectionsRoundTripAndLead() {
        let encoded = try? JSONEncoder().encode(AIModelSelection.appleIntelligence)
        let decoded = encoded.flatMap { try? JSONDecoder().decode(AIModelSelection.self, from: $0) }
        expect(decoded == .appleIntelligence, "the on-device selection survives a round trip")
        expect(
            AIModelSelection.appleIntelligence.model == AppleIntelligence.modelID,
            "the on-device selection reports a stable model id")
        expect(
            AIModelSelection.appleIntelligence.source == .appleIntelligence,
            "the on-device selection is its own source")
        expect(
            AIModelSelection.appleIntelligence.isOnDevice
                && !AIModelSelection.codex(model: "gpt-5", effort: nil).isOnDevice,
            "only the on-device selection reads as on device")

        let legacy = Data(#"{"chatGPT":{"model":"gpt-5","effort":"high"}}"#.utf8)
        expect(
            (try? JSONDecoder().decode(AIModelSelection.self, from: legacy))
                == .codex(model: "gpt-5", effort: "high"),
            "the old ChatGPT selection migrates to the installed Codex route")

        let suite = "AIProviderTests.onDevice"
        let defaults = isolatedDefaults(suite)
        defer { discardSuite(suite, defaults) }

        let store = AISettingsStore(defaults: defaults, isAppleIntelligenceAvailable: { true })
        expect(
            store.defaultModel == .appleIntelligence,
            "the on-device route is the default on an unconfigured Mac")

        // A configured connection must not be displaced by resolution running a second time.
        let connectionID = UUID()
        store.save(AIConnection(id: connectionID, name: "Local", models: ["m"]))
        store.select(.api(connection: connectionID, model: "m", effort: nil))
        store.resolveDefaultModel()
        expect(
            store.defaultModel == .api(connection: connectionID, model: "m", effort: nil),
            "resolution never overrides a selection the reader made")

        // A removed connection falls forward to the route that is always configured.
        store.removeConnection(id: connectionID)
        expect(
            store.defaultModel == .appleIntelligence,
            "a removed connection falls forward to the on-device route")

        let without = AISettingsStore(defaults: defaults, isAppleIntelligenceAvailable: { false })
        without.resolveDefaultModel()
        expect(
            without.defaultModel == .appleIntelligence,
            "an unavailable model does not silently reroute a stored on-device selection")
    }

    static func settingsPersistAndRepairSelections() {
        let suite = "AIProviderTests.persistence"
        let defaults = isolatedDefaults(suite)
        defer { discardSuite(suite, defaults) }
        let firstID = UUID()
        let secondID = UUID()

        var first = AIConnection(
            id: firstID, name: "  Work  ", provider: .openRouter,
            models: [" model-a ", "model-a", "model-b"],
            reasoningOptions: [
                "model-b": .init(efforts: ["medium", "low"], defaultEffort: "medium")
            ])
        first.baseURL = " https://openrouter.ai/api/v1 "
        let store = AISettingsStore(defaults: defaults)
        store.save(first)
        store.save(
            AIConnection(id: secondID, provider: .gemini, models: ["gemini-model"]))
        expect(store.connections.first?.name == "Work", "connection names are normalized")
        expect(
            store.connections.first?.models == ["model-a", "model-b"],
            "models are trimmed and deduplicated")
        expect(
            store.defaultModel == .api(connection: firstID, model: "model-a", effort: nil),
            "the first saved model becomes the default")
        store.select(.api(connection: firstID, model: "model-b", effort: "low"))

        let reopened = AISettingsStore(defaults: defaults)
        expect(reopened.connections == store.connections, "connection metadata survives a restart")
        expect(reopened.defaultModel == store.defaultModel, "the default model survives a restart")
        reopened.removeConnection(id: firstID)
        expect(
            reopened.defaultModel
                == .api(
                    connection: secondID, model: "gemini-model", effort: nil),
            "removing the default connection falls forward to another API model")
    }

    static func installedModelLoadingPreferencePersists() {
        let suite = "AIProviderTests.installedModelLoading"
        let defaults = isolatedDefaults(suite)
        defer { discardSuite(suite, defaults) }
        let store = AISettingsStore(defaults: defaults)
        expect(
            store.enabledInstalledProviders.isEmpty,
            "installed providers are disabled by default")
        store.setInstalledProviderEnabled(true, for: .claude)
        store.setInstalledProviderEnabled(false, for: .openCode)
        let reopened = AISettingsStore(defaults: defaults)
        expect(
            reopened.enabledInstalledProviders == [.claude],
            "an enabled provider survives a restart")
        expect(
            !reopened.enabledInstalledProviders.contains(.openCode),
            "a provider toggle survives a restart")
    }

    static func installedOverridesPersistAndResolve() {
        let suite = "AIProviderTests.installedOverrides"
        let defaults = isolatedDefaults(suite)
        defer { discardSuite(suite, defaults) }
        let kept = KeptVariables()
        let environmentStore = InstalledAIEnvironmentStore(
            values: { kept.values[$0] ?? [:] }, save: { kept.values[$1] = $0 })
        let store = AISettingsStore(defaults: defaults, environmentStore: environmentStore)
        expect(store.launch(for: .codex) == InstalledAILaunch(), "a tool left alone has no override")
        store.setCommandPath("  ~/bin/codex \n", for: .codex)
        expect(store.override(for: .codex).commandPath == "~/bin/codex", "a path is kept trimmed")
        expect(store.launchRevisions[.codex] == 1, "and setting it counts as a change to the launch")
        store.setCommandPath("~/bin/codex", for: .codex)
        expect(store.launchRevisions[.codex] == 1, "the same path again is no change")
        try? store.setEnvironment(
            [
                InstalledAIVariable(name: "HTTPS_PROXY", value: "http://127.0.0.1:9"),
                InstalledAIVariable(name: "HTTPS_PROXY", value: "a second one"),
                InstalledAIVariable(name: "not a name", value: "x"),
                InstalledAIVariable(name: "CODEX_HOME", value: "/tmp/home")
            ], for: .codex)
        expect(
            store.override(for: .codex).environmentNames == ["HTTPS_PROXY", "CODEX_HOME"],
            "variables keep their order, without a repeated or an unusable name")
        expect(
            defaults.data(forKey: AppSettingsKey.aiInstalledOverrides.rawValue)
                .map { String(decoding: $0, as: UTF8.self) }?.contains("127.0.0.1") == false,
            "and no value is written to settings")
        let reopened = AISettingsStore(defaults: defaults, environmentStore: environmentStore)
        expect(
            reopened.launch(for: .codex)
                == InstalledAILaunch(
                    commandPath: "~/bin/codex",
                    environment: ["HTTPS_PROXY": "http://127.0.0.1:9", "CODEX_HOME": "/tmp/home"]),
            "a launch after a restart has the path and the values")
        expect(
            (try? reopened.environment(for: .codex))?.map(\.name) == ["HTTPS_PROXY", "CODEX_HOME"],
            "and the editor lists them in the order they were entered")
        reopened.setCommandPath("", for: .codex)
        try? reopened.setEnvironment([], for: .codex)
        expect(
            defaults.object(forKey: AppSettingsKey.aiInstalledOverrides.rawValue) == nil
                && kept.values[.codex]?.isEmpty == true,
            "clearing both leaves nothing stored")

        let home = NSHomeDirectory()
        let present: (String) -> Bool = { $0 == home + "/bin/codex" }
        expect(InstalledAILaunch().command(isExecutable: present) == .automatic, "no path looks up")
        expect(
            InstalledAILaunch(commandPath: "~/bin/codex").command(isExecutable: present)
                == .executable(URL(fileURLWithPath: home + "/bin/codex")),
            "a path under the home folder may be written with a tilde")
        expect(
            InstalledAILaunch(commandPath: "/opt/none/codex").command(isExecutable: present)
                == .missing(path: "/opt/none/codex"),
            "a path with nothing to run is reported, never replaced by a lookup")
        expect(
            InstalledAILaunch(commandPath: "codex").command(isExecutable: { _ in true })
                == .missing(path: "codex"),
            "a bare name is not a path")
    }

    static func aFailedKeychainReadIsNeverSavedOver() {
        let suite = "AIProviderTests.failedKeychainRead"
        let defaults = isolatedDefaults(suite)
        defer { discardSuite(suite, defaults) }
        let kept = KeptVariables()
        kept.values[.claude] = ["HTTPS_PROXY": "http://127.0.0.1:9"]
        let working = InstalledAIEnvironmentStore(
            values: { kept.values[$0] ?? [:] }, save: { kept.values[$1] = $0 })
        try? AISettingsStore(defaults: defaults, environmentStore: working).setEnvironment(
            [InstalledAIVariable(name: "HTTPS_PROXY", value: "http://127.0.0.1:9")], for: .claude)
        let locked = InstalledAIEnvironmentStore(
            values: { _ in throw KeychainUnreadable() }, save: { kept.values[$1] = $0 })
        let store = AISettingsStore(defaults: defaults, environmentStore: locked)
        expect(
            (try? store.environment(for: .claude)) == nil,
            "a read that fails is an error, never a list of names without values")
        expect(
            (try? store.setEnvironment(
                [InstalledAIVariable(name: "HTTPS_PROXY", value: "")], for: .claude)) == nil,
            "and saving over values that could not be read fails")
        expect(
            kept.values[.claude] == ["HTTPS_PROXY": "http://127.0.0.1:9"],
            "so the stored value survives")
        expect(
            store.launch(for: .claude).environment.isEmpty,
            "a launch that cannot read the values starts without them")
    }

    static func aLaunchInheritsTheReadersVariablesNotTinycastsOwn() {
        let launch = InstalledAILaunch(
            environment: [
                "PATH": "/reader/bin", "HTTPS_PROXY": "proxy", "NO_COLOR": "0",
                "OPENCODE_CONFIG_CONTENT": "{}", "TC_MCP_0_0": "stolen", "1BAD": "x"
            ])
        let inherited = launch.inherited(
            for: .openCode, base: ["PATH": "/usr/bin", "HOME": "/Users/reader", "NO_COLOR": "1"])
        expect(
            inherited["PATH"] == "/reader/bin" && inherited["HTTPS_PROXY"] == "proxy"
                && inherited["HOME"] == "/Users/reader",
            "the reader's variables lie over the app's own")
        expect(
            inherited["OPENCODE_CONFIG_CONTENT"] == nil && inherited["TC_MCP_0_0"] == nil
                && inherited["NO_COLOR"] == "1" && inherited["1BAD"] == nil,
            "but never one Tinycast sets itself, nor one that is not a variable name")
        expect(
            launch.inherited(for: .claude, base: [:])["OPENCODE_CONFIG_CONTENT"] == "{}",
            "a name only another tool reserves is an ordinary variable here")
        expect(
            InstalledAIKind.allCases.allSatisfy { kind in
                kind.managedEnvironment.keys.allSatisfy(kind.isManagedVariable)
            },
            "every variable a tool is launched with is one the reader cannot replace")
    }

    static func switchedOffRoutesLeaveTheDefault() {
        let suite = "AIProviderTests.disabledRoutes"
        let defaults = isolatedDefaults(suite)
        defer { discardSuite(suite, defaults) }
        let store = AISettingsStore(defaults: defaults)
        let first = AIConnection(provider: .openRouter, models: ["first-model"])
        let second = AIConnection(provider: .gemini, models: ["second-model"])
        store.save(first)
        store.save(second)
        expect(store.defaultModel?.source == .api(first.id), "the first connection is the default")
        store.setRoute(.api(first.id), enabled: false)
        expect(
            store.defaultModel?.source == .api(second.id),
            "switching the default's connection off moves the default to one still on")
        let reopened = AISettingsStore(defaults: defaults)
        expect(
            !reopened.isRouteEnabled(.api(first.id)) && reopened.isRouteEnabled(.api(second.id)),
            "a switched-off connection stays off after a restart")
        reopened.setRoute(.appleIntelligence, enabled: false)
        expect(
            !reopened.isRouteEnabled(.appleIntelligence),
            "the on-device model can be switched off like a connection")
        reopened.setRoute(.api(first.id), enabled: true)
        reopened.removeConnection(id: second.id)
        expect(
            reopened.defaultModel?.source == .api(first.id),
            "with the other one gone, the connection switched back on becomes the default")
        reopened.removeConnection(id: first.id)
        expect(
            !reopened.disabledRoutes.contains(AIModelSource.api(first.id).storageKey),
            "removing a connection forgets that it was switched off")
    }

    static func shownModelsFilterThePicker() {
        let suite = "AIProviderTests.shownModels"
        let defaults = isolatedDefaults(suite)
        defer { discardSuite(suite, defaults) }
        let store = AISettingsStore(defaults: defaults)
        let available = ["a", "b", "c"]
        expect(
            available.allSatisfy { store.isModelShown($0, in: .openCode) },
            "a route nobody has trimmed lists every model")
        store.setModel("b", shown: false, in: .openCode, available: available)
        let reopened = AISettingsStore(defaults: defaults)
        expect(
            reopened.isModelShown("a", in: .openCode) && !reopened.isModelShown("b", in: .openCode),
            "an unticked model stays out of the picker after a restart")
        expect(
            !reopened.isModelShown("d", in: .openCode),
            "a trimmed route does not list a model it adds later")
        expect(
            reopened.isModelShown("b", in: .claude),
            "trimming one route leaves the others listing everything")
        reopened.setModel("b", shown: true, in: .openCode, available: available)
        expect(
            reopened.shownModels[AIModelSource.openCode.storageKey] == nil
                && reopened.isModelShown("d", in: .openCode),
            "ticking every model back returns the route to listing all, later ones included")
        reopened.hideAllModels(in: .openCode)
        expect(
            available.allSatisfy { !reopened.isModelShown($0, in: .openCode) },
            "Hide All leaves nothing but the default listed")
        let connection = AIConnection(provider: .openRouter, models: ["x", "y"])
        reopened.save(connection)
        reopened.setModel("y", shown: false, in: .api(connection.id), available: connection.models)
        reopened.removeConnection(id: connection.id)
        expect(
            reopened.shownModels[AIModelSource.api(connection.id).storageKey] == nil,
            "removing a connection forgets which of its models were shown")
    }

    static func subscriptionSelectionsReconcile() {
        let suite = "AIProviderTests.subscription"
        let defaults = isolatedDefaults(suite)
        defer { discardSuite(suite, defaults) }
        let store = AISettingsStore(defaults: defaults)
        let model = ChatGPTSubscription.Model(
            id: "gpt", name: "GPT",
            efforts: [
                .init(id: "low", detail: nil), .init(id: "high", detail: nil)
            ], defaultEffort: "high", isDefault: true)
        store.select(.codex(model: "gpt", effort: "missing"))
        store.reconcile(codexModels: [model], isUnavailable: false)
        expect(
            store.defaultModel == .codex(model: "gpt", effort: "high"),
            "a removed reasoning tier falls back to the model default")
        store.reconcile(codexModels: [], isUnavailable: true)
        expect(store.defaultModel == nil, "signing out clears an unusable Codex default")

        store.select(.claude(model: "removed", effort: nil))
        store.reconcile(
            installed: .claude,
            models: [InstalledAIModel(id: "sonnet", name: "Claude Sonnet")],
            isUnavailable: false)
        expect(
            store.defaultModel == .claude(model: "sonnet", effort: nil),
            "an installed catalog replaces a model alias that disappeared")
        store.reconcile(installed: .claude, models: [], isUnavailable: true)
        expect(store.defaultModel == nil, "signing out clears an unusable Claude default")
    }

    static func installedCLIStreamsDecode() {
        let openCodeText = Data(
            #"{"type":"text","sessionID":"ses_1","part":{"text":"Hello"}}"#.utf8)
        expect(
            InstalledAIStreamDecoder.decode(openCodeText, kind: .openCode)
                == InstalledAIStreamFrame(events: [.text("Hello")], sessionID: "ses_1"),
            "OpenCode text and its cleanup session decode together")
        let openCodeReasoning = Data(
            #"{"type":"reasoning","sessionID":"ses_1","part":{"text":"Weighing it"}}"#.utf8)
        expect(
            InstalledAIStreamDecoder.decode(openCodeReasoning, kind: .openCode).events
                == [.reasoning("\n\nWeighing it")],
            "OpenCode reasoning opens its own block")
        let openCodeStep = Data(
            #"""
            {"type":"step_finish","sessionID":"ses_1","part":{"cost":0.25,"tokens":{"input":12,
            "output":4,"reasoning":3,"cache":{"read":5,"write":1}}}}
            """#.utf8)
        let openCodeFrame = InstalledAIStreamDecoder.decode(openCodeStep, kind: .openCode)
        expect(
            openCodeFrame.events == [
                .usage(
                    AIUsage(
                        inputTokens: 12, outputTokens: 7, cachedInputTokens: 6,
                        reasoningTokens: 3, costUSD: 0.25))
            ] && !openCodeFrame.completed,
            "an OpenCode step reports usage and leaves the finish to the clean exit")
        let openCodeError = Data(
            #"{"type":"error","sessionID":"","error":{"type":"unknown","message":"No provider"}}"#.utf8)
        let openCodeErrorFrame = InstalledAIStreamDecoder.decode(openCodeError, kind: .openCode)
        expect(
            openCodeErrorFrame.error == "No provider" && openCodeErrorFrame.sessionID == nil,
            "an OpenCode error before any session fails the turn with nothing to delete")
        let openCodeModels = #"""
            {"location":{"directory":"/w"},"data":[
            {"id":"gpt-5","providerID":"openai","name":"GPT-5",
            "capabilities":{"tools":true,"input":["text","image"],"output":["text"]},
            "variants":[{"id":"high"},{"id":"low"},{"id":"minimal"}]},
            {"id":"glm-4.6","providerID":"zai","name":"GLM 4.6",
            "capabilities":{"tools":true,"input":["text"],"output":["text"]},"variants":[]},
            {"id":"claude-sonnet-4-5","providerID":"anthropic","name":"Claude Sonnet 4.5",
            "capabilities":{"tools":true,"input":["text","image","pdf"],"output":["text"]},
            "variants":[]}]}
            """#
        let openCodeCatalog = InstalledAIModel.openCodeCatalog(openCodeModels)
        expect(
            openCodeCatalog.map(\.id) == [
                "anthropic/claude-sonnet-4-5", "openai/gpt-5", "zai/glm-4.6"
            ],
            "OpenCode models are listed by their provider-qualified reference")
        expect(
            openCodeCatalog[1].efforts.map(\.id) == ["minimal", "low", "high"],
            "OpenCode variants become efforts in reasoning order")
        expect(
            openCodeCatalog.map(\.acceptsImages) == [true, true, false],
            "OpenCode takes images only where the model's input does")
        expect(
            InstalledAIModel.openCodeCatalog("Error: server failed to start").isEmpty,
            "an OpenCode answer that is not the model list yields no models")

        let claudeText = Data(
            #"{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"Hi"}}}"#.utf8)
        expect(
            InstalledAIStreamDecoder.decode(claudeText, kind: .claude).events == [.text("Hi")],
            "Claude partial text decodes without replaying its full assistant message")
        let claudeFinish = Data(
            #"{"type":"result","is_error":false,"usage":{"input_tokens":8,"output_tokens":3}}"#.utf8)
        let claudeFrame = InstalledAIStreamDecoder.decode(claudeFinish, kind: .claude)
        expect(
            claudeFrame.events == [.usage(AIUsage(inputTokens: 8, outputTokens: 3))]
                && claudeFrame.completed,
            "Claude result usage ends the stream")

        let cursorDelta = Data(
            #"{"type":"assistant","timestamp_ms":1,"message":{"content":[{"type":"text","text":"Hi"}]}}"#
                .utf8)
        expect(
            InstalledAIStreamDecoder.decode(cursorDelta, kind: .cursor).events == [.text("Hi")],
            "Cursor live deltas decode as text")
        let cursorFlush = Data(
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hi"}]}}"#.utf8)
        expect(
            InstalledAIStreamDecoder.decode(cursorFlush, kind: .cursor).events.isEmpty,
            "Cursor buffered flushes without timestamp_ms are ignored")
        let cursorDone = Data(#"{"type":"result","subtype":"success","result":"Hi"}"#.utf8)
        expect(
            InstalledAIStreamDecoder.decode(cursorDone, kind: .cursor).completed,
            "Cursor result ends the stream")
        let cursorSession = Data(
            #"{"type":"system","subtype":"init","session_id":"ses_cursor"}"#.utf8)
        expect(
            InstalledAIStreamDecoder.decode(cursorSession, kind: .cursor).sessionID == "ses_cursor",
            "Cursor system init carries the session id for cleanup")
        let grokText = Data(
            #"{"type":"stream_event","session_id":"ses_g","event":{"delta":{"type":"text_delta","text":"Yo"}}}"#
                .utf8)
        let grokTextFrame = InstalledAIStreamDecoder.decode(grokText, kind: .grok)
        expect(
            grokTextFrame.events == [.text("Yo")] && grokTextFrame.sessionID == "ses_g",
            "Grok partial text reuses the Claude stream shape and keeps the session id")
        let grokFinish = Data(
            #"{"type":"result","is_error":false,"session_id":"ses_g","usage":{"input_tokens":5,"output_tokens":1}}"#
                .utf8)
        let grokFrame = InstalledAIStreamDecoder.decode(grokFinish, kind: .grok)
        expect(
            grokFrame.events == [.usage(AIUsage(inputTokens: 5, outputTokens: 1))]
                && grokFrame.completed && grokFrame.sessionID == "ses_g",
            "Grok result usage ends the stream and names the session to delete")
        let grokError = Data(
            #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["Not signed in."],"session_id":""}"#
                .utf8)
        let grokErrorFrame = InstalledAIStreamDecoder.decode(grokError, kind: .grok)
        expect(
            grokErrorFrame.error == "Not signed in." && grokErrorFrame.sessionID == nil
                && !grokErrorFrame.completed,
            "Grok execution errors name the cause, not Claude, and ignore an empty session id")
        let grokBare = Data(#"{"type":"result","is_error":true}"#.utf8)
        expect(
            InstalledAIStreamDecoder.decode(grokBare, kind: .grok).error
                == "Grok could not finish the response.",
            "a Grok error with no cause still names Grok")
    }

    /// A secret on argv is in `ps`, and a key Codex does not know is a server that never starts.
    static func codexLaunchNamesServersAndKeepsSecretsOffArgv() {
        let stdio = AIToolServer(
            handle: "files", title: "Files",
            transport: .command(
                path: "/usr/local/bin/node", arguments: ["server.js", "--root=/tmp"],
                environment: ["API_KEY": "s3cret"]))
        let oauth = AIToolServer(
            handle: "linear", title: "Linear",
            transport: .url(
                "https://mcp.linear.app/mcp", headerName: "Authorization",
                headerValue: "Bearer tok-123"))
        let custom = AIToolServer(
            handle: "notes", title: "Notes",
            transport: .url(
                "https://notes.example/mcp", headerName: "X-Api-Key", headerValue: "k1"))

        let arguments = CodexMCPLaunch.arguments(
            servers: [stdio, oauth, custom], disabling: ["computer-use", "files"])
        expect(
            arguments.contains("mcp_servers.computer-use.enabled=false")
                && arguments.contains("mcp_servers.files.enabled=false"),
            "every one of the reader's own servers is disabled by name, one named like ours too")
        expect(
            arguments.contains("mcp_servers.tinycast-files.enabled=true")
                && !arguments.contains {
                    $0.hasPrefix("mcp_servers.files.") && !$0.hasSuffix("=false")
                },
            "since Tinycast's go by names of their own, which no table of the reader's merges into")
        expect(
            arguments.contains(#"mcp_servers.tinycast-files.command="/bin/sh""#)
                && arguments.contains(Self.renamingArguments),
            "a local server with variables arrives through a shell that renames them, then runs it")
        expect(
            arguments.contains(Self.forwardedVariables),
            "whose environment is named rather than carried: Codex forwards only what is listed")
        expect(
            arguments.contains(#"mcp_servers.tinycast-linear.bearer_token_env_var="TC_MCP_1_0""#),
            "an OAuth endpoint lends its token through the variable Codex reads it from")
        expect(
            arguments.contains(Self.headerMapOverride),
            "and another header name goes through the map that takes one")
        expect(
            !arguments.contains {
                $0.contains("s3cret") || $0.contains("tok-123") || $0.contains("k1")
            },
            "no value reaches argv, where `ps` would show it")

        let environment = CodexMCPLaunch.environment(servers: [stdio, oauth, custom]) ?? [:]
        expect(
            environment["TC_MCP_0_0"] == "s3cret" && environment["TC_MCP_2_0"] == "k1",
            "the values ride the child's environment instead")
        expect(
            environment["TC_MCP_1_0"] == "tok-123",
            "and a bearer token loses its prefix, because Codex composes that itself")

        let open = AIToolServer(
            handle: "open", title: "Open",
            transport: .url(
                "https://open.example/mcp", headerName: "Authorization", headerValue: ""))
        let openArguments = CodexMCPLaunch.arguments(servers: [open], disabling: [])
        expect(
            openArguments.contains(#"mcp_servers.tinycast-open.url="https://open.example/mcp""#)
                && !openArguments.contains { $0.contains("bearer_token") || $0.contains("headers") }
                && CodexMCPLaunch.environment(servers: [open]) == [:],
            "a server that needs no credential goes to Codex with no header and no variable")

        let quoted = CodexMCPLaunch.arguments(
            servers: [
                AIToolServer(
                    handle: "odd", title: "Odd",
                    transport: .command(
                        path: #"/tmp/we"ird\bin"#, arguments: [], environment: [:]))
            ], disabling: [])
        expect(
            quoted.contains(#"mcp_servers.tinycast-odd.command="/tmp/we\"ird\\bin""#),
            "a path with a quote in it is still one TOML string")

        expect(
            CodexMCPLaunch.quoted("a\r\nb\tc\u{1}\u{7F}é\"\\")
                == #""a\u000D\u000Ab\u0009c\u0001\u007Fé\"\\""#,
            "CRLF, every other control character and DEL become \\u escapes TOML accepts")
        let crlf = CodexMCPLaunch.arguments(
            servers: [
                AIToolServer(
                    handle: "lines", title: "Lines",
                    transport: .command(path: "/bin/echo", arguments: ["a\r\nb"], environment: [:]))
            ], disabling: [])
        expect(
            crlf.contains(#"mcp_servers.tinycast-lines.args=["a\u000D\u000Ab"]"#),
            "so an argument carrying a Windows line ending still leaves Codex's config loadable")

        expect(
            CodexMCPLaunch.handle(ofServer: "tinycast-files") == "files"
                && CodexMCPLaunch.handle(ofServer: "files") == nil
                && CodexMCPLaunch.handle(ofServer: "tinycast-") == nil,
            "a name Codex reports maps back to a handle only when it is one of Tinycast's")
        expect(
            CodexMCPLaunch.takenName(servers: [stdio], foreignNames: ["tinycast-files"])
                == "tinycast-files"
                && CodexMCPLaunch.takenName(servers: [stdio], foreignNames: ["files"]) == nil,
            "and a reader's server already named like an armed one of ours is caught before launch")

        expect(
            CodexMCPLaunch.foreignNames(listing: #"[{"name":"a","enabled":true},{"name":"b c"}]"#)
                == ["a", "b c"],
            "the reader's servers are every name `codex mcp list --json` reports")
        expect(
            CodexMCPLaunch.foreignNames(listing: "warning: not json") == nil
                && CodexMCPLaunch.foreignNames(listing: #"{"name":"a"}"#) == nil
                && CodexMCPLaunch.foreignNames(listing: #"[{"name":"a"},{"enabled":true}]"#) == nil,
            "and output that is not that list reads as unknown, never as an empty one")
        expect(
            CodexMCPLaunch.unaddressableName(["ok", "日本", "has space", "has.dot"]) == "has.dot"
                && CodexMCPLaunch.unaddressableName(["a=b"]) == "a=b"
                && CodexMCPLaunch.unaddressableName(["ok", "日本", "has space"]) == nil,
            "only a dot or `=` keeps `-c` from naming a server; spaces and other scripts do not")
    }

    /// Only running the launch proves a server gets its own names; `printenv` stands in for it.
    static func codexLaunchHandsAServerItsOwnVariableNames() {
        let derived = ["TC_MCP_0_0": "s3cret"]
        let launch = CodexMCPLaunch.command(
            path: "/usr/bin/printenv", arguments: ["API_KEY"],
            environment: ["API_KEY": "s3cret"], server: 0)
        expect(
            run(launch, environment: derived) == "s3cret\n",
            "the server reads its value under its own name, which Codex alone cannot give it")
        let leftover = CodexMCPLaunch.command(
            path: "/usr/bin/printenv", arguments: ["TC_MCP_0_0"],
            environment: ["API_KEY": "s3cret"], server: 0)
        expect(
            run(leftover, environment: derived) == "",
            "and the derived name is gone, so the value does not reach it twice")

        let odd = AIToolServer(
            handle: "odd", title: "Odd",
            transport: .command(
                path: "/usr/bin/true", arguments: [], environment: ["NOT-A-NAME": "hidden"]))
        let oddArguments = CodexMCPLaunch.arguments(servers: [odd], disabling: [])
        expect(
            oddArguments.contains(#"mcp_servers.tinycast-odd.command="/usr/bin/true""#)
                && oddArguments.contains("mcp_servers.tinycast-odd." + "env" + "_vars=[]"),
            "a name the shell cannot export is not forwarded, and the server launches directly")
        expect(
            CodexMCPLaunch.environment(servers: [odd]) == [:],
            "so its value never enters the app-server's environment under a name nobody reads")
    }

    /// Two spellings of handle and key must never meet in one variable, or a secret changes hands.
    static func codexVariablesNeverCollide() {
        func local(_ handle: String, _ environment: [String: String]) -> AIToolServer {
            AIToolServer(
                handle: handle, title: handle,
                transport: .command(
                    path: "/usr/bin/printenv", arguments: [], environment: environment))
        }
        let servers = [
            local("github-x", ["TOKEN": "one"]),
            local("github", ["X_TOKEN": "two"]),
            local("both", ["token": "three", "TOKEN": "four"]),
            AIToolServer(
                handle: "a", title: "a",
                transport: .url("https://a.example/mcp", headerName: "B-C", headerValue: "five")),
            local("a-b", ["C": "six"]),
            local("日本", ["TOKEN": "seven"]),
            local("中国", ["TOKEN": "eight"])
        ]
        let environment = CodexMCPLaunch.environment(servers: servers) ?? [:]
        expect(
            environment.count == 8
                && Set(environment.values)
                    == ["one", "two", "three", "four", "five", "six", "seven", "eight"],
            "every secret gets a variable of its own, however the handles and keys are spelled")
        var delivered: [String] = []
        for (index, server) in servers.enumerated() {
            guard case .command(let path, _, let values) = server.transport else { continue }
            for key in values.keys.sorted() {
                let launch = CodexMCPLaunch.command(
                    path: path, arguments: [key], environment: values, server: index)
                delivered.append(run(launch, environment: environment))
            }
        }
        expect(
            delivered == ["one\n", "two\n", "four\n", "three\n", "six\n", "seven\n", "eight\n"],
            "and each local server reads only its own values, under its own names")
        let shadowing = ["TC_MCP_0_0": "zero", "TC_MCP_0_1": "one", "Z": "zed"]
        let shadowingDerived = CodexMCPLaunch.environment(servers: [local("s", shadowing)]) ?? [:]
        let shadowingReads = ["TC_MCP_0_0", "TC_MCP_0_1", "Z", "TC_MCP_0_2"].map { key in
            let launch = CodexMCPLaunch.command(
                path: "/usr/bin/printenv", arguments: [key], environment: shadowing, server: 0)
            return run(launch, environment: shadowingDerived)
        }
        expect(
            shadowingReads == ["zero\n", "one\n", "zed\n", ""],
            "a key spelled like a derived name still reads its own value, as do the keys after it")
        let many = Dictionary(uniqueKeysWithValues: (0...10).map { ("K\($0)", "v\($0)") })
        let manyDerived = CodexMCPLaunch.environment(servers: [local("m", many)]) ?? [:]
        let manyReads = many.keys.sorted().map { key in
            run(
                CodexMCPLaunch.command(
                    path: "/usr/bin/printenv", arguments: [key], environment: many, server: 0),
                environment: manyDerived)
        }
        expect(
            manyReads == many.keys.sorted().map { many[$0]! + "\n" },
            "a tenth value and beyond reads whole, not as the first followed by a digit")
        let repeated = [(name: "TC_MCP_0_0", value: "a"), (name: "TC_MCP_0_0", value: "b")]
        expect(
            CodexMCPLaunch.distinct(repeated) == nil,
            "a repeated variable refuses the launch rather than keeping one of the two values")
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func run(
        _ launch: (path: String, arguments: [String]), environment: [String: String]
    ) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.path)
        process.arguments = launch.arguments
        process.environment = environment.merging(["PATH": "/usr/bin:/bin"]) { value, _ in value }
        let output = Pipe()
        process.standardOutput = output
        guard (try? process.run()) != nil else { return "<did not start>" }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private static let renamingArguments =
        #"mcp_servers.tinycast-files.args=["-c","set -- \"$TC_MCP_0_0\" \"$@\"; "#
        + #"unset TC_MCP_0_0; export API_KEY=\"${1}\"; shift 1; "#
        + #"exec \"$@\"","tinycast-mcp","/usr/local/bin/node","server.js","--root=/tmp"]"#

    /// Spelled through a joined literal so no shell hook mistakes the key for a dotfile.
    private static let forwardedVariables =
        "mcp_servers.tinycast-files." + "env" + #"_vars=["TC_MCP_0_0"]"#
    private static let headerMapOverride =
        "mcp_servers.tinycast-notes." + "env" + #"_http_headers={"X-Api-Key"="TC_MCP_2_0"}"#

    /// The file is the only place Claude's secrets go, and the tool name is what routes back.
    static func claudeConfigurationCarriesServersAndRoutesToolNames() {
        let servers = [
            AIToolServer(
                handle: "files", title: "Files",
                transport: .command(
                    path: "/bin/node", arguments: ["s.js"], environment: ["API_KEY": "s3cret"])),
            AIToolServer(
                handle: "linear", title: "Linear",
                transport: .url(
                    "https://mcp.linear.app/mcp", headerName: "Authorization",
                    headerValue: "Bearer tok-123"))
        ]
        let text = ClaudeMCPLaunch.configuration(servers: servers)
        guard let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = object["mcpServers"] as? [String: Any]
        else {
            expect(false, "Claude's MCP configuration is a decodable mcpServers record")
            return
        }
        let files = entries["files"] as? [String: Any] ?? [:]
        expect(
            files["command"] as? String == "/bin/node" && files["args"] as? [String] == ["s.js"],
            "a local server carries its command and arguments in the file")
        expect(
            (files["env"] as? [String: String]) == ["API_KEY": "s3cret"],
            "and its environment, which is the only place that secret goes")
        let linear = entries["linear"] as? [String: Any] ?? [:]
        expect(
            linear["type"] as? String == "http"
                && (linear["headers"] as? [String: String]) == [
                    "Authorization": "Bearer tok-123"
                ],
            "a remote one carries the header Tinycast would have sent itself")

        let bare = ClaudeMCPLaunch.configuration(servers: [
            AIToolServer(
                handle: "open", title: "Open",
                transport: .url(
                    "https://open.example/mcp", headerName: "Authorization", headerValue: ""))
        ])
        expect(
            bare == #"{"mcpServers":{"open":{"type":"http","url":"https:\/\/open.example\/mcp"}}}"#,
            "and one that needs no credential goes to Claude with no headers at all")

        let arguments = ClaudeMCPLaunch.arguments(
            configurationPath: "/tmp/m.json", handles: ["files", "linear"], rounds: 25)
        expect(
            arguments.contains("--strict-mcp-config") && arguments.contains("/tmp/m.json")
                && arguments.contains("--permission-prompt-tool")
                && arguments.contains("stdio")
                && value(after: "--max-turns", in: arguments) == "25",
            "the flags name the file, route consent to Tinycast and cap the turn")
        let uncapped = ClaudeMCPLaunch.arguments(
            configurationPath: "/tmp/m.json", handles: ["files"], rounds: nil)
        expect(
            uncapped.contains("--mcp-config") && !uncapped.contains("--max-turns"),
            "Unlimited passes no --max-turns at all, since Claude has no cap without one")
        expect(
            !arguments.contains("--disallowedTools"),
            "and never deny every tool, which would take the MCP ones with it")
        expect(
            value(after: "--permission-mode", in: arguments) == "default",
            "the mode is pinned, so a reader's bypassPermissions default never skips the question")
        let settings =
            (value(after: "--settings", in: arguments)?.data(using: .utf8))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        expect(
            ((settings["permissions"] as? [String: Any])?["ask"] as? [String])
                == ["mcp__files", "mcp__linear"] && settings.count == 1,
            "and every armed server has an ask rule, which outranks any allow rule of the reader's")

        expect(
            ClaudeMCPLaunch.route("mcp__files__read_file")
                == AIToolServerCall(handle: "files", tool: "read_file"),
            "a wire name routes back to the server and the tool")
        expect(
            ClaudeMCPLaunch.route("mcp__files__read__file")
                == AIToolServerCall(handle: "files", tool: "read__file"),
            "the first separator is the split: a handle is letters, digits and `-`, a tool is not")
        expect(
            ClaudeMCPLaunch.route("Bash") == nil && ClaudeMCPLaunch.route("mcp__files") == nil,
            "and a name that is not one of ours routes nowhere")
    }

    /// Every other server request stays declined, so only a tool call may become a question.
    static func codexElicitationsAreOnlyToolCalls() {
        let call = CodexElicitation(
            params: [
                "serverName": .string("files"),
                "message": .string(
                    "Allow the files MCP server to run tool \u{201C}read\u{201D}?"),
                "_meta": .object([
                    "codex_approval_kind": .string("mcp_tool_call"),
                    "persist": .array([.string("session"), .string("always")])
                ])
            ])
        expect(
            call?.serverName == "files" && call?.toolName == "read" && call?.namedTool == nil,
            "a tool-call elicitation names its server, and the message names its tool")
        let named = CodexElicitation(
            params: [
                "serverName": .string("files"),
                "_meta": .object([
                    "codex_approval_kind": .string("mcp_tool_call"),
                    "tool_name": .string("write"), "tool_title": .string("Write")
                ])
            ])
        expect(
            named?.namedTool == "write" && named?.toolName == "write",
            "and `_meta.tool_name`, when sent, is the name tied to this call")
        expect(
            CodexElicitation(
                params: [
                    "serverName": .string("files"),
                    "_meta": .object(["codex_approval_kind": .string("form")])
                ]) == nil,
            "a form is not a tool call and is never asked about")
        expect(
            CodexElicitation(params: ["message": .string("hello")]) == nil,
            "and neither is an elicitation that names no server")
        expect(
            CodexElicitation.Action.accept.rawValue == "accept"
                && CodexElicitation.Action.decline.rawValue == "decline",
            "the two answers are the two the app-server honours")
    }

    private static let canUseToolFrame = """
        {"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool",\
        "tool_name":"mcp__files__read","input":{"path":"/tmp"}}}
        """

    /// The consent channel is the SDK's undocumented one; this is all of it Tinycast speaks.
    static func claudeControlFramesAnswerOneTool() {
        let frame =
            (try? JSONSerialization.jsonObject(with: Data(Self.canUseToolFrame.utf8)))
            as? [String: Any] ?? [:]
        guard let request = ClaudeControlProtocol.request(frame) else {
            expect(false, "a can_use_tool frame decodes into a request")
            return
        }
        expect(
            request.id == "r1" && request.call == AIToolServerCall(handle: "files", tool: "read"),
            "carrying the id to answer and the call to ask about")

        guard let allow = ClaudeControlProtocol.response(to: request, allowed: true, message: ""),
            let decodedAllow = try? JSONSerialization.jsonObject(with: allow) as? [String: Any],
            let allowed = (decodedAllow["response"] as? [String: Any])?["response"]
                as? [String: Any]
        else {
            expect(false, "an allow encodes as a control_response")
            return
        }
        expect(
            allowed["behavior"] as? String == "allow"
                && (allowed["updatedInput"] as? [String: Any])?["path"] as? String == "/tmp",
            "an allow hands the arguments back untouched")
        expect(
            allowed["updatedPermissions"] == nil,
            "and never a permission update, which would have the CLI write its own settings")
        expect(
            allow.last == 0x0A, "each answer is one line, because the channel is newline framed")

        guard let deny = ClaudeControlProtocol.response(to: request, allowed: false, message: "no"),
            let decodedDeny = try? JSONSerialization.jsonObject(with: deny) as? [String: Any],
            let denied = (decodedDeny["response"] as? [String: Any])?["response"] as? [String: Any]
        else {
            expect(false, "a deny encodes as a control_response")
            return
        }
        expect(
            denied["behavior"] as? String == "deny" && denied["message"] as? String == "no",
            "a deny says so, and the model reads the reason as the call's result")

        let initialize =
            #"{"type":"control_request","request_id":"r2","request":{"subtype":"initialize"}}"#
        let other =
            (try? JSONSerialization.jsonObject(with: Data(initialize.utf8))) as? [String: Any]
            ?? [:]
        expect(
            ClaudeControlProtocol.request(other) == nil
                && ClaudeControlProtocol.unsupportedRequestID(other) == "r2"
                && ClaudeControlProtocol.unsupportedRequestID(frame) == nil,
            "a subtype Tinycast does not know is no tool question, yet it is still answered")
        let error =
            ClaudeControlProtocol.error(to: "r2", message: "no")
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let errorResponse = error?["response"] as? [String: Any]
        expect(
            error?["type"] as? String == "control_response"
                && errorResponse?["subtype"] as? String == "error"
                && errorResponse?["request_id"] as? String == "r2",
            "with the SDK's error response, so the CLI stops waiting on it")
    }
}

/// Claude caches only when a request asks; a gateway never sees the field, other routes cache alone.
extension AIProviderTests {
    static func claudeRoutesMarkTheirCachedPrefix() {
        let names = ["read", "list"]
        let calls = names.map { AIToolCall(id: $0, name: $0, arguments: "{}") }
        let results = names.map { name in
            let result = AIToolResult(callID: name, content: "a", isError: false)
            return AIMessage(role: .tool, text: "", toolResult: result)
        }
        let turn = AIRequest(
            instructions: "Be brief.",
            messages: [
                AIMessage(role: .user, text: "hi"), AIMessage(role: .assistant, text: "", toolCalls: calls)
            ] + results,
            tools: names.map {
                AITool(name: $0, description: "", parameters: .object([:]), origin: "T")
            })
        let ephemeral = ["type": "ephemeral"]
        func marks(_ value: Any?) -> Int {
            switch value {
            case let object as [String: Any]:
                (object["cache_control"] as? [String: String] == ephemeral ? 1 : 0)
                    + object.values.reduce(0) { $0 + marks($1) }
            case let array as [Any]: array.reduce(0) { $0 + marks($1) }
            default: 0
            }
        }
        func body(
            _ request: AIRequest, _ provider: AIProviderKind, _ url: String, _ model: String
        ) -> [String: Any] {
            let route = AIHTTPConfiguration(provider: provider, baseURL: URL(string: url)!, model: model)
            return AIRequestBody.make(request, configuration: route)
        }

        let anthropic = body(turn, .anthropic, "https://api.anthropic.com", "claude-sonnet-5-5")
        expect(
            anthropic["cache_control"] as? [String: String] == ephemeral,
            "Anthropic's own API is asked to cache the moving tail of the conversation")
        let system = anthropic["system"] as? [[String: Any]]
        expect(
            system?.count == 1 && system?.first?["text"] as? String == "Be brief."
                && system?.first?["cache_control"] as? [String: String] == ephemeral,
            "its system prompt becomes one marked text block")
        let tools = anthropic["tools"] as? [[String: Any]] ?? []
        expect(
            tools.count == 2 && tools.last?["cache_control"] as? [String: String] == ephemeral
                && tools.first?["cache_control"] == nil,
            "and the last tool is marked, so the tools cache apart from the prompt")
        let messages = anthropic["messages"] as? [[String: Any]] ?? []
        expect(
            messages.first?["content"] as? String == "hi" && marks(messages) == 0,
            "the conversation itself goes out as it was")
        expect(marks(anthropic) == 3, "three breakpoints, under Anthropic's four")
        expect(JSONSerialization.isValidJSONObject(anthropic), "and the body is still JSON")

        let oneShot = AIRequest(instructions: "Fix the grammar.", messages: [AIMessage(role: .user, text: "hi")])
        for (provider, url, model) in [
            (AIProviderKind.anthropic, "https://api.anthropic.com", "claude-sonnet-5-5"),
            (.openRouter, "https://openrouter.ai/api/v1", "anthropic/claude-sonnet-5.5")
        ] {
            let lone = body(oneShot, provider, url, model)
            expect(
                marks(lone) == 0 && lone["cache_control"] == nil
                    && (provider != .anthropic || lone["system"] as? String == "Fix the grammar."),
                "a lone question, as a Quick Action or a summary, is sent as before on \(provider)")
        }
        let followUp = AIRequest(
            instructions: "Be brief.",
            messages: [
                AIMessage(role: .user, text: "hi"), AIMessage(role: .assistant, text: "hello"),
                AIMessage(role: .user, text: "and?")
            ])
        let chat = body(followUp, .anthropic, "https://api.anthropic.com", "claude-sonnet-5-5")
        expect(
            marks(chat) == 2 && chat["cache_control"] as? [String: String] == ephemeral
                && chat["tools"] == nil,
            "a chat's follow-up asks, marking the prompt and the moving tail with no tools to mark")

        let gateway = body(turn, .anthropic, "https://gateway.example.com", "claude-sonnet-5-5")
        expect(
            marks(gateway) == 0 && gateway["system"] as? String == "Be brief.",
            "an Anthropic preset pointed at a gateway is sent exactly as before")

        for model in ["anthropic/claude-sonnet-5.5", "~anthropic/claude-sonnet-latest"] {
            let router = body(turn, .openRouter, "https://openrouter.ai/api/v1", model)
            let routed = router["messages"] as? [[String: Any]] ?? []
            expect(
                router["cache_control"] as? [String: String] == ephemeral && marks(router) == 1
                    && routed.first?["content"] as? String == "Be brief.",
                "OpenRouter's \(model) is asked to cache, with nothing else changed")
        }
        for (provider, url, model) in [
            (AIProviderKind.openRouter, "https://openrouter.ai/api/v1", "openai/gpt-5"),
            (.openAI, "https://api.openai.com/v1", "gpt-5"),
            (.gemini, "https://generativelanguage.googleapis.com/v1beta/openai", "gemini-2.5-pro"),
            (.openAICompatible, "http://localhost:11434/v1", "anthropic/claude")
        ] {
            let other = body(turn, provider, url, model)
            expect(
                marks(other) == 0
                    && (other["messages"] as? [[String: Any]])?.first?["content"] as? String == "Be brief.",
                "\(provider) \(model) caches by itself and is sent exactly as before")
        }
    }
}

/// `removePersistentDomain` only empties the domain; cfprefsd still leaves the plist on disk.
private func discardSuite(_ name: String, _ defaults: UserDefaults) {
    defaults.removePersistentDomain(forName: name)
    UserDefaults.standard.removeSuite(named: name)
    CFPreferencesAppSynchronize(name as CFString)
    try? FileManager.default.removeItem(
        at: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences/\(name).plist"))
}

/// A fixed suite name stops cfprefsd accumulating a plist per run.
private func isolatedDefaults(_ name: String) -> UserDefaults {
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// Stands in for the Keychain: what a harness saved, read back the way a launch would.
private final class KeptVariables: @unchecked Sendable {
    var values: [InstalledAIKind: [String: String]] = [:]
}

private struct KeychainUnreadable: Error {}
