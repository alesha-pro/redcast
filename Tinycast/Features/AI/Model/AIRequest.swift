import Foundation

/// An attached picture, already encoded for the wire; every provider takes it as a data URL.
struct AIImage: Equatable, Hashable, Sendable {
    let data: Data
    let mimeType: String

    var dataURL: String { "data:\(mimeType);base64,\(data.base64EncodedString())" }
}

/// A file a route reads natively; a text-ish file never becomes one, it inlines as text instead.
struct AIDocument: Equatable, Hashable, Sendable {
    let data: Data
    let mimeType: String
    /// On the wire, unlike an image's: a model shown three PDFs needs to tell them apart.
    let name: String

    var dataURL: String { "data:\(mimeType);base64,\(data.base64EncodedString())" }
}

/// Recorded speech for a route that hears it; OpenAI-compatible bodies send it as `input_audio`.
struct AIAudio: Equatable, Hashable, Sendable {
    let data: Data
    /// The wire's container name: `wav`, `mp3`, `flac`…
    let format: String
}

/// Requests cap near 25 MB and a data URL costs a third more, so the ceiling lives here.
enum AIAttachmentBudget {
    static let maxCount = 6
    static let maxBytes = 10 * 1_048_576
    /// Inlined text rides the newest turn, which is never trimmed, so it is capped before staging.
    static let maxInlinedTextBytes = 32 * 1_024

    /// Counted jointly: two independent ceilings would let six of each through.
    static func admits(images: [AIImage], documents: [AIDocument], addingBytes bytes: Int) -> Bool {
        let used =
            images.reduce(0) { $0 + $1.data.count }
            + documents.reduce(0) { $0 + $1.data.count }
        return images.count + documents.count < maxCount && used + bytes <= maxBytes
    }

    /// The longest leading run that fits, for a turn assembled by any route but the composer.
    /// Images fill first, so a picture is never dropped in favour of a document behind it.
    static func bounded(
        _ images: [AIImage], _ documents: [AIDocument]
    )
        -> (images: [AIImage], documents: [AIDocument])
    {
        var total = 0
        var count = 0
        let keptImages = images.prefix { image in
            guard count < maxCount, total + image.data.count <= maxBytes else { return false }
            total += image.data.count
            count += 1
            return true
        }
        let keptDocuments = documents.prefix { document in
            guard count < maxCount, total + document.data.count <= maxBytes else { return false }
            total += document.data.count
            count += 1
            return true
        }
        return (Array(keptImages), Array(keptDocuments))
    }
}

struct AIMessage: Equatable, Sendable {
    enum Role: String, Equatable, Sendable {
        case system
        case user
        case assistant
        case tool
    }

    let role: Role
    let text: String
    let images: [AIImage]
    /// Only a PDF ever lands here: a text-ish file is inlined into `text` before any transport.
    let documents: [AIDocument]
    let audio: [AIAudio]
    /// Assistant only: the calls this turn asked for, alongside whatever text came with them.
    let toolCalls: [AIToolCall]
    /// Tool only: the answer to one of them.
    let toolResult: AIToolResult?
    // Fork: assistant only, what the reply reasoned, for a route that must be sent it again.
    let reasoning: AIReasoningReplay?

    init(
        role: Role, text: String, images: [AIImage] = [], documents: [AIDocument] = [],
        audio: [AIAudio] = [], toolCalls: [AIToolCall] = [], toolResult: AIToolResult? = nil,
        reasoning: AIReasoningReplay? = nil
    ) {
        self.role = role
        self.text = text
        self.images = images
        self.documents = documents
        self.audio = audio
        self.toolCalls = toolCalls
        self.toolResult = toolResult
        self.reasoning = reasoning
    }
}

// Fork: a reply's reasoning, sent back only to the model that wrote it; see agent-harness.md.
struct AIReasoningReplay: Equatable, Sendable {
    /// How the stream carried it, which is how it goes back.
    enum Form: String, Codable, Sendable {
        /// DeepSeek's field, which Qwen, Kimi, MiniMax and GLM copy.
        case reasoningContent = "reasoning_content"
        /// OpenRouter's and vLLM's plain field.
        case reasoning
        /// `<think>…</think>` leading the answer.
        case thinkTags
        /// `reasoning_details`: OpenRouter's entries, and MiniMax's split output.
        case details
        /// Anthropic's `thinking` and `redacted_thinking` blocks.
        case blocks
    }

    /// The host and model that wrote it; no other is ever sent it.
    let route: String
    let model: String
    /// Nil when the reply only signed its calls.
    let form: Form?
    let text: String
    /// Entries sent back byte for byte and in order; never stored, so they never outlive the turn.
    let items: [JSONValue]
    /// Read back from the chat's history, as a later turn sends it.
    let isStored: Bool

    init(
        route: String, model: String, form: Form?, text: String, items: [JSONValue] = [],
        isStored: Bool = false
    ) {
        self.route = route
        self.model = model
        self.form = form
        self.text = text
        self.items = items
        self.isStored = isStored
    }

