import Foundation

/// How a file is read: as text in the app, or by the helper's PDF, OCR or rich-text readers.
nonisolated enum DocumentKind: String, Codable, CaseIterable, Sendable {
    case text
    case html
    case pdf
    case image
    /// DOCX, DOC, RTF, RTFD and ODT, which AppKit's text system imports.
    case richText
    /// A NUL byte early on and no reader for it.
    case binary

    private static let images: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"
    ]
    private static let richTexts: Set<String> = ["docx", "doc", "rtf", "rtfd", "odt"]
    private static let pages: Set<String> = ["html", "htm", "xhtml"]

    /// By extension, then by the first bytes, so a PDF or a photo saved without one still reads.
    static func of(path: String, head: Data) -> DocumentKind {
        let suffix = (path as NSString).pathExtension.lowercased()
        if suffix == "pdf" || head.starts(with: Data("%PDF-".utf8)) { return .pdf }
        if images.contains(suffix) { return .image }
        if richTexts.contains(suffix) { return .richText }
        if pages.contains(suffix) { return .html }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) || head.starts(with: [0xFF, 0xD8, 0xFF]) {
            return .image
        }
        return head.prefix(8_192).contains(0) ? .binary : .text
    }

    /// PDFKit maps a PDF rather than loading it; OCR keeps `ClipboardTextExtractor`'s own limit.
    var maxFileBytes: Int {
        switch self {
        case .pdf: 256 * 1_048_576
        case .richText: 64 * 1_048_576
        case .image: 32_000_000
        case .text, .html, .binary: 10 * 1_048_576
        }
    }

    /// Read in a child process, so PDFKit, Vision and AppKit's importers never load into the app.
    var needsHelper: Bool {
        switch self {
        case .pdf, .image, .richText: true
        case .text, .html, .binary: false
        }
    }
}
