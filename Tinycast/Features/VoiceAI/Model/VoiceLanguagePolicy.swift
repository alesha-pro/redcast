import Foundation

/// The languages cloud dictation is told the speaker uses, as `DictationLanguage` raw values.
enum VoiceLanguagePolicy {
    static let limit = 3

    /// The Mac's own languages that dictation knows, in its order, then English, at most `limit`.
    static func defaults(preferred: [String]) -> [String] {
        let english = Locale(identifier: "en")
        var chosen: [String] = []
        for identifier in preferred {
            guard let code = Locale.Language(identifier: identifier).languageCode?.identifier,
                let name = english.localizedString(forLanguageCode: code),
                let language = DictationLanguage.allCases.first(where: {
                    $0.displayName(locale: english) == name
                }),
                !chosen.contains(language.rawValue)
            else { continue }
            chosen.append(language.rawValue)
            if chosen.count == limit { break }
        }
        // Technical terms come in English whatever the Mac's language, and a Russian Mac lists no other.
        if !chosen.isEmpty, chosen.count < limit, !chosen.contains(DictationLanguage.english.rawValue) {
            chosen.append(DictationLanguage.english.rawValue)
        }
        return chosen
    }

    /// Known languages only, each once, at most `limit`, in the order they were chosen.
    static func normalized(_ stored: [String]) -> [String] {
        var chosen: [String] = []
        for raw in stored where DictationLanguage(rawValue: raw) != nil && !chosen.contains(raw) {
            guard chosen.count < limit else { break }
            chosen.append(raw)
        }
        return chosen
    }

    /// One more at the end, or one fewer; a language past the limit is not added.
    static func toggled(_ language: String, in chosen: [String]) -> [String] {
        if chosen.contains(language) { return chosen.filter { $0 != language } }
        return normalized(chosen + [language])
    }
}
