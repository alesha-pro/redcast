import Foundation

/// A named prompt a cloud dictation passes through before it is typed.
struct VoiceMode: Codable, Hashable, Identifiable, Sendable {
    static let maxNameLength = 40
    static let maxInstructionsLength = 2_000

    let id: UUID
    var name: String
    var instructions: String

    init(id: UUID = UUID(), name: String, instructions: String) {
        self.id = id
        self.name = name
        self.instructions = instructions
    }

    /// Both trimmed and within their limits; anything else is not saved.
    var isComplete: Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.count <= Self.maxNameLength && !instructions.isEmpty
            && instructions.count <= Self.maxInstructionsLength
    }
}

/// The shipped modes; their names follow the app's language, so a built-in name is never stored.
enum VoiceModeCatalog {
    static let translateToEnglish = UUID(uuidString: "3C6E2B14-8F0A-4D57-9E21-7A4B5C6D7E01")!
    static let polish = UUID(uuidString: "3C6E2B14-8F0A-4D57-9E21-7A4B5C6D7E02")!
    static let asMessage = UUID(uuidString: "3C6E2B14-8F0A-4D57-9E21-7A4B5C6D7E03")!

    static var builtIns: [VoiceMode] {
        [
            VoiceMode(
                id: translateToEnglish, name: String(localized: "Translate to English"),
                instructions: """
                    Translate the dictation into natural, fluent English, whatever language it was \
                    spoken in. Keep names, code, commands and technical terms as they are.
                    """),
            VoiceMode(
                id: polish, name: String(localized: "Polish"),
                instructions: """
                    Write the dictation as clean, well-formed text in the language it was spoken in: \
                    fix grammar and word order, drop fillers and false starts, and keep the speaker's \
                    meaning, tone and wording wherever it already works. Add nothing.
                    """),
            VoiceMode(
                id: asMessage, name: String(localized: "As a message"),
                instructions: """
                    Write the dictation as a short chat message in the language it was spoken in: \
                    clear, friendly sentences, short paragraphs if it runs long, no greeting or \
                    sign-off the speaker did not say, and no Markdown.
                    """)
        ]
    }

    static func isBuiltIn(_ id: UUID) -> Bool {
        id == translateToEnglish || id == polish || id == asMessage
    }

    static func builtIn(_ id: UUID) -> VoiceMode? {
        builtIns.first { $0.id == id }
    }

    static func symbol(for id: UUID) -> String {
        switch id {
        case translateToEnglish: "globe"
        case polish: "sparkles"
        case asMessage: "bubble.left"
        default: "text.bubble"
        }
    }
}
