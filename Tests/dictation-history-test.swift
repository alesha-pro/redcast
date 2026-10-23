import Foundation

/// Dictation History's line format, its file and its search, on a scratch folder of its own.
@main
@MainActor
struct DictationHistoryTests {
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

    static func main() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "dictation-history-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        aLineReadsBackAsWritten()
        aLineThisBuildWroteStillReads()
        aLaterBuildsLineReadsAndSurvives()
        unreadableLinesAreSkipped()
        theEntryKeepsItsTextBounded()
        retentionSpans()
        voiceRepliesAreKeptOnlyOnRequest()
        try appendsLoadNewestFirst(in: folder)
        try anAppendTrimsWhatAgedOut(in: folder)
        try aLoadDropsWhatAgedOutSinceTheLastWrite(in: folder)
        try aCutShortLineNeverSwallowsTheNext(in: folder)
        try aCorruptLineIsToleratedAndKeptUntilItAges(in: folder)
        try deleteRemovesOnlyItsLine(in: folder)
        try clearAndOffRemoveTheFile(in: folder)
        searchFindsEveryWordAnywhere()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func entry(
        _ text: String, ago seconds: TimeInterval = 0, kind: DictationHistoryEntry.Kind = .dictation,
        transcript: String? = nil, mode: String? = nil, app: String? = nil
    ) -> DictationHistoryEntry {
        DictationHistoryEntry(
            date: now.addingTimeInterval(-seconds), kind: kind, text: text, transcript: transcript,
            mode: mode, engine: .cloud, model: "google/gemini-3.1-flash-lite", appName: app,
            bundleID: "com.apple.TextEdit", duration: 4.2)
    }

    static func lines(_ data: Data) -> [Data.SubSequence] {
        data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
    }

    static func lineCount(_ url: URL) -> Int {
        lines((try? Data(contentsOf: url)) ?? Data()).count
    }

    static func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - Line format

    static func aLineReadsBackAsWritten() {
        let written = entry(
            "Привет,\tмир\nВторая строка «цитата» \"quotes\" / slash", transcript: "привет мир",
            mode: "Polish", app: "TextEdit")
        let line = written.line
        expect(line.hasSuffix("\n") && line.dropLast().allSatisfy { $0 != "\n" }, "a line is one line")
        expect(line.hasPrefix("\(Int64(now.timeIntervalSince1970))\t"), "the date's seconds lead the line")
        let read = DictationHistoryEntry(line: Data(line.dropLast().utf8)[...])
        expect(read == written, "every field reads back as written, tabs and newlines in the text included")
        let fractional = DictationHistoryEntry(
            date: now.addingTimeInterval(0.75), kind: .dictation, text: "a")
        expect(fractional.date == now, "the date keeps whole seconds, as the line does")
    }

    /// Pinned: a line this build writes must read the same in every later build.
    static func aLineThisBuildWroteStillReads() {
        let id = UUID(uuidString: "6B1F3C2A-9D4E-4F5A-8B7C-1D2E3F4A5B6C")!
        let pinned =
            #"1790000000\#t{"app":"Mail","bundleID":"com.apple.mail","duration":12.5,"engine":"cloud","#
            + #""id":"6B1F3C2A-9D4E-4F5A-8B7C-1D2E3F4A5B6C","kind":"dictation","mode":"As a message","#
            + #""model":"voxtral","text":"I'll be there at ten.","transcript":"буду в десять"}"#
        let read = DictationHistoryEntry(line: Data(pinned.utf8)[...])
        let expected = DictationHistoryEntry(
            id: id, date: now, kind: .dictation, text: "I'll be there at ten.", transcript: "буду в десять",
            mode: "As a message", engine: .cloud, model: "voxtral", appName: "Mail",
            bundleID: "com.apple.mail", duration: 12.5)
        expect(read == expected, "the first build's line reads field for field")
        expect(expected.line == pinned + "\n", "and this build still writes it byte for byte")
        let bare = #"1790000000\#t{"id":"6B1F3C2A-9D4E-4F5A-8B7C-1D2E3F4A5B6C","text":"hi"}"#
        let minimal = DictationHistoryEntry(line: Data(bare.utf8)[...])
        expect(
            minimal?.kind == .dictation && minimal?.engine == nil && minimal?.duration == nil
                && minimal?.appName == nil,
            "a line with only an id and text reads, every other field none")
    }

