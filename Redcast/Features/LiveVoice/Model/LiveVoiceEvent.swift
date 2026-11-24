import Foundation

/// What a live voice provider reports, in the one vocabulary `LiveVoiceSession` understands.
enum LiveVoiceEvent: Equatable, Sendable {
    case ready
    case userStartedSpeaking
    case userStoppedSpeaking
    /// The provider began a reply of its own accord, before any of it has arrived.
    case replyStarted
    /// A piece of what the user said, as text; it trails the audio and may arrive mid-reply.
    case heard(String)
    /// The reply's speech, PCM16 mono at the wire's `outputRate`, and the item it belongs to.
    case audio(Data, item: String)
    case said(String)
    case toolCall(AIToolCall)
    /// The provider cut its own reply, so whatever is still queued must not be played.
    case interrupted
    /// The provider cancelled in-flight tool calls (e.g., user spoke over them).
    case toolCallsCancelled([String])
    /// Server-side token allowing a fresh WebSocket to continue this conversation.
    case resumptionHandle(String)
    /// The provider will close this socket soon; reconnect cleanly before it drops.
    case sessionExpiring(String?)
    case replyEnded(LiveVoiceUsage?)
    case failed(String)
}

/// What one reply cost, as the provider counted it.
struct LiveVoiceUsage: Equatable, Sendable {
    var input = 0
    var cached = 0
    var output = 0
}

/// What a session opens with, the same for every provider.
struct LiveVoiceSetup: Sendable {
    var instructions: String
    var tools: [AITool]
    /// Nil keeps the provider's own default voice.
    var voice: String?
    /// The language the user mostly speaks, as an ISO 639-1 code: a hint for the transcript only.
    var language: String?
    /// Server-side session token sent when reconnecting a resumable provider.
    var resumptionHandle: String?

    init(
        instructions: String, tools: [AITool], voice: String?, language: String? = nil,
        resumptionHandle: String? = nil
    ) {
        self.instructions = instructions
        self.tools = tools
        self.voice = voice
        self.language = language
        self.resumptionHandle = resumptionHandle
    }
}

/// A picture sent into the conversation, and where its pixels sit on the Mac's screens.
struct LiveVoiceImage: Sendable {
    let jpeg: Data
    let frame: LiveVoiceFrame
}
