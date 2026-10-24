import Foundation

/// What Send to AI hands Quick AI or a new chat for each kind of row.
@main
@MainActor
struct SendToAITests {
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

    static let cap = 1_024

    static func make(_ source: SendToAISource) -> SendToAIPayload? {
        SendToAIPayload.make(for: source, maxNoteBytes: cap)
    }

    static func main() {
        shortTextIsQuoted()
        longOrMultilineTextIsAttached()
        coloursAreQuotedWithTheirHex()
        imagesAndFilesGoThroughTheComposersReader()
        foldersAreNamedNotAttached()
        dictationsAreQuotedOrAttached()
        nothingToSendIsNil()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func shortTextIsQuoted() {
        let payload = make(.text("  the meeting moved to Thursday \n"))
        expect(payload?.kind == .text, "a text entry is text")
        expect(payload?.draft == "\"the meeting moved to Thursday\" ", "a short line is quoted, trimmed")
        expect(payload?.files.isEmpty == true && payload?.notes.isEmpty == true, "and attaches nothing")
        let edge = String(repeating: "a", count: SendToAIPayload.maxQuotedLength)
        expect(make(.text(edge))?.notes.isEmpty == true, "a line at the limit is still quoted")
    }

    static func longOrMultilineTextIsAttached() {
        let lines = make(.text("first line\nsecond line"))
        expect(lines?.draft == "", "a multi-line clip leaves the one-line composer empty")
        expect(
            lines?.notes == [.init(name: "Clipboard.txt", text: "first line\nsecond line")],
            "and is staged as a text file")
        let long = String(repeating: "word ", count: 60)
        expect(make(.text(long))?.notes.count == 1, "a line past the limit is attached")
        let huge = String(repeating: "é", count: 5_000)
        let note = make(.text(huge))?.notes.first
        expect(note.map { $0.text.utf8.count <= cap } == true, "an attached clip fits the composer's cap")
        expect(note?.text.hasSuffix(SendToAIPayload.cutMarker) == true, "and says it was cut")
        expect(
            note.map { $0.text.dropLast(SendToAIPayload.cutMarker.count).allSatisfy { $0 == "é" } } == true,
            "cut on a character, never inside one")
    }

    static func coloursAreQuotedWithTheirHex() {
        let hex = make(.text("#f23d32"))
        expect(hex?.kind == .color, "a colour entry is a colour")
        expect(hex?.draft == "#f23d32 ", "a hex colour is quoted as copied, once")
        let rgb = make(.text("rgb(242, 61, 50)"))
        expect(rgb?.draft == "rgb(242, 61, 50) (#F23D32) ", "another notation carries its hex")
        expect(rgb?.notes.isEmpty == true && rgb?.files.isEmpty == true, "a colour attaches nothing")
    }

    static func imagesAndFilesGoThroughTheComposersReader() {
        let image = make(.image(path: "/clips/images/a.png"))
        expect(image?.kind == .image, "an image entry is an image")
        expect(image?.files == ["/clips/images/a.png"], "its saved file is attached")
        expect(image?.draft == "", "with nothing quoted")
        let file = make(.file(path: "/Users/me/report.pdf", isDirectory: false))
        expect(file?.kind == .file, "a file entry or result is a file")
        expect(file?.files == ["/Users/me/report.pdf"], "attached by path, refusals left to the composer")
    }

    static func foldersAreNamedNotAttached() {
        let folder = make(.file(path: "/Users/me/Projects", isDirectory: true))
        expect(folder?.kind == .folder, "a folder is a folder")
        expect(folder?.files.isEmpty == true, "a folder is never attached")
        expect(folder?.draft == "\"/Users/me/Projects\" ", "its path is quoted instead")
    }

    static func dictationsAreQuotedOrAttached() {
        let short = make(.dictation(text: "Remind me to call Anna", request: nil))
        expect(short?.kind == .dictation, "a dictation is a dictation")
        expect(short?.draft == "\"Remind me to call Anna\" ", "a short dictation is quoted")
        let long = make(.dictation(text: "Point one.\nPoint two.", request: nil))
        expect(long?.notes.first?.name == "Dictation.txt", "a long one is attached as Dictation.txt")
        let ask = make(.dictation(text: "It is 21 °C.", request: "What is the weather?"))
        expect(ask?.draft == "", "an Ask by Voice entry quotes nothing")
        expect(
            ask?.notes == [
                .init(name: "Voice question.txt", text: "Question: What is the weather?\n\nAnswer: It is 21 °C.")
            ],
            "and goes with the question it answered")
        expect(
            make(.dictation(text: "Hi", request: "  "))?.draft == "\"Hi\" ",
            "an empty question is no question")
    }

    static func nothingToSendIsNil() {
        expect(make(.text(" \n\t")) == nil, "a blank clip has nothing to send")
        expect(make(.image(path: "")) == nil, "an image with no file has nothing to send")
        expect(make(.file(path: "", isDirectory: false)) == nil, "a file with no path has nothing to send")
        expect(make(.dictation(text: "", request: "What?")) == nil, "a failed dictation has no text yet")
    }
}