    static func aLaterBuildsLineReadsAndSurvives() {
        let later =
            #"1790000000\#t{"id":"6B1F3C2A-9D4E-4F5A-8B7C-1D2E3F4A5B6C","kind":"meeting","engine":"satellite","#
            + #""text":"from the future","speakers":["A","B"],"duration":-3}"#
        let read = DictationHistoryEntry(line: Data(later.utf8)[...])
        expect(read?.text == "from the future", "a later build's line reads, its extra fields ignored")
        expect(read?.kind == .dictation, "an unknown kind reads as a dictation rather than hiding")
        expect(
            read?.engine == nil && read?.duration == nil, "an unknown engine and a bad duration read as none")
        let data = Data((later + "\n" + entry("now").line).utf8)
        let kept = DictationHistoryEntry.kept(data, since: now.addingTimeInterval(-60))
        expect(
            String(data: kept, encoding: .utf8)?.hasPrefix(later + "\n") == true,
            "a trim keeps a later build's line byte for byte")
    }

    static func unreadableLinesAreSkipped() {
        let good = entry("good").line
        let data = Data(
            ("garbage without a tab\n" + "12x\t{}\n" + "1790000000\tnot json\n"
                + #"1790000000\#t{"text":"no id"}"# + "\n"
                + #"1790000000\#t{"id":"6B1F3C2A-9D4E-4F5A-8B7C-1D2E3F4A5B6C"}"# + "\n"
                + good).utf8)
        let read = DictationHistoryEntry.entries(in: data)
        expect(read.map(\.text) == ["good"], "lines without a date, JSON, an id or a text are skipped")
        let kept = String(data: DictationHistoryEntry.kept(data, since: nil), encoding: .utf8) ?? ""
        expect(
            !kept.contains("garbage") && !kept.contains("12x") && kept.contains("not json"),
            "a rewrite drops lines with no date and keeps dated ones it cannot read")
    }

    static func theEntryKeepsItsTextBounded() {
        let long = String(repeating: "a", count: DictationHistoryEntry.maxTextLength + 50)
        let capped = DictationHistoryEntry(date: now, kind: .dictation, text: long, transcript: long + "b")
        expect(capped.text.count == DictationHistoryEntry.maxTextLength, "text keeps its head within the cap")
        expect(capped.transcript == nil, "a transcript the cap makes equal to the text is dropped")
        let same = DictationHistoryEntry(date: now, kind: .dictation, text: "same", transcript: "same")
        expect(same.transcript == nil, "a transcript equal to the text is not kept twice")
        let empty = DictationHistoryEntry(date: now, kind: .dictation, text: "x", transcript: "")
        expect(empty.transcript == nil, "an empty transcript is none")
    }

    static func retentionSpans() {
        expect(DictationHistoryRetention.standard == .month, "thirty days by default")
        expect(!DictationHistoryRetention.off.keepsHistory, "Off keeps nothing")
        expect(DictationHistoryRetention.forever.cutoff(now: now) == nil, "Forever keeps everything")
        expect(
            DictationHistoryRetention.week.cutoff(now: now) == now.addingTimeInterval(-7 * 86_400),
            "a span keeps its days back from now")
        expect(
            DictationHistoryRetention.off.cutoff(now: now) == .distantFuture, "Off's cutoff passes everything"
        )
        expect(
            DictationHistoryRetention.allCases.map(\.rawValue) == [0, 1, 7, 30, 90, -1],
            "the stored values stay what the first build wrote")
        expect(
            DictationHistoryRetention.allCases.allSatisfy { !$0.title.isEmpty }, "every span has a title")
    }

    static func voiceRepliesAreKeptOnlyOnRequest() {
        let kinds: [DictationHistoryEntry.Kind] = [.dictation, .ask, .edit]
        expect(
            kinds.map { $0.isKept(voiceReplies: false) } == [true, false, false],
            "with the switch off, only dictations are kept, never an answer or an edited selection")
        expect(kinds.allSatisfy { $0.isKept(voiceReplies: true) }, "with it on, Ask and edits are kept too")
    }

    // MARK: - The file

    static func scratch(_ folder: URL, _ name: String) -> URL {
        folder.appending(path: name + ".jsonl", directoryHint: .notDirectory)
    }

