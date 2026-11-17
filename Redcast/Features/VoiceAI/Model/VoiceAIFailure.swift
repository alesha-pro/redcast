import Foundation

enum VoiceAIFailure: LocalizedError, Equatable {
    case noSpeech
    case noDictationModel
    case noAskModel
    case dictationBusy

    var errorDescription: String? {
        switch self {
        case .noSpeech: String(localized: "No speech was recorded")
        case .noDictationModel:
            String(localized: "Choose a model for cloud transcription in Settings → Dictation.")
        case .noAskModel: String(localized: "Choose a model for Ask by Voice in Settings → AI.")
        case .dictationBusy: String(localized: "Finish the current dictation first.")
        }
    }
}
