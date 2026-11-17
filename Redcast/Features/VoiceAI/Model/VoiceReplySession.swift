import Foundation

/// One streamed Ask reply: when its panel may open, what streams into it, and what it ends as.
struct VoiceReplySession: Sendable {
    enum Step: Equatable, Sendable {
        /// The reply is certainly an answer: the panel opens, titled by the question.
        case open(question: String?, text: String)
        case append(String)
    }

    enum Outcome: Equatable, Sendable {
        case noSpeech
        case answer(String)
        case insert(String)
        /// An INSERT that may not be typed unseen, shown in the panel for ↵.
        case review(String)

        /// What the reply says, however it is delivered; nil when nothing was said.
        var text: String? {
            switch self {
            case .noSpeech: nil
            case .answer(let text), .insert(let text), .review(let text): text
            }
        }
    }

    private let bundleID: String?
    private let hadFocusedField: Bool
    private var parser = VoiceReplyParser()
    private var mode: VoiceReplyMode?
    private(set) var question: String?
    private var body = ""
    private(set) var isPanelOpen = false

    init(bundleID: String?, hadFocusedField: Bool) {
        self.bundleID = bundleID
        self.hadFocusedField = hadFocusedField
    }

    mutating func feed(_ delta: String) -> [Step] {
        steps(for: parser.feed(delta))
    }

    mutating func finish() -> (steps: [Step], outcome: Outcome) {
        let steps = steps(for: parser.finish())
        return (steps, outcome)
    }

    private mutating func steps(for events: [VoiceReplyParser.Event]) -> [Step] {
        var steps: [Step] = []
        for event in events {
            switch event {
            case .header(let mode, let question):
                self.mode = mode
                self.question = question
            case .body(let text):
                body += text
                if isPanelOpen { steps.append(.append(text)) }
            }
            // An unnamed answer may still be the no-speech sentinel, which is never shown.
            guard !isPanelOpen, mode == .answer, question != nil || !mayBeSilence else { continue }
            isPanelOpen = true
            steps.append(.open(question: question, text: body))
        }
        return steps
    }

    private var mayBeSilence: Bool {
        VoicePrompt.noSpeech.hasPrefix(body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var outcome: Outcome {
        guard let text = VoiceTranscript.cleaned(body) else { return .noSpeech }
        guard mode == .insert else { return .answer(body.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let unseen = VoiceInsertPolicy.autoInserts(
            text, bundleID: bundleID, hadFocusedField: hadFocusedField)
        return unseen ? .insert(text) : .review(text)
    }
}
