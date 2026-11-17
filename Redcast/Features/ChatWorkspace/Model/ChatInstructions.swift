import Foundation

/// Fork: a chat's system prompt with its folder's and its own instructions after the app's.
enum ChatInstructions {
    /// After the base, so the preamble stays first and a cached prefix stays the same per folder.
    static func compose(
        base: String?, folderName: String? = nil, folder: String? = nil, chat: String? = nil
    ) -> String? {
        var parts = base.map { [$0] } ?? []
        if let folder = trimmed(folder) {
            let name = folderName.flatMap(trimmed).map { " “\($0)”" } ?? ""
            parts.append("Instructions for every chat in the folder\(name):\n\(folder)")
        }
        if let chat = trimmed(chat) {
            parts.append("Additional instructions for this chat:\n\(chat)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }
}
