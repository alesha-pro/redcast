import AppKit
import CoreText
import Foundation
import PDFKit

/// Documents read for agents: kinds, page ranges, the helper's reads and the service that runs it.
@main
@MainActor
struct DocumentTextTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() async {
        // The harness is its own helper, as ClipboardTextHelper is the app's.
        if CommandLine.arguments.count > 1, CommandLine.arguments[1] == DocumentTextRequest.command {
            exit(await DocumentTextExtractor.run(Array(CommandLine.arguments.dropFirst())))
        }
        // A helper that swells, as an importer fed a document built to inflate would.
        if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "swell" {
            let block = UnsafeMutableRawPointer.allocate(byteCount: 512 << 20, alignment: 4_096)
            block.initializeMemory(as: UInt8.self, repeating: 1, count: 512 << 20)
            try? await Task.sleep(for: .seconds(10))
            exit(block.load(as: UInt8.self) == 1 ? 0 : 1)
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinycast-document-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        kindsComeFromNamesAndBytes()
        pageRangesParse()
        requestsSurviveTheCommandLine()
        textIsCleanedAndCutOnScalars()
        answersSayHowToReadOn()
        await pdfPagesReadInOrderWithinTheBudget(folder)
        await richTextAndImagesRead(folder)
        await theServiceRunsOneHelperPerRead(folder)
        await archivesAreSizedBeforeTheyOpen(folder)

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Model

    static func kindsComeFromNamesAndBytes() {
        let none = Data("plain words".utf8)
        expect(DocumentKind.of(path: "/a/Report.PDF", head: none) == .pdf, "a PDF by its extension")
        expect(DocumentKind.of(path: "/a/report", head: Data("%PDF-1.7".utf8)) == .pdf, "or by its first bytes")
        expect(DocumentKind.of(path: "/a/scan.HEIC", head: none) == .image, "an image by its extension")
        expect(
            DocumentKind.of(path: "/a/photo", head: Data([0x89, 0x50, 0x4E, 0x47, 0x0D])) == .image
                && DocumentKind.of(path: "/a/photo", head: Data([0xFF, 0xD8, 0xFF, 0xE0])) == .image,
            "or by a PNG's or JPEG's signature")
        for name in ["a.docx", "a.doc", "a.rtf", "a.rtfd", "a.odt"] {
            expect(DocumentKind.of(path: name, head: none) == .richText, "\(name) is rich text")
        }
        expect(DocumentKind.of(path: "a.htm", head: none) == .html, "a saved page is HTML")
        expect(DocumentKind.of(path: "a.swift", head: none) == .text, "source is text")
        expect(DocumentKind.of(path: "a.bin", head: Data([0x41, 0x00, 0x42])) == .binary, "a NUL byte is binary")
        expect(DocumentKind.pdf.needsHelper && !DocumentKind.text.needsHelper, "only documents need the helper")
        expect(DocumentKind.pdf.maxFileBytes > DocumentKind.text.maxFileBytes, "a PDF may be larger than text")
    }

    static func pageRangesParse() {
        expect(DocumentPageRange("3") == DocumentPageRange(first: 3, last: 3), "one page")
        expect(DocumentPageRange(" 3 - 5 ") == DocumentPageRange(first: 3, last: 5), "a range, spaces allowed")
        expect(DocumentPageRange("3–5") == DocumentPageRange(first: 3, last: 5), "an en dash reads as a dash")
        expect(DocumentPageRange("8-") == DocumentPageRange(first: 8, last: nil), "an open range")
        for bad in ["0", "-3", "5-3", "x", "", "3-x", "1.5"] {
            expect(DocumentPageRange(bad) == nil, "\"\(bad)\" is no range")
        }
        expect(DocumentPageRange.all.clamped(to: 200) == 1...DocumentPageRange.maxPages, "a read stops at 50 pages")
        expect(DocumentPageRange("190-")?.clamped(to: 200) == 190...200, "an open range ends at the last page")
        expect(DocumentPageRange("5-9")?.clamped(to: 7) == 5...7, "a range past the end is cut there")
        expect(DocumentPageRange("9")?.clamped(to: 7) == .some(nil), "a start past the end reads nothing")
        expect(DocumentPageRange.from(13) == "13-", "how to read on")
    }

    static func requestsSurviveTheCommandLine() {
        let request = DocumentTextRequest(
            path: "/tmp/a b.pdf", kind: .pdf, pages: DocumentPageRange(first: 2, last: nil), budget: 900)
        expect(
            request.arguments == ["document", "pdf", "/tmp/a b.pdf", "2", "0", "900"],
            "a request is one argument per field, got \(request.arguments)")
        expect(DocumentTextRequest(arguments: request.arguments) == request, "and reads back unchanged")
        expect(DocumentTextRequest(arguments: ["image", "/tmp/a.png"]) == nil, "the clipboard's own commands stay its")
        expect(
            DocumentTextRequest(arguments: ["document", "spreadsheet", "/a", "1", "0", "9"]) == nil
                && DocumentTextRequest(arguments: ["document", "pdf", "/a", "1", "0", "0"]) == nil,
            "an unknown kind or no budget is refused")
    }

    static func textIsCleanedAndCutOnScalars() {
        expect(
            DocumentText.cleaned("a\r\nb\rc\u{2028}d\u{0B}e\u{0007}f\u{FFFC}g\tz") == "a\nb\nc\nd\nef" + "g\tz",
            "line breaks become newlines, controls and object marks go, tabs stay")
        let text = "абв"
        expect(DocumentText.prefix(text, bytes: 3) == "а", "a cut never splits a scalar")
        expect(DocumentText.prefix(text, bytes: 100) == text, "short text is whole")
    }

    static func answersSayHowToReadOn() {
        let read = DocumentText(
            pageCount: 9,
            pages: [.init(number: 3, text: "Three", recognized: false), .init(number: 4, text: "", recognized: true)],
            cut: false)
        let answer = read.pdfAnswer(for: "/r.pdf", asked: DocumentPageRange(first: 3, last: nil))
        expect(answer.hasPrefix("/r.pdf: PDF, 9 pages. Pages 3–4:"), "the answer names the pages it holds")
        expect(answer.contains("[Page 3]\nThree") && answer.contains("[Page 4, scanned"), "each page is headed")
        expect(answer.contains("(no text)"), "an empty page says so")
        expect(answer.hasSuffix("Read on with pages \"5-\".]"), "and how to read on, got \(answer)")
        let past = DocumentText(pageCount: 2, pages: [], cut: false)
        expect(
            past.pdfAnswer(for: "/r.pdf", asked: DocumentPageRange(first: 5, last: nil))
                == "/r.pdf has 2 pages; page 5 is past the end.",
            "a start past the end says how many there are")
        let cut = DocumentText(pageCount: 1, pages: [.init(number: 1, text: "Long", recognized: false)], cut: true)
        expect(cut.pdfAnswer(for: "/r.pdf", asked: .all).contains("Page 1 is cut here"), "a cut page says so")
        expect(
            DocumentText(pageCount: 0, pages: [.init(number: 0, text: " ", recognized: true)], cut: false)
                .imageAnswer(for: "/i.png") == "No text was recognized in /i.png.",
            "an image without text says so")
    }

    // MARK: - The helper's reads

    static func pdfPagesReadInOrderWithinTheBudget(_ folder: URL) async {
        let url = folder.appendingPathComponent("report.pdf")
        makePDF(at: url, pages: ["FIRST PAGE ALPHA", "SECOND PAGE BRAVO", nil, "FOURTH PAGE DELTA"])
        func read(_ pages: String?, budget: Int = 24_576) async -> DocumentText? {
            let range = pages.flatMap(DocumentPageRange.init) ?? .all
            return try? await DocumentTextExtractor.extract(
                DocumentTextRequest(path: url.path, kind: .pdf, pages: range, budget: budget))
        }
        let all = await read(nil)
        expect(all?.pageCount == 4 && all?.pages.map(\.number) == [1, 2, 3, 4], "every page in order")
        expect(all?.pages.first?.text == "FIRST PAGE ALPHA" && all?.pages[0].recognized == false, "a text layer reads")
        expect(
            all?.pages[2].recognized == true && all?.pages[2].text.contains("7391") == true,
            "a page with no text layer is recognized by OCR, got \(all?.pages[2].text ?? "nothing")")
        let some = await read("2-3")
        expect(some?.pages.map(\.number) == [2, 3], "a range reads only its pages")
        let fit = await read("1-", budget: 20)
        expect(fit?.pages.map(\.number) == [1] && fit?.cut == false, "whole pages until the budget would split one")
        let tight = await read("2", budget: 6)
        expect(tight?.pages.first?.text == "SECOND" && tight?.cut == true, "only a first page too long alone is cut")
        let past = await read("9-")
        expect(past?.pageCount == 4 && past?.pages.isEmpty == true, "a start past the end reads nothing")
        let locked = folder.appendingPathComponent("broken.pdf")
        try? Data("%PDF-1.7 not really".utf8).write(to: locked)
        let broken = try? await DocumentTextExtractor.extract(
            DocumentTextRequest(path: locked.path, kind: .pdf, budget: 100))
        expect(broken == nil, "a PDF PDFKit cannot open fails")
    }

    static func richTextAndImagesRead(_ folder: URL) async {
        let text = "Quarterly notes\nRevenue grew in the north.\nПривет, отчёт."
        let documents: [(String, NSAttributedString.DocumentType)] = [
            ("notes.docx", .officeOpenXML), ("notes.rtf", .rtf), ("notes.odt", .openDocument),
            ("notes.doc", .docFormat)
        ]
        for (name, type) in documents {
            let url = folder.appendingPathComponent(name)
            let string = NSAttributedString(string: text)
            let data = try? string.data(
                from: NSRange(location: 0, length: string.length), documentAttributes: [.documentType: type])
            try? data?.write(to: url)
            let read = try? await DocumentTextExtractor.extract(
                DocumentTextRequest(path: url.path, kind: .richText, budget: 4_096))
            expect(
                read?.pages.first?.text.contains("Revenue grew in the north.") == true
                    && read?.pages.first?.text.contains("Привет, отчёт.") == true,
                "\(name) reads as text, got \(read?.pages.first?.text ?? "nothing")")
            expect(read?.pageCount == 0 && read?.cut == false, "\(name) has no pages and fits")
        }
        let short = try? await DocumentTextExtractor.extract(
            DocumentTextRequest(path: folder.appendingPathComponent("notes.rtf").path, kind: .richText, budget: 9))
        expect(short?.pages.first?.text == "Quarterly" && short?.cut == true, "a document past its budget is cut")

        let image = folder.appendingPathComponent("receipt.png")
        writePNG(makeImage("ALPINE RECEIPT 7391"), to: image)
        let seen = try? await DocumentTextExtractor.extract(
            DocumentTextRequest(path: image.path, kind: .image, budget: 4_096))
        expect(seen?.pages.first?.text.contains("7391") == true && seen?.pages.first?.recognized == true, "OCR")
        let html = try? await DocumentTextExtractor.extract(
            DocumentTextRequest(path: image.path, kind: .html, budget: 4_096))
        expect(html == nil, "a page is never the helper's to read")
    }

    // MARK: - The service

    static func theServiceRunsOneHelperPerRead(_ folder: URL) async {
        let me = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let pdf = folder.appendingPathComponent("report.pdf")
        let service = DocumentTextService(executable: me)
        let range = DocumentPageRange(first: 2, last: 2)
        switch await service.read(DocumentTextRequest(path: pdf.path, kind: .pdf, pages: range, budget: 4_096)) {
        case .success(let text):
            expect(text.pages.map(\.text) == ["SECOND PAGE BRAVO"], "the helper answers as JSON over its pipe")
        case .failure(let failure):
            expect(false, "the helper answers, got \(failure.message)")
        }
        let missing = await DocumentTextService(executable: folder.appendingPathComponent("none"))
            .read(DocumentTextRequest(path: pdf.path, kind: .pdf, budget: 10))
        expect(missing.failure?.message.contains("document reader is missing") == true, "no helper, said so")
        let unreadable = await service.read(
            DocumentTextRequest(path: folder.appendingPathComponent("broken.pdf").path, kind: .pdf, budget: 10))
        expect(
            unreadable.failure?.message == "broken.pdf could not be read as a PDF.",
            "a failed read names the file, got \(unreadable.failure?.message ?? "success")")

        let slow = script(in: folder, named: "slow", body: "sleep 5")
        var timed = DocumentTextService(executable: slow)
        timed.timeout = .seconds(1)
        let started = ContinuousClock.now
        let late = await timed.read(DocumentTextRequest(path: pdf.path, kind: .pdf, budget: 10))
        expect(late.failure?.message.contains("longer than 1 s") == true, "a read past its time is stopped")
        expect(ContinuousClock.now - started < .seconds(3), "at its time")

        let flood = script(in: folder, named: "flood", body: "yes aaaaaaaaaaaa | head -c 400000")
        let flooded = await DocumentTextService(executable: flood)
            .read(DocumentTextRequest(path: pdf.path, kind: .pdf, budget: 1_000))
        expect(flooded.failure != nil, "an answer past its bound is dropped, not held")

        let stopped = Task { await DocumentTextService(executable: slow).read(
            DocumentTextRequest(path: pdf.path, kind: .pdf, budget: 10)) }
        try? await Task.sleep(for: .milliseconds(300))
        let stopAt = ContinuousClock.now
        stopped.cancel()
        let cancelled = await stopped.value
        expect(cancelled.failure?.message.contains("was stopped") == true, "Stop ends a read")
        expect(ContinuousClock.now - stopAt < .seconds(2), "at once, and the helper with it")
    }

    /// A DOCX or ODT that would unpack past what a read holds is refused before AppKit opens it.
    static func archivesAreSizedBeforeTheyOpen(_ folder: URL) async {
        func zip(_ entries: [(String, UInt32)], count: UInt16? = nil) -> Data {
            var directory = Data()
            for (name, size) in entries {
                var entry = [UInt8](repeating: 0, count: 46)
                entry.replaceSubrange(0..<4, with: [0x50, 0x4B, 0x01, 0x02])
                for shift in 0..<4 { entry[24 + shift] = UInt8(truncatingIfNeeded: size >> (8 * UInt32(shift))) }
                entry[28] = UInt8(name.utf8.count & 0xFF)
                entry[29] = UInt8(name.utf8.count >> 8)
                directory.append(contentsOf: entry)
                directory.append(contentsOf: Array(name.utf8))
            }
            var end = [UInt8](repeating: 0, count: 22)
            end.replaceSubrange(0..<4, with: [0x50, 0x4B, 0x05, 0x06])
            let total = count ?? UInt16(entries.count)
            end[8] = UInt8(total & 0xFF)
            end[9] = UInt8(total >> 8)
            end[10] = end[8]
            end[11] = end[9]
            for shift in 0..<4 { end[12 + shift] = UInt8(truncatingIfNeeded: directory.count >> (8 * shift)) }
            return directory + Data(end)
        }
        func verdict(_ data: Data) -> DocumentArchive.Verdict {
            DocumentArchive.verdict(tail: data.suffix(Int(DocumentArchive.tailBytes)), fileSize: UInt64(data.count)) {
                Int($0) + $1 <= data.count ? data.subdata(in: Int($0)..<(Int($0) + $1)) : nil
            }
        }
        let small = zip([("[Content_Types].xml", 1_000), ("word/document.xml", 40_000), ("word/media/a.png", 900_000)])
        expect(
            verdict(small) == .readable(.init(markup: 41_000, total: 941_000, entries: 3)),
            "a document's sizes come from its directory, got \(verdict(small))")
        expect(verdict(zip([("word/document.xml", 300 << 20)])) == .tooLarge, "300 MB of XML is refused")
        expect(
            verdict(zip((1...9).map { ("word/media/\($0).png", 30 << 20) })) == .tooLarge,
            "and so are 270 MB of pictures")
        expect(verdict(zip([("word/document.xml", 10)], count: 0xFFFF)) == .tooLarge, "ZIP64 is not read")
        expect(
            verdict(zip([("word/document.xml", 10)], count: 0)) == .readable(.init(markup: 10, total: 10, entries: 1)),
            "the end record's count is not trusted")
        expect(verdict(Data("not a zip at all".utf8)) == .notArchive, "text has no directory")

        let string = NSAttributedString(string: String(repeating: "Minutes of the meeting.\n", count: 200))
        let real = try? string.data(
            from: NSRange(location: 0, length: string.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        let docx = folder.appendingPathComponent("real.docx")
        try? real?.write(to: docx)
        guard case .readable(let sizes) = DocumentTextService.archive(at: docx.path) else {
            return expect(false, "AppKit's own DOCX reads as an archive")
        }
        expect(sizes.markup > 4_000 && sizes.entries >= 3, "with its XML counted, got \(sizes)")

        let bomb = folder.appendingPathComponent("bomb.docx")
        try? zip([("word/document.xml", 300 << 20)]).write(to: bomb)
        let me = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let refused = await DocumentTextService(executable: me)
            .read(DocumentTextRequest(path: bomb.path, kind: .richText, budget: 4_096))
        expect(
            refused.failure?.message == "bomb.docx unpacks to more than a read can hold, so it was not opened.",
            "the service refuses it without starting the helper, got \(refused)")

        let swelling = script(in: folder, named: "swelling", body: "exec \"\(me.path)\" swell")
        var guarded = DocumentTextService(executable: swelling)
        guarded.memoryLimit = 64 << 20
        let started = ContinuousClock.now
        let swollen = await guarded.read(DocumentTextRequest(path: docx.path, kind: .richText, budget: 4_096))
        expect(
            swollen.failure?.message == "Reading real.docx needed more than 64 MB and was stopped.",
            "a helper past its memory is ended, got \(swollen)")
        expect(ContinuousClock.now - started < .seconds(5), "long before its time runs out")
    }

    // MARK: - Fixtures

    static func script(in folder: URL, named name: String, body: String) -> URL {
        let url = folder.appendingPathComponent(name)
        try? "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// One page a line of text; nil is a scanned page, an image with no text layer.
    static func makePDF(at url: URL, pages: [String?]) {
        var box = CGRect(x: 0, y: 0, width: 1000, height: 300)
        let context = CGContext(consumer: CGDataConsumer(url: url as CFURL)!, mediaBox: &box, nil)!
        for page in pages {
            context.beginPDFPage(nil)
            if let page {
                draw(page, in: context)
            } else {
                context.draw(makeImage("SCANNED PAGE 7391"), in: box)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    static func makeImage(_ text: String) -> CGImage {
        let context = CGContext(
            data: nil, width: 1000, height: 300, bitsPerComponent: 8, bytesPerRow: 4000,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 300))
        draw(text, in: context)
        return context.makeImage()!
    }

    static func writePNG(_ image: CGImage, to url: URL) {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        expect(CGImageDestinationFinalize(destination), "write \(url.lastPathComponent)")
    }

    static func draw(_ text: String, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 48, nil)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: 40, y: 150)
        CTLineDraw(line, context)
    }
}

extension Result {
    var failure: Failure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}