    static func appendsLoadNewestFirst(in folder: URL) throws {
        let url = scratch(folder, "order")
        expect(
            DictationHistoryFile.load(retention: .month, now: now, at: url).isEmpty, "no file is no history")
        expect(!FileManager.default.fileExists(atPath: url.path), "and reading creates none")
        for (index, text) in ["one", "two", "three"].enumerated() {
            DictationHistoryFile.append(
                entry(text, ago: TimeInterval(30 - index)), retention: .month, to: url)
        }
        let loaded = DictationHistoryFile.load(retention: .month, now: now, at: url)
        expect(loaded.map(\.text) == ["three", "two", "one"], "entries load newest first")
        expect(lineCount(url) == 3, "one line per append")
        DictationHistoryFile.append(entry("never"), retention: .off, to: url)
        expect(lineCount(url) == 3, "Off appends nothing")
    }

    static func anAppendTrimsWhatAgedOut(in folder: URL) throws {
        let url = scratch(folder, "trim")
        let day: TimeInterval = 86_400
        DictationHistoryFile.append(entry("old", ago: 2 * day), retention: .forever, to: url)
        let slack = day + DictationHistoryFile.trimSlack / 2
        DictationHistoryFile.append(entry("slack", ago: slack), retention: .forever, to: url)
        DictationHistoryFile.append(entry("fresh", ago: 60), retention: .forever, to: url)
        expect(lineCount(url) == 3, "Forever trims nothing")
        DictationHistoryFile.append(entry("new"), retention: .day, to: url)
        let texts = DictationHistoryEntry.entries(in: try Data(contentsOf: url)).map(\.text)
        expect(texts == ["fresh", "new"], "an append past the slack rewrites without everything aged out")
        DictationHistoryFile.append(entry("slack again", ago: slack), retention: .forever, to: url)
        try reorder(url)
        DictationHistoryFile.append(entry("newer"), retention: .day, to: url)
        let within = DictationHistoryEntry.entries(in: try Data(contentsOf: url)).map(\.text)
        expect(within.contains("slack again"), "an oldest line inside the slack leaves the file as it is")
        let shown = DictationHistoryFile.load(retention: .day, now: now, at: url).map(\.text)
        expect(!shown.contains("slack again"), "while a load never shows it")
    }

    /// Moves the last line first, so the file's head is the one inside the slack.
    static func reorder(_ url: URL) throws {
        var all = lines(try Data(contentsOf: url)).map { Data($0) }
        all.insert(all.removeLast(), at: 0)
        try all.map { $0 + Data("\n".utf8) }.reduce(Data(), +).write(to: url)
    }

    static func aLoadDropsWhatAgedOutSinceTheLastWrite(in folder: URL) throws {
        let url = scratch(folder, "load")
        DictationHistoryFile.append(entry("a week ago", ago: 7 * 86_400), retention: .forever, to: url)
        DictationHistoryFile.append(entry("today", ago: 60), retention: .forever, to: url)
        let loaded = DictationHistoryFile.load(retention: .day, now: now, at: url)
        expect(loaded.map(\.text) == ["today"], "a load shows only what the span keeps")
        expect(!read(url).contains("a week ago"), "and the file loses what aged out with it")
        _ = DictationHistoryFile.load(retention: .day, now: now.addingTimeInterval(2 * 86_400), at: url)
        expect(!FileManager.default.fileExists(atPath: url.path), "a file with nothing left is removed")
    }

