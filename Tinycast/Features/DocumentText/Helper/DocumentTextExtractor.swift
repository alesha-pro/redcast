import AppKit
import PDFKit

/// The text helper's document reads: PDF pages, scans and images by OCR, and rich text, as JSON.
nonisolated enum DocumentTextExtractor {
    enum Failure: Error { case unreadable, unsupported }

    /// Past this no new page is started, so a long scan answers before the app's timeout does.
    static let timeBudget: Duration = .seconds(40)

    /// The helper's entry for `DocumentTextRequest`'s command line; the exit status of the read.
    static func run(_ arguments: [String]) async -> Int32 {
        guard let request = DocumentTextRequest(arguments: arguments) else { return 2 }
        do {
            let text = try await extract(request)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            try FileHandle.standardOutput.write(contentsOf: try encoder.encode(text))
            return 0
        } catch {
            return 1
        }
    }

    static func extract(_ request: DocumentTextRequest) async throws -> DocumentText {
        let url = URL(fileURLWithPath: request.path)
        switch request.kind {
        case .pdf: return try await pdf(url, pages: request.pages, budget: request.budget)
        case .image:
            let found = try await ClipboardTextExtractor.extract(at: url, isPDF: false)
            return bounded(found, recognized: true, budget: request.budget)
        case .richText: return bounded(try richText(url), recognized: false, budget: request.budget)
        case .text, .html, .binary: throw Failure.unsupported
        }
    }

    /// Whole pages until the budget would split one; only a first page too long alone is cut.
    private static func pdf(_ url: URL, pages: DocumentPageRange, budget: Int) async throws -> DocumentText {
        guard let document = PDFDocument(url: url), !document.isLocked else { throw Failure.unreadable }
        var result = DocumentText(pageCount: document.pageCount, pages: [], cut: false)
        guard let range = pages.clamped(to: document.pageCount) else { return result }
        let started = ContinuousClock.now
        var used = 0
        for number in range {
            try Task.checkCancellation()
            if !result.pages.isEmpty, ContinuousClock.now - started > timeBudget { break }
            guard let page = document.page(at: number - 1) else { continue }
            var text = DocumentText.cleaned(autoreleasepool { page.string ?? "" })
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var recognized = false
            if text.isEmpty, let image = autoreleasepool(invoking: { ClipboardTextExtractor.render(page) }) {
                text = DocumentText.cleaned(try await ClipboardTextExtractor.recognize(image))
                recognized = !text.isEmpty
            }
            let size = text.utf8.count
            guard used + size <= budget else {
                if result.pages.isEmpty {
                    let kept = DocumentText.prefix(text, bytes: budget)
                    result.pages.append(.init(number: number, text: kept, recognized: recognized))
                    result.cut = true
                }
                break
            }
            used += size
            result.pages.append(.init(number: number, text: text, recognized: recognized))
        }
        return result
    }

    /// AppKit's importers; HTML's needs the main thread and WebKit, so pages convert elsewhere.
    private static func richText(_ url: URL) throws -> String {
        let type: NSAttributedString.DocumentType =
            switch url.pathExtension.lowercased() {
            case "docx": .officeOpenXML
            case "doc": .docFormat
            case "odt": .openDocument
            case "rtfd": .rtfd
            default: .rtf
            }
        let string = try NSAttributedString(
            url: url, options: [.documentType: type], documentAttributes: nil
        ).string
        return DocumentText.cleaned(string)
    }

    private static func bounded(_ text: String, recognized: Bool, budget: Int) -> DocumentText {
        let kept = DocumentText.prefix(text, bytes: budget)
        return DocumentText(
            pageCount: 0, pages: [.init(number: 0, text: kept, recognized: recognized)],
            cut: kept.utf8.count < text.utf8.count)
    }
}
