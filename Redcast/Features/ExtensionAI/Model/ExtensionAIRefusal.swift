import Foundation

/// Why an extension's `AI.ask` was refused; the message reaches the extension as its error.
enum ExtensionAIRefusal: LocalizedError, Equatable, Sendable {
    case featureOff
    case aiOff
    case unattended
    case denied
    case unanswered
    case noModel
    case emptyPrompt
    case promptTooLong(kilobytes: Int)
    case rateLimited(seconds: Int)

    var errorDescription: String? {
        switch self {
        case .featureOff:
            return String(localized: "Extensions can't use AI. Turn it on in Settings \u{2192} Extensions.")
        case .aiOff:
            return String(localized: "AI is off. Turn it on in Settings \u{2192} AI to let extensions use it.")
        case .unattended:
            return String(
                localized: "Extensions can use AI only in a command you open or from a menu-bar item you click.")
        case .denied:
            return String(
                localized: """
                    This extension isn't allowed to use AI. You can change this in Settings \u{2192} \
                    Extensions.
                    """)
        case .unanswered:
            return String(
                localized: "This extension can use AI once you allow it. It will ask again next time.")
        case .noModel:
            return String(localized: "Choose a model for extensions in Settings \u{2192} Extensions.")
        case .emptyPrompt:
            return String(localized: "The prompt is empty.")
        case .promptTooLong(let kilobytes):
            let limit = ExtensionAIPolicy.maxPromptBytes / 1_024
            return String(
                localized: "The prompt is too long: \(kilobytes) KB, where the limit is \(limit) KB.")
        case .rateLimited(let seconds):
            return String(
                localized: """
                    This extension reached its AI limit of 10 requests a minute and 100 an hour. Try \
                    again in \(seconds) s.
                    """)
        }
    }
}