    /// What the chat keeps for a later turn: the text alone, since an opaque entry is the turn's.
    var stored: AIReasoningReplay? {
        guard let form, form != .blocks, !text.isEmpty else { return nil }
        return AIReasoningReplay(route: route, model: model, form: form, text: text, isStored: true)
    }

    /// Anthropic signs a block over everything sent before it, so an edit there voids it.
    var bindsPrefix: Bool {
        !items.isEmpty
            && (route == "api.anthropic.com"
                || route == "openrouter.ai" && model.drop(while: { $0 == "~" }).hasPrefix("anthropic/"))
    }

    var unbound: AIReasoningReplay {
        AIReasoningReplay(route: route, model: model, form: form, text: text, isStored: isStored)
    }
}

struct AIRequest: Equatable, Sendable {
    static let defaultMaxOutputTokens = 4_096

    let conversationID: UUID?
    let instructions: String?
    let messages: [AIMessage]
    let maxOutputTokens: Int
    /// Lets the model search the web; each route has its own switch for that, all off by default.
    let webSearch: Bool
    /// Empty for every route that cannot call one, so a transport need not ask whether it may.
    let tools: [AITool]
    // Fork: an extension's `creativity` on OpenAI's 0–2 scale; nil keeps each route's own default.
    let temperature: Double?
    // Fork: an agent round's cap, sent on both shapes; nil leaves the OpenAI shape the route's own.
    let outputCap: Int?

    init(
        instructions: String? = nil, messages: [AIMessage],
        maxOutputTokens: Int = defaultMaxOutputTokens,
        webSearch: Bool = false, tools: [AITool] = [], conversationID: UUID? = nil,
        temperature: Double? = nil, outputCap: Int? = nil
    ) {
        self.conversationID = conversationID
        self.instructions = instructions
        self.messages = messages
        self.maxOutputTokens = maxOutputTokens
        self.webSearch = webSearch
        self.tools = tools
        self.temperature = temperature
        self.outputCap = outputCap
    }

    /// The same turn carried forward, armed with what the loop wrapping it may call.
    func continuing(with messages: [AIMessage], tools: [AITool]) -> AIRequest {
        AIRequest(
            instructions: instructions, messages: messages, maxOutputTokens: maxOutputTokens,
            webSearch: webSearch, tools: tools, conversationID: conversationID,
            temperature: temperature, outputCap: outputCap)
    }

    /// Fork: the same request with its own output cap, or none.
    func capped(at tokens: Int?) -> AIRequest {
        AIRequest(
            instructions: instructions, messages: messages, maxOutputTokens: maxOutputTokens,
            webSearch: webSearch, tools: tools, conversationID: conversationID,
            temperature: temperature, outputCap: tokens)
    }
}

struct AIUsage: Equatable, Sendable {
    var inputTokens: Int?
    var outputTokens: Int?
    /// Prompt tokens served from a cache, counted outside `inputTokens`; a cache write is input.
    var cachedInputTokens: Int?
    /// The part of `outputTokens` the model spent thinking.
    var reasoningTokens: Int?
    /// The model's whole window, where a route reports it; only Claude's CLI does.
    var contextWindow: Int?
    var costUSD: Double?

    var totalTokens: Int? {
        guard let inputTokens, let outputTokens else { return nil }
        return inputTokens + outputTokens
    }

    /// What the conversation now occupies in the window: every prompt token plus the reply.
    var contextTokens: Int? {
        totalTokens.map { $0 + (cachedInputTokens ?? 0) }
    }
}

enum AIStreamEvent: Equatable, Sendable {
    case text(String)
    case thinking
    /// Reasoning text, where a route shares it; never answer text, and never sent back as context.
    case reasoning(String)
    case searching(String?)
    case searched(String?)
    /// What a transport emits; the loop consumes it and never passes it on to the transcript.
    case toolCallRequested(AIToolCall)
    /// What the loop emits in its place, already carrying what a row has to show.
    case toolCall(id: String, origin: String, title: String)
    case toolResult(id: String, isError: Bool)
    /// Fork: an ACP call's diff or output, replacing what its row showed before.
    case toolOutput(id: String, content: ChatToolContent)
    /// Fork: a reply's reasoning for a tool loop to send back with its calls; never shown.
    case reasoningReplay(AIReasoningReplay)
    /// Fork: the output cap cut the reply, so a call in it may have lost the end of its arguments.
    case outputLimit
    case usage(AIUsage)
    case finished
}

// Fork: a failure a run may outlast; it reads exactly as the failure it stands for.
struct AIProviderRecoverableError: LocalizedError, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Busy, rate-limited or a dropped connection: the same request may pass later.
        case transient(retryAfter: Duration?)
        /// The prompt no longer fits the model's window.
        case overflow
    }

    let kind: Kind
    let message: String

    var errorDescription: String? { message }
}

enum AIProviderError: LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case responseFailed(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .responseFailed(let message): return message
        case .malformedResponse:
            return String(localized: "The provider returned malformed streaming data.")
        }
    }
}
