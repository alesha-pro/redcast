import Foundation

@main
@MainActor
struct AIModelCatalogTests {
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

    static func main() {
        anAddressSaysWhoPays()
        aDeclaredBillingOverrulesTheAddress()
        routesWithoutAConnectionKeepTheirOwnReport()
        tariffsPriceEveryKindOfToken()
        aRouteOwnFigureIsNeverReplaced()
        theFillIsTheWindowOnlyWhenTheWindowIsKnown()
        theScreenshotChatIsAPlanOfAMillionTokens()
        theCostLineSaysOnlyWhatIsKnown()
        heldTokensOutrankATurnsSum()
        claudeSaysWhoPaysAndWhatIsHeld()
        print("\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    private static func connection(
        _ base: String, provider: AIProviderKind = .openAICompatible, billing: AIConnection.Billing? = nil
    ) -> AIConnection {
        var connection = AIConnection(provider: provider, baseURL: base)
        connection.billing = billing
        return connection
    }

    private static func facts(_ connection: AIConnection, _ model: String) -> AIRouteFacts {
        AIModelCatalog.facts(
            for: .api(connection: connection.id, model: model, effort: nil), connection: connection)
    }

    private static func anAddressSaysWhoPays() {
        let api = facts(connection("https://api.deepseek.com/v1"), "deepseek-flash")
        expect(api.billing == .perToken, "DeepSeek's own API bills per token")
        expect(api.rates != nil && api.window ?? 0 > 0, "and has a tariff and a window, got \(api)")
        expect(
            facts(connection("https://api.deepseek.com/"), "deepseek-flash") == api,
            "a trailing slash or a missing /v1 is the same API")

        let anthropic = facts(connection("https://api.anthropic.com", provider: .anthropic), "claude-opus-5-5")
        expect(anthropic.billing == .perToken && anthropic.rates?.base.input == 4, "Anthropic's tariff, got \(anthropic)")

        let kimi = facts(connection("https://api.kimi.com/coding/v1"), "k3.1-pro")
        expect(kimi.billing == .unbilled && kimi.rates == nil, "Kimi's coding plan has no price, got \(kimi)")

        let unknown = facts(connection("https://llm.example.com/v1"), "anything")
        expect(
            unknown == AIRouteFacts(billing: .undetermined),
            "an address nobody lists invents neither a price nor a window, got \(unknown)")

        let model = facts(connection("https://api.deepseek.com/v1"), "no-such-model")
        expect(
            model.billing == .perToken && model.rates == nil && model.window == nil,
            "a model the API's list lacks keeps the billing and has no tariff, got \(model)")

        let shared = facts(connection("https://api.minimax.io/v1"), "MiniMax-M3.1-Flash")
        expect(
            shared.billing == .undetermined && shared.rates == nil,
            "a host a plan shares with its API is never priced on a guess, got \(shared)")

        let local = facts(connection("http://localhost:1234/v1"), "gpt-5.6")
        expect(local == AIRouteFacts(billing: .unbilled), "a server on this Mac costs nothing, got \(local)")

        let router = facts(connection("https://openrouter.ai/api/v1", provider: .openRouter), "google/gemini-3.8-flash")
        expect(
            router.billing == .perToken && router.rates == nil && router.window != nil,
            "OpenRouter's reply says what it billed, and its catalog still knows the window, got \(router)")
    }

    private static func aDeclaredBillingOverrulesTheAddress() {
        let plan = facts(connection("https://api.deepseek.com/v1", billing: .plan), "deepseek-flash")
        expect(plan.billing == .unbilled && plan.rates == nil && plan.window != nil, "declared a plan, got \(plan)")

        let shared = facts(connection("https://api.minimax.io/v1", billing: .perToken), "MiniMax-M3.1-Flash")
        expect(shared.billing == .perToken && shared.rates != nil, "declared per token takes the API's tariff, got \(shared)")

        let unknown = facts(connection("https://llm.example.com/v1", billing: .perToken), "anything")
        expect(unknown.billing == .perToken && unknown.rates == nil, "and still invents none, got \(unknown)")

        var codex = connection("https://api.openai.com/v1", provider: .codexPlan, billing: .perToken)
        codex.contextWindows = ["gpt-6-sol": 272_000]
        let plan2 = facts(codex, "gpt-6-sol")
        expect(
            plan2.billing == .unbilled && plan2.window == 272_000,
            "a ChatGPT plan is never billed, and its own catalog's window wins, got \(plan2)")
    }

    private static func routesWithoutAConnectionKeepTheirOwnReport() {
        let codex = AIModelCatalog.facts(for: .codex(model: "gpt-6-sol", effort: nil), connection: nil)
        expect(codex == AIRouteFacts(billing: .unbilled), "Codex's own login shows no cost")
        let claude = AIModelCatalog.facts(for: .claude(model: "sonnet", effort: nil), connection: nil)
        expect(claude == AIRouteFacts(billing: .ownReport), "Claude's CLI reports for itself")
        expect(
            AIModelCatalog.facts(for: .appleIntelligence, connection: nil).billing == .unbilled,
            "the on-device model bills nothing")
        expect(AIModelCatalog.facts(for: nil, connection: nil).billing == .unbilled, "no model bills nothing")
        let openCode = AIModelCatalog.facts(
            for: .openCode(model: "anthropic/claude-opus-5-5", effort: nil), connection: nil)
        expect(
            openCode.billing == .ownReport && openCode.window == 1_000_000,
            "OpenCode's provider prefix names the window, got \(openCode)")
    }

    private static func tariffsPriceEveryKindOfToken() {
        let prices = AIModelRates.Prices(input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5, reasoning: 20)
        let rates = AIModelRates(
            base: prices,
            tiers: [AIModelRates.Tier(above: 1_000, prices: AIModelRates.Prices(input: 4, output: 30))])
        func near(_ left: Double, _ right: Double) -> Bool { abs(left - right) < 1e-12 }
        expect(
            near(rates.cost(input: 100, cached: 0, written: 0, output: 0, reasoning: 0), 0.0002),
            "plain input")
        expect(
            near(rates.cost(input: 100, cached: 500, written: 40, output: 50, reasoning: 10), 0.00092),
            "cache reads, cache writes inside input, and thinking inside output each take their own price")
        expect(
            near(rates.cost(input: 900, cached: 200, written: 0, output: 10, reasoning: 0), 0.0047),
            "a prompt past the tier prices the whole request there, cache included at input without its own")
        let plain = AIModelRates(base: AIModelRates.Prices(input: 1, output: 2))
        expect(
            near(plain.cost(input: 10, cached: 10, written: 5, output: 10, reasoning: 5), 0.00004),
            "a tariff with no cache or thinking price charges them as plain input and output")
    }

    private static func aRouteOwnFigureIsNeverReplaced() {
        let rates = AIModelRates(base: AIModelRates.Prices(input: 1, output: 1))
        let billed = AIUsage(inputTokens: 1_000_000, outputTokens: 0, costUSD: 0.5)
        expect(billed.priced(by: rates).costUSD == 0.5, "OpenRouter's figure stands")
        let unpriced = AIUsage(inputTokens: 1_000_000, outputTokens: 0)
        expect(unpriced.priced(by: rates).costUSD == 1, "a reply with none is priced")
        expect(unpriced.priced(by: nil).costUSD == nil, "no tariff prices nothing")
        expect(AIUsage().priced(by: rates).costUSD == nil, "no tokens price nothing")
    }

    private static func report(
        usage: AIUsage?, known: Int? = nil, history: Int = 2_000
    ) -> ChatContextReport {
        ChatContextReport(
            modelTitle: "", historyBytes: history, budget: 100_000, sentMessages: 4, totalMessages: 4,
            stagedFiles: 0, stagedBytes: 0, usage: usage, knownWindow: known, systemPrompt: false,
            webSearch: false, toolServers: 0)
    }

    private static func theFillIsTheWindowOnlyWhenTheWindowIsKnown() {
        let usage = AIUsage(inputTokens: 11_249, outputTokens: 341)
        let unknown = report(usage: usage)
        expect(
            !unknown.fillsWindow && abs(unknown.fill - 0.02) < 1e-9,
            "with no window the fill is the history budget, and says so, got \(unknown.fill)")
        let known = report(usage: usage, known: 1_000_000)
        expect(known.fillsWindow && abs(known.fill - 0.01159) < 1e-9, "the catalog's window, got \(known.fill)")
        let reported = report(
            usage: AIUsage(inputTokens: 1_000, outputTokens: 0, contextWindow: 2_000), known: 1_000_000)
        expect(reported.window == 2_000 && reported.fill == 0.5, "the route's own window outranks the catalog's")
        let noTokens = report(usage: nil, known: 1_000_000)
        expect(!noTokens.fillsWindow, "a window with no tokens to weigh shows the history budget")
        let fresh = report(usage: nil, known: 1_000_000, history: 0)
        expect(fresh.fillsWindow && fresh.fill == 0, "an empty chat is an empty window")
        let zero = report(usage: AIUsage(inputTokens: 5, outputTokens: 0, contextWindow: 0))
        expect(!zero.fillsWindow && zero.window == nil, "a window of 0 is no window")
    }

    /// The chat that opened this: Z.AI's coding address behind the OpenAI preset.
    private static func theScreenshotChatIsAPlanOfAMillionTokens() {
        let route = facts(connection("https://api.z.ai/api/coding/paas/v4", provider: .openAI), "glm-5.3-flash")
        expect(route.billing == .unbilled && route.rates == nil, "the coding plan has no price, got \(route)")
        expect(route.window == 1_000_000, "and a million tokens of window, got \(route)")
        let line = ChatCostLine.line(
            facts: route, runsOwnRuntime: false, replies: [AIUsage(inputTokens: 11_249, outputTokens: 341)])
        expect(line == .hidden, "so its card states no cost, got \(line)")
        let paid = facts(connection("https://api.z.ai/api/paas/v4"), "glm-5.3-flash")
        expect(paid.billing == .perToken && paid.rates != nil, "the same model on the paid API has a tariff, got \(paid)")
    }

    private static func theCostLineSaysOnlyWhatIsKnown() {
        let rates = AIModelRates(base: AIModelRates.Prices(input: 1, output: 1))
        let priced = AIUsage(inputTokens: 1, outputTokens: 1, costUSD: 0.25)
        let unpriced = AIUsage(inputTokens: 1, outputTokens: 1)
        let perToken = AIRouteFacts(billing: .perToken, rates: rates)
        func line(_ facts: AIRouteFacts, _ replies: [AIUsage], own: Bool = false) -> ChatCostLine {
            ChatCostLine.line(facts: facts, runsOwnRuntime: own, replies: replies)
        }
        expect(
            line(perToken, [priced, priced, unpriced])
                == .spent(0.5, estimated: true, pricedReplies: 2, replies: 3),
            "the sum of what was priced, and how much of the chat that is")
        expect(line(perToken, []) == .hidden, "nothing asked, nothing spent")
        expect(line(perToken, [unpriced]) == .notYetPriced, "a reply from before the tariff")
        expect(line(AIRouteFacts(billing: .perToken), [unpriced]) == .noTariff, "no tariff is said aloud")
        expect(line(AIRouteFacts(billing: .undetermined), [unpriced]) == .noTariff, "and so is no idea who pays")
        expect(
            line(AIRouteFacts(billing: .perToken), [priced])
                == .spent(0.25, estimated: false, pricedReplies: 1, replies: 1),
            "what a route billed is not an estimate")
        expect(line(AIRouteFacts(billing: .unbilled), [priced]) == .hidden, "a plan never shows one")
        expect(line(perToken, [priced], own: true) == .hidden, "ACP does not say who pays")
        expect(line(AIRouteFacts(billing: .ownReport), [unpriced]) == .hidden, "a CLI silent on a plan stays silent")
        expect(
            line(AIRouteFacts(billing: .ownReport), [priced])
                == .spent(0.25, estimated: true, pricedReplies: 1, replies: 1),
            "a CLI's own figure is its estimate")
    }

    private static func heldTokensOutrankATurnsSum() {
        // Five rounds of 400 k cached add up to 2 M; the window never held more than 400 k.
        let usage = AIUsage(
            inputTokens: 44_273, outputTokens: 11_707, cachedInputTokens: 1_945_088, contextWindow: 258_400,
            heldTokens: 120_000)
        expect(usage.contextTokens == 120_000, "what is held is the context")
        expect(usage.totalTokens == 55_980, "and the turn's counts stay what was spent")
        var plain = usage
        plain.heldTokens = nil
        expect(plain.contextTokens == 2_001_068, "a route with no such figure adds its counts up, as before")
    }

    private static func claudeSaysWhoPaysAndWhatIsHeld() {
        func frame(_ text: String) -> InstalledAIStreamFrame {
            InstalledAIStreamDecoder.decode(Data(text.utf8), kind: .claude)
        }
        expect(
            frame(#"{"type":"system","subtype":"init","apiKeySource":"none"}"#).runsOnPlan == true,
            "no key is the subscription")
        expect(
            frame(#"{"type":"system","subtype":"init","apiKeySource":"ANTHROPIC_API_KEY"}"#).runsOnPlan == false,
            "a key is billed")
        expect(frame(#"{"type":"system","subtype":"init"}"#).runsOnPlan == nil, "silence decides nothing")
        let call = """
            {"type":"assistant","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":200,\
            "cache_creation_input_tokens":30,"output_tokens":5}}}
            """
        expect(frame(call).heldTokens == 245, "one call's prompt and reply")
        let side = """
            {"type":"assistant","parent_tool_use_id":"t","message":{"usage":{"input_tokens":9}}}
            """
        expect(frame(side).heldTokens == nil, "a sub-agent's call is not this conversation's")
    }
}