    static func aCutShortLineNeverSwallowsTheNext(in folder: URL) throws {
        let url = scratch(folder, "cut")
        DictationHistoryFile.append(entry("whole"), retention: .month, to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"1790000000\#t{"id":"6B1F3C2A-9D4E-4F5A-8B7C"#.utf8))
        try handle.close()
        expect(
            DictationHistoryFile.load(retention: .month, now: now, at: url).map(\.text) == ["whole"],
            "a line still landing is not read")
        DictationHistoryFile.append(entry("after"), retention: .month, to: url)
        let texts = DictationHistoryEntry.entries(in: try Data(contentsOf: url)).map(\.text)
        expect(texts == ["whole", "after"], "the next append drops the cut line rather than ending it")
        expect(lineCount(url) == 2 && read(url).hasSuffix("\n"), "and it ends on a whole line")
    }

    static func aCorruptLineIsToleratedAndKeptUntilItAges(in folder: URL) throws {
        let url = scratch(folder, "corrupt")
        DictationHistoryFile.append(entry("before", ago: 120), retention: .month, to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("1789999950\t{\"id\":broken}\n".utf8))
        try handle.close()
        DictationHistoryFile.append(entry("after", ago: 10), retention: .month, to: url)
        let loaded = DictationHistoryFile.load(retention: .month, now: now, at: url)
        expect(
            loaded.map(\.text) == ["after", "before"], "a corrupt line in the middle hides nothing around it")
        expect(read(url).contains("broken"), "and is left alone, since a later build might read it")
    }

    static func deleteRemovesOnlyItsLine(in folder: URL) throws {
        let url = scratch(folder, "delete")
        let first = entry("first", ago: 30)
        let second = entry("second", ago: 20)
        let later = #"1789999990\#t{"id":"6B1F3C2A-9D4E-4F5A-8B7C-1D2E3F4A5B6C","text":"later","extra":1}"#
        try Data((first.line + later + "\n" + second.line).utf8).write(to: url)
        DictationHistoryFile.delete([first.id], at: url)
        let after = read(url)
        expect(!after.contains("first") && after.contains("second"), "delete removes only that entry")
        expect(after.contains(later + "\n"), "and keeps a later build's line byte for byte")
        let laterID = UUID(uuidString: "6B1F3C2A-9D4E-4F5A-8B7C-1D2E3F4A5B6C")!
        DictationHistoryFile.delete([second.id, laterID], at: url)
        expect(
            !FileManager.default.fileExists(atPath: url.path), "deleting the last entries removes the file")
        DictationHistoryFile.delete([first.id], at: url)
        expect(!FileManager.default.fileExists(atPath: url.path), "deleting from no file creates none")
    }

    static func clearAndOffRemoveTheFile(in folder: URL) throws {
        let url = scratch(folder, "clear")
        DictationHistoryFile.append(entry("one"), retention: .month, to: url)
        DictationHistoryFile.clear(at: url)
        expect(!FileManager.default.fileExists(atPath: url.path), "Clear removes the file")
        DictationHistoryFile.append(entry("two"), retention: .month, to: url)
        expect(lineCount(url) == 1, "the next dictation starts a new file")
        DictationHistoryFile.trim(retention: .forever, now: now, at: url)
        expect(FileManager.default.fileExists(atPath: url.path), "Forever trims nothing")
        DictationHistoryFile.trim(retention: .off, now: now, at: url)
        expect(!FileManager.default.fileExists(atPath: url.path), "switching to Off removes the history")
    }

    // MARK: - Search

    static func searchFindsEveryWordAnywhere() {
        let entries = [
            entry("Ёлка в субботу", app: "Telegram"),
            entry(
                "Release notes for Kubernetes", transcript: "релиз ноутс", mode: "Translate to English",
                app: "Slack"),
            entry("Сделай короче", kind: .edit, app: "TextEdit"),
            entry("Café menu", app: "Notes")
        ]
        let keys = entries.map(DictationHistorySearchKey.init)
        func found(_ query: String) -> [String] {
            DictationHistoryQuery.filter(entries, keys: keys, query: query).map(\.text)
        }
        expect(found("") == entries.map(\.text), "an empty query lists everything in order")
        expect(found("   ") == entries.map(\.text), "and so does whitespace")
        expect(
            found("кубер").isEmpty && found("KUBERNETES") == ["Release notes for Kubernetes"], "case folds")
        expect(found("елка") == ["Ёлка в субботу"], "Ё folds to Е, so either spelling finds it")
        expect(found("cafe") == ["Café menu"], "accents fold")
        expect(found("релиз") == ["Release notes for Kubernetes"], "the raw transcript is searched")
        expect(
            found("slack translate") == ["Release notes for Kubernetes"], "the app and the mode are searched")
        expect(found("notes kubernetes") == ["Release notes for Kubernetes"], "every word must match")
        expect(found("notes telegram").isEmpty, "a word no entry holds finds nothing")
        expect(found("note").count == 2, "a word part matches, in the given order")
        expect(found("textedit короче") == ["Сделай короче"], "an edit is found like a dictation")
    }
}
