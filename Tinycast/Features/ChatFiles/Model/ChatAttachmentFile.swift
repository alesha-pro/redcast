import Foundation

/// A sent picture or file, which lives only as bytes in its message, and the name to show it by.
struct ChatAttachmentFile: Equatable, Sendable {
    /// Finder's own ceiling on a file name, in bytes.
    private static let maxNameBytes = 255
    private static let imageExtensions = [
        "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp",
        "image/heic": "heic", "image/tiff": "tiff", "image/bmp": "bmp"
    ]

    let data: Data
    let name: String

    /// An image keeps no name of its own, so it takes `name` and its type's extension.
    init(image data: Data, mimeType: String, name: String) {
        self.data = data
        self.name = Self.fileName(name, requiredExtension: Self.imageExtensions[mimeType] ?? "png")
    }

    /// A PDF always reads as one, and a text file whose name has no extension as text.
    init(document data: Data, isPDF: Bool, name: String) {
        self.data = data
        self.name = Self.fileName(name, requiredExtension: isPDF ? "pdf" : nil)
    }

    /// One path component whatever a stored name holds, so a copy can never land outside its folder.
    private static func fileName(_ name: String, requiredExtension: String?) -> String {
        let unsafe = CharacterSet(charactersIn: "/:\\").union(.controlCharacters).union(.newlines)
        let cleaned = String(name.unicodeScalars.filter { !unsafe.contains($0) })
            .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespaces))
        var named = cleaned.isEmpty ? "Attachment" : cleaned
        let current = (named as NSString).pathExtension
        if let requiredExtension, current.lowercased() != requiredExtension {
            named += "." + requiredExtension
        } else if requiredExtension == nil, current.isEmpty {
            named += ".txt"
        }
        guard named.utf8.count > maxNameBytes else { return named }
        // From the front: the extension is what says how the file opens.
        let suffix = (named as NSString).pathExtension
        let stem = (named as NSString).deletingPathExtension
        var kept = Substring(stem)
        while kept.utf8.count + suffix.utf8.count + 1 > maxNameBytes { kept.removeLast() }
        return String(kept) + "." + suffix
    }
}
