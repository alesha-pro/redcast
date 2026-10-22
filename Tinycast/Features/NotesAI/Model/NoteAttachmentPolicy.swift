import Foundation

/// A picked note rides the next message as the text file it is, refused rather than cut.
enum NoteAttachmentPolicy {
    enum Verdict: Equatable, Sendable {
        case document(AIDocument)
        case tooLong
    }

    static func document(
        title: String, source: String, limit: Int = AIAttachmentBudget.maxInlinedTextBytes
    ) -> Verdict {
        let data = Data(source.utf8)
        guard data.count <= limit else { return .tooLong }
        let name = title + ".md"
        return .document(
            AIDocument(data: data, mimeType: AIAttachmentPolicy.mimeType(forFileName: name), name: name))
    }
}
