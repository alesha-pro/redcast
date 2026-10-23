import Foundation

/// What `web_fetch` and `read_page` read: one bounded fetch, a page or document in parts.
nonisolated enum WebPageReader {
    struct Read: Sendable, Equatable {
        let text: String
        /// The addresses the returned part links to, which an agent's scope may then let it open.
        let links: [URL]
    }

    /// Model-facing, like every tool failure.
    struct Failure: Error, Sendable, Equatable {
        let message: String
    }

    /// What a PDF read may carry, like `read_file`'s, under the tool's own 28 KB.
    static let documentBudget = 24 * 1_024
    /// A word processor's text, paged into parts here as a page's is.
    static let richTextBudget = 1_048_576

    @concurrent
    static func read(
        _ url: URL, part: Int = 1, pages: String? = nil, tool: String,
        documents: DocumentTextService = .bundled,
        session makeSession: @Sendable () -> URLSession = { WebPageReader.fetchSession() }
    ) async -> Result<Read, Failure> {
        let session = makeSession()
        // Also ends what is left of a body cut at its limit.
        defer { session.invalidateAndCancel() }
        var spool: Spool?
        defer { spool?.remove() }
        do {
            var request = URLRequest(url: url)
            request.setValue(
                "text/html,application/xhtml+xml,application/pdf;q=0.9,text/plain;q=0.8,*/*;q=0.5",
                forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            let http = response as? HTTPURLResponse
            if let http, !(200..<300).contains(http.statusCode) {
                return .failure(Failure(message: "\(url.absoluteString) answered HTTP \(http.statusCode)."))
            }
            let type = http?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            var document = Self.documentType(of: type, url: url)
            if document == nil, let label = Self.binaryLabel(of: type) {
                return .failure(Failure(message: Self.notReadable(url, label)))
            }
            var body = Data()
            var truncated = false
            if let document { spool = try Spool(suffix: document.suffix) }
            for try await byte in bytes {
                if let document, let spool {
                    guard try spool.append(byte) else {
                        return .failure(Failure(message: Self.tooLarge(url, kind: document.kind)))
                    }
                    continue
                }
                body.append(byte)
                if body.count == 5, body.starts(with: Data("%PDF-".utf8)) {
                    document = (.pdf, "pdf")
                    let file = try Spool(suffix: "pdf")
                    for byte in body { _ = try file.append(byte) }
                    spool = file
                    body = Data()
                } else if body.count == Self.sniffBytes, Self.isBinary(body, type: type) {
                    return .failure(Failure(message: Self.notReadable(url, Self.label(of: type))))
                } else if body.count >= WebPageTool.maxPageBytes {
                    truncated = true
                    break
                }
            }
            if let document, let spool {
                return await Self.document(
                    spool, kind: document.kind, url: url, part: part, pages: pages, tool: tool, documents: documents)
            }
            if Self.isBinary(body, type: type) {
                return .failure(Failure(message: Self.notReadable(url, Self.label(of: type))))
            }
            return page(body, type: type, url: url, base: response.url ?? url, part: part, tool: tool, truncated: truncated)
        } catch {
            return .failure(Failure(message: "Fetching \(url.absoluteString) failed: \(error.localizedDescription)"))
        }
    }

    /// HTML as Markdown in parts, other text as it came; a page its scripts would fill says so.
    static func page(
        _ data: Data, type: String, url: URL, base: URL, part: Int, tool: String, truncated: Bool
    ) -> Result<Read, Failure> {
        let text = decoded(data, type: type)
        let head = text.prefix(1_024).lowercased()
        let isHTML = type.contains("html") || head.contains("<html") || head.contains("<!doctype html")
        let page = isHTML ? WebPageMarkdown.page(from: text, base: base) : WebPageMarkdown.page(fromText: text)
        guard page.weight > 0 else {
            let message = isHTML
                ? WebPageTool.unreadable(url, title: page.title, summary: page.summary)
                : "\(url.absoluteString) returned no text."
            return .failure(Failure(message: message))
        }
        let parts = WebPageParts(page)
        guard let body = WebPageTool.body(of: parts, part: part, title: page.title, tool: tool, truncated: truncated)
        else { return .failure(Failure(message: WebPageTool.pastEnd(part, of: parts.count, url: url))) }
        let noted = isHTML ? WebPageTool.noted(body.text, weight: page.weight) : body.text
        return .success(Read(text: noted, links: body.links))
    }

    private static func document(
        _ spool: Spool, kind: DocumentKind, url: URL, part: Int, pages: String?, tool: String,
        documents: DocumentTextService
    ) async -> Result<Read, Failure> {
        let range: DocumentPageRange
        if let pages {
            guard let parsed = DocumentPageRange(pages) else {
                return .failure(Failure(message: "pages takes a page, a range or an open range: \"3\", \"3-5\", \"8-\"."))
            }
            range = parsed
        } else {
            range = .all
        }
        do {
            try spool.flush()
        } catch {
            return .failure(Failure(message: "Saving \(url.absoluteString) for reading failed."))
        }
        let budget = kind == .richText ? richTextBudget : documentBudget
        let request = DocumentTextRequest(path: spool.path, kind: kind, pages: range, budget: budget)
        switch await documents.read(request) {
        case .success(let text) where kind == .richText:
            return richText(text, url: url, part: part, tool: tool)
        case .success(let text):
            let answer = kind == .pdf
                ? text.pdfAnswer(for: url.absoluteString, asked: range) : text.imageAnswer(for: url.absoluteString)
            return .success(Read(text: answer, links: []))
        case .failure(let failure):
            return .failure(Failure(message: failure.message.replacingOccurrences(
                of: (spool.path as NSString).lastPathComponent, with: url.absoluteString)))
        }
    }

    /// A word processor's text in parts, as a page's; nothing in it links anywhere.
    private static func richText(_ text: DocumentText, url: URL, part: Int, tool: String) -> Result<Read, Failure> {
        let page = WebPageMarkdown.page(fromText: text.pages.map(\.text).joined(separator: "\n"))
        guard page.weight > 0 else { return .failure(Failure(message: "\(url.absoluteString) holds no text.")) }
        let parts = WebPageParts(page)
        guard let body = WebPageTool.body(of: parts, part: part, title: "", tool: tool, truncated: false) else {
            return .failure(Failure(message: WebPageTool.pastEnd(part, of: parts.count, url: url)))
        }
        var answer = "A document, as plain text.\n" + body.text
        if text.cut, part == parts.count {
            answer += "\n\n[The document goes on past the \(richTextBudget / 1_048_576) MB of text a read takes.]"
        }
        return .success(Read(text: answer, links: []))
    }

    /// Word processors' types, and the name a file of each needs for AppKit to import it.
    private static let richTypes = [
        ("officedocument.wordprocessingml", "docx"), ("application/msword", "doc"), ("application/rtf", "rtf"),
        ("application/x-rtf", "rtf"), ("text/rtf", "rtf"), ("opendocument.text", "odt")
    ]

    /// A PDF, an image or a word processor's file goes to the document helper; nil reads a page.
    private static func documentType(of type: String, url: URL) -> (kind: DocumentKind, suffix: String)? {
        if type.contains("application/pdf") { return (.pdf, "pdf") }
        if type.hasPrefix("image/"), !type.contains("svg") { return (.image, "") }
        if let rich = richTypes.first(where: { type.contains($0.0) }) { return (.richText, rich.1) }
        // A download's type says nothing, so its name decides.
        let generic = ["", "octet-stream", "download", "application/zip", "application/x-zip"]
        guard generic.contains(where: { $0.isEmpty ? type.isEmpty : type.contains($0) }) else { return nil }
        let suffix = url.pathExtension.lowercased()
        if suffix == "pdf" { return (.pdf, suffix) }
        return ["docx", "doc", "rtf", "odt"].contains(suffix) ? (.richText, suffix) : nil
    }

    /// Archives, media, fonts, programs, spreadsheets and slides, which no read takes, by their type.
    private static func binaryLabel(of type: String) -> String? {
        let families = ["audio/", "video/", "font/", "model/", "application/font", "application/x-font"]
        let names = [
            "zip", "gzip", "x-tar", "x-7z", "rar", "x-bzip", "x-xz", "diskimage", "java-archive", "msdownload",
            "x-executable", "x-mach", "wasm", "ms-excel", "ms-powerpoint", "spreadsheetml", "presentationml",
            "opendocument.spreadsheet", "opendocument.presentation", "x-iso9660", "android.package", "sqlite"
        ]
        let known = families.contains { type.hasPrefix($0) } || names.contains { type.contains($0) }
        return known ? label(of: type) : nil
    }

    /// Enough of a body to tell text from bytes, as `DocumentKind` tells a file's.
    static let sniffBytes = 8_192

    /// A NUL early on, in a body not sent as UTF-16 or UTF-32, whose text holds NULs.
    static func isBinary(_ body: Data, type: String) -> Bool {
        let head = body.prefix(sniffBytes)
        guard head.contains(0) else { return false }
        let wide = type.contains("utf-16") || type.contains("utf-32") || head.starts(with: [0xFF, 0xFE])
            || head.starts(with: [0xFE, 0xFF])
        return !wide
    }

    private static func label(of type: String) -> String {
        let bare = type.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return bare.isEmpty || bare.contains("octet-stream") ? "binary data" : bare
    }

    private static func notReadable(_ url: URL, _ label: String) -> String {
        "\(url.absoluteString) is not a page or a document a read takes (\(label))."
    }

    private static func tooLarge(_ url: URL, kind: DocumentKind) -> String {
        "\(url.absoluteString) is a \(DocumentTextService.label(kind)) larger than "
            + "\(WebPageTool.maxPDFBytes / 1_048_576) MB, more than a read takes."
    }

    /// The declared charset, else UTF-8 forgiving a cut character, else the page's, else Latin-1.
    static func decoded(_ data: Data, type: String) -> String {
        if let encoding = encoding(named: parameter("charset", in: type)), encoding != .utf8,
            let text = String(data: data, encoding: encoding)
        {
            return text
        }
        for drop in 0...min(3, data.count) {
            if let text = String(data: data.dropLast(drop), encoding: .utf8) { return text }
        }
        let head = (String(bytes: data.prefix(4_096), encoding: .isoLatin1) ?? "").lowercased()
        if let range = head.range(of: #"charset\s*=\s*["']?([a-z0-9_\-]+)"#, options: .regularExpression),
            let name = head[range].split(whereSeparator: { "=\"' ".contains($0) }).last,
            let encoding = encoding(named: String(name)), encoding != .utf8,
            let text = String(data: data, encoding: encoding)
        {
            return text
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static func parameter(_ name: String, in type: String) -> String? {
        type.split(separator: ";").lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(name + "=") }
            .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
    }

    private static func encoding(named name: String?) -> String.Encoding? {
        guard let name, !name.isEmpty else { return nil }
        let value = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard value != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(value))
    }

    /// Per read: its redirects keep their cookies, and no jar or pool links reads or outlives one.
    static func fetchSession(_ configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration, delegate: PageRedirects(), delegateQueue: nil)
    }
}

/// A PDF, an image or a document on its way to the helper, in chunks; gone when the read ends.
private nonisolated final class Spool {
    /// Named with its type's suffix, as AppKit picks a word processor's importer by it.
    let path: String
    private var handle: FileHandle?
    private var buffer: [UInt8] = []
    private var size = 0

    /// Created at once, readable by this user alone.
    init(suffix: String) throws {
        let name = "tinycast-web-\(UUID().uuidString)" + (suffix.isEmpty ? "" : "." + suffix)
        path = FileManager.default.temporaryDirectory.appendingPathComponent(name).path
        guard FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        do {
            handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        } catch {
            try? FileManager.default.removeItem(atPath: path)
            throw error
        }
        buffer.reserveCapacity(65_536)
    }

    /// False once past `WebPageTool.maxPDFBytes`; the last chunk is written when the stream ends.
    func append(_ byte: UInt8) throws -> Bool {
        buffer.append(byte)
        size += 1
        guard size <= WebPageTool.maxPDFBytes else { return false }
        if buffer.count >= 65_536 { try flush() }
        return true
    }

    func flush() throws {
        guard let handle, !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    func remove() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// Only the first address was checked, so a redirect may not leave the open web for a local host.
nonisolated final class PageRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let follows = WebPageScope.follows(from: task.originalRequest?.url, to: request.url)
        completionHandler(follows ? request : nil)
    }
}
