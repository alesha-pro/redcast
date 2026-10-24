import Foundation

/// Dictation History's lines, file, search, recordings and retries, on a scratch folder.
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

    static func main() async throws {
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
        aFailedEntryRoundTrips()
        aFailedLineAnOlderBuildReads()
        aFailureIsOneShortLine()
        try aRetryRewritesItsLineInPlace(in: folder)
        keptRecordingsAreNamedByTheirEntry()
        keptRecordingsAreBounded()
        aRecordingReadsBackAsItsSamples()
        try theRecordingFolderKeepsTrimsAndClears(in: folder)
        oneRetryRunsPerEntry()
        await aRetryLandsFailsOrLeavesTheEntry()

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

    // MARK: - Failed dictations

    static func failed(_ reason: String = "The request timed out.", ago seconds: TimeInterval = 0)
        -> DictationHistoryEntry
    {
        DictationHistoryEntry(
            date: now.addingTimeInterval(-seconds), kind: .dictation, text: "", mode: "Polish",
            modeID: UUID(uuidString: "3C6E2B14-8F0A-4D57-9E21-7A4B5C6D7E02"), engine: .cloud,
            model: "google/gemini-3.1-flash-lite", appName: "Slack", bundleID: "com.tinyspeck.slackmacgap",
            duration: 6.4, failure: reason)
    }

    static func aFailedEntryRoundTrips() {
        let written = failed("The request timed out.\nURL: https://openrouter.ai/api/v1")
        expect(written.isFailed && written.text.isEmpty, "a failed entry has a reason and no text yet")
        expect(written.failure == "The request timed out.", "the reason keeps the error's first line")
        let read = DictationHistoryEntry(line: Data(written.line.dropLast().utf8)[...])
        expect(read == written, "a failed entry reads back field for field, its mode's id included")
        expect(!entry("fine").isFailed && !entry("fine").line.contains("failure"), "a normal entry has none")
    }

    /// Pinned: the line a failure writes, and what the build before failures reads of it.
    static func aFailedLineAnOlderBuildReads() {
        let id = UUID(uuidString: "6B1F3C2A-9D4E-4F5A-8B7C-1D2E3F4A5B6C")!
        let pinned =
            #"1790000000\#t{"app":"Slack","duration":6.4,"engine":"cloud","failure":"HTTP 503","#
            + #""id":"6B1F3C2A-9D4E-4F5A-8B7C-1D2E3F4A5B6C","kind":"dictation","#
            + #""modeID":"3C6E2B14-8F0A-4D57-9E21-7A4B5C6D7E02","model":"voxtral","text":""}"#
        let entry = DictationHistoryEntry(
            id: id, date: now, kind: .dictation, text: "",
            modeID: UUID(uuidString: "3C6E2B14-8F0A-4D57-9E21-7A4B5C6D7E02"), engine: .cloud, model: "voxtral",
            appName: "Slack", duration: 6.4, failure: "HTTP 503")
        expect(entry.line == pinned + "\n", "a failure's line is written byte for byte")
        expect(DictationHistoryEntry(line: Data(pinned.utf8)[...]) == entry, "and reads back")
        let tab = pinned.firstIndex(of: "\t")!
        let older = try? JSONDecoder().decode(
            FirstBuildPayload.self, from: Data(pinned[pinned.index(after: tab)...].utf8))
        expect(
            older?.id == id && older?.text == "" && older?.kind == "dictation",
            "the build before failures reads it as an empty dictation, hiding nothing around it")
    }

    /// The first build's own payload, field for field.
    struct FirstBuildPayload: Decodable {
        var id: UUID
        var kind: String?
        var text: String
        var transcript: String?
        var mode: String?
        var engine: String?
        var model: String?
        var app: String?
        var bundleID: String?
        var duration: Double?
    }

    static func aFailureIsOneShortLine() {
        let long = String(repeating: "word ", count: 60)
        let line = DictationHistoryEntry.failureLine(long)
        expect(
            line.count == DictationHistoryEntry.maxFailureLength && line.hasSuffix("…"),
            "a long error is capped with an ellipsis")
        expect(DictationHistoryEntry.failureLine("  a\t b  \n c") == "a b", "whitespace folds on the first line")
        expect(DictationHistoryEntry.failureLine("\n\n") == "?", "an empty error still marks the failure")
    }

    static func aRetryRewritesItsLineInPlace(in folder: URL) throws {
        let url = scratch(folder, "retry")
        let before = entry("before", ago: 30)
        let broken = failed(ago: 20)
        let later = #"1789999985\#t{"id":"8B1F3C2A-9D4E-4F5A-8B7C-1D2E3F4A5B6C","text":"later","extra":1}"#
        let after = entry("after", ago: 10)
        try Data((before.line + broken.line + later + "\n" + after.line).utf8).write(to: url)
        let heard = DictationRetryTranscript(
            text: "Hello there", transcript: "hello there", mode: "Polish", engine: .cloud, model: "voxtral")
        let fixed = broken.transcribed(heard)
        expect(
            !fixed.isFailed && fixed.id == broken.id && fixed.date == broken.date && fixed.appName == "Slack"
                && fixed.duration == 6.4 && fixed.modeID == nil,
            "a transcribed retry is a normal entry at the failure's date, app and length")
        DictationHistoryFile.update(fixed, at: url)
        let texts = DictationHistoryEntry.entries(in: try Data(contentsOf: url)).map(\.text)
        expect(texts == ["before", "Hello there", "later", "after"], "its line is rewritten where it stood")
        expect(read(url).contains(later + "\n"), "and every other line stays byte for byte")
        let loaded = DictationHistoryFile.load(retention: .month, now: now, at: url)
        expect(
            loaded.first { $0.id == broken.id }?.transcript == "hello there",
            "a load shows the retried text with its raw transcript")
    }

    // MARK: - Kept recordings

    static func recording(ago seconds: TimeInterval, bytes: Int = 1_000) -> DictationKeptRecording {
        DictationKeptRecording(id: UUID(), date: now.addingTimeInterval(-seconds), bytes: bytes)
    }

    static func keptRecordingsAreNamedByTheirEntry() {
        let kept = recording(ago: 0.5)
        let name = kept.fileName
        expect(name == "1789999999-\(kept.id.uuidString).wav", "a name is the date's seconds and the entry's id")
        expect(DictationKeptRecording(fileName: name, bytes: 1_000) == kept, "and reads back as written")
        for foreign in [".DS_Store", "x-\(kept.id.uuidString).wav", "1-\(kept.id.uuidString).mp3", "1-nope.wav"] {
            expect(DictationKeptRecording(fileName: foreign, bytes: 1) == nil, "a foreign name is not ours: \(foreign)")
        }
    }

    static func keptRecordingsAreBounded() {
        let day: TimeInterval = 86_400
        expect(
            DictationKeptRecording.maxCount == 20 && DictationKeptRecording.maxAge == 7 * day
                && DictationKeptRecording.maxBytes == 100_000_000,
            "twenty recordings, seven days and 100 MB at most")
        expect(
            DictationKeptRecording.cutoff(now: now, history: nil) == now.addingTimeInterval(-7 * day)
                && DictationKeptRecording.cutoff(now: now, history: now.addingTimeInterval(-day))
                    == now.addingTimeInterval(-day)
                && DictationKeptRecording.cutoff(now: now, history: now.addingTimeInterval(-30 * day))
                    == now.addingTimeInterval(-7 * day),
            "a week, or the history's own span when it is shorter")
        let cutoff = DictationKeptRecording.cutoff(now: now, history: nil)
        let many = (0..<25).map { recording(ago: TimeInterval($0) * 60) }
        let expired = DictationKeptRecording.expired(many, cutoff: cutoff)
        expect(expired == Set(many[20...].map(\.id)), "past twenty, the oldest go")
        let aged = [recording(ago: 60), recording(ago: 8 * day)]
        expect(DictationKeptRecording.expired(aged, cutoff: cutoff) == [aged[1].id], "past a week, it goes")
        let large = [
            recording(ago: 10, bytes: 40_000_000), recording(ago: 20, bytes: 40_000_000),
            recording(ago: 30, bytes: 40_000_000), recording(ago: 40, bytes: 1_000)
        ]
        expect(
            DictationKeptRecording.expired(large, cutoff: cutoff) == [large[2].id, large[3].id],
            "past the bytes, the oldest go, even a small one older than the first that did not fit")
        expect(DictationKeptRecording.expired([], cutoff: cutoff).isEmpty, "nothing kept, nothing to trim")
    }

    static func aRecordingReadsBackAsItsSamples() {
        let samples: [Float] = [0, 0.5, -0.5, 1, -1, 0.25, .nan]
        let wav = VoiceAudio.wav(samples[...])
        let read = DictationKeptRecording.samples(fromWAV: wav, sampleRate: VoiceAudio.sampleRate)
        let expected: [Float] = [0, 0.5, -0.5, 1, -1, 0.25, 0]
        expect(
            read.map { zip($0, expected).allSatisfy { abs($0 - $1) < 0.0001 } && $0.count == 7 } == true,
            "the WAV a failure keeps reads back as its samples")
        expect(
            DictationKeptRecording.samples(fromWAV: wav, sampleRate: 44_100) == nil,
            "another rate is not a recording this build kept")
        expect(DictationKeptRecording.samples(fromWAV: Data("RIFF".utf8), sampleRate: 16_000) == nil, "nor a stub")
        var stereo = wav
        stereo[22] = 2
        expect(DictationKeptRecording.samples(fromWAV: stereo, sampleRate: 16_000) == nil, "nor stereo")
    }

    static func theRecordingFolderKeepsTrimsAndClears(in folder: URL) throws {
        let audio = folder.appending(path: "dictation-failed-audio", directoryHint: .isDirectory)
        let speech = (0..<16_000).map { Float(sin(Double($0) / 8)) * 0.5 }
        let wav = VoiceAudio.wav(speech[...])
        expect(DictationRecordingFolder.kept(now: now, historyCutoff: nil, in: audio).isEmpty, "no folder, none kept")
        expect(!FileManager.default.fileExists(atPath: audio.path), "and reading creates none")
        let first = DictationKeptRecording(id: UUID(), date: now.addingTimeInterval(-60), bytes: wav.count)
        DictationRecordingFolder.keep(wav, as: first, historyCutoff: nil, in: audio)
        let excluded = try audio.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        expect(excluded == true, "the folder is excluded from backups")
        expect(
            DictationRecordingFolder.kept(now: now, historyCutoff: nil, in: audio) == [first.id],
            "a kept recording is listed by its entry")
        let samples = DictationRecordingFolder.samples(for: first.id, sampleRate: 16_000, in: audio)
        expect(samples?.count == speech.count, "and reads back as its samples")
        let more = (1...21).map {
            DictationKeptRecording(id: UUID(), date: now.addingTimeInterval(TimeInterval(-60 + $0)), bytes: wav.count)
        }
        more.forEach { DictationRecordingFolder.keep(wav, as: $0, historyCutoff: nil, in: audio) }
        let kept = DictationRecordingFolder.kept(now: now, historyCutoff: nil, in: audio)
        expect(kept == Set(more[1...].map(\.id)), "a write trims to the newest twenty")
        let stale = DictationKeptRecording(id: UUID(), date: now.addingTimeInterval(-8 * 86_400), bytes: wav.count)
        DictationRecordingFolder.keep(wav, as: stale, historyCutoff: nil, in: audio)
        expect(
            !DictationRecordingFolder.kept(now: now, historyCutoff: nil, in: audio).contains(stale.id),
            "one older than a week is trimmed as it is written")
        DictationRecordingFolder.trim(now: now, historyCutoff: now.addingTimeInterval(-50), in: audio)
        expect(
            DictationRecordingFolder.kept(now: now, historyCutoff: nil, in: audio) == Set(more[9...].map(\.id)),
            "a shorter Keep history trims the recordings at once")
        DictationRecordingFolder.delete([more[20].id], in: audio)
        expect(
            DictationRecordingFolder.samples(for: more[20].id, sampleRate: 16_000, in: audio) == nil
                && DictationRecordingFolder.kept(now: now, historyCutoff: nil, in: audio).count == 11,
            "Delete Entry removes its recording alone")
        DictationRecordingFolder.trim(
            now: now, historyCutoff: DictationHistoryRetention.off.cutoff(now: now), in: audio)
        expect(!FileManager.default.fileExists(atPath: audio.path), "Off removes every recording and the folder")
        DictationRecordingFolder.keep(wav, as: first, historyCutoff: nil, in: audio)
        DictationRecordingFolder.clear(in: audio)
        expect(!FileManager.default.fileExists(atPath: audio.path), "Clear History removes the folder")
    }

    // MARK: - Retry

    static func oneRetryRunsPerEntry() {
        var state = DictationRetryState()
        let id = UUID()
        let attempt = state.begin(id)
        expect(attempt != nil && state.isRetrying(id) && !state.isIdle, "a retry starts")
        expect(state.begin(id) == nil, "and a second one for the same entry waits for it")
        expect(!state.end(id, attempt: UUID()), "a stranger's result never lands")
        expect(state.end(id, attempt: attempt!) && state.isIdle, "its own does, once")
        let deleted = state.begin(id)!
        state.cancel([id])
        expect(!state.end(id, attempt: deleted), "a deleted entry's retry lands nothing")
        let closed = state.begin(id)!
        state.cancelAll()
        expect(!state.end(id, attempt: closed) && state.isIdle, "nor does one whose screen closed")
        let again = state.begin(id)
        expect(again != nil && again != closed, "and the entry can be retried afresh")
    }

    /// A fake engine standing where the cloud or the model on this Mac would.
    @MainActor
    final class FakeTranscriber {
        var calls: [Int] = []
        var result: Result<DictationRetryTranscript, any Error> = .failure(URLError(.timedOut))
        var gate: CheckedContinuation<Void, Never>?
        var holds = false

        func transcribe(_ samples: [Float]) async throws -> DictationRetryTranscript {
            calls.append(samples.count)
            if holds { await withCheckedContinuation { gate = $0 } }
            return try result.get()
        }
    }

    static func aRetryLandsFailsOrLeavesTheEntry() async {
        let broken = failed()
        let fake = FakeTranscriber()
        let attempt = DictationRetryAttempt(engine: .onDevice, model: "Parakeet · Redux")
        func run(_ samples: [Float]? = [0.1, 0.2]) async -> DictationHistoryEntry? {
            await DictationRetry.run(
                broken, samples: samples, attempt: attempt, transcribe: fake.transcribe,
                describe: { $0.localizedDescription })
        }
        fake.result = .success(
            DictationRetryTranscript(text: "  Hello.\n", engine: .onDevice, model: "Parakeet · Redux"))
        let landed = await run()
        expect(
            landed?.isFailed == false && landed?.text == "Hello." && landed?.engine == .onDevice
                && landed?.model == "Parakeet · Redux" && landed?.mode == nil && fake.calls == [2],
            "a retry that hears the recording makes the entry a normal one, trimmed")
        fake.result = .failure(URLError(.timedOut))
        let again = await run()
        expect(
            again?.failure == URLError(.timedOut).localizedDescription && again?.text == ""
                && again?.engine == .onDevice && again?.model == "Parakeet · Redux" && again?.id == broken.id,
            "one that fails stays failed with the new reason, on what it tried")
        fake.result = .success(DictationRetryTranscript(text: " ", engine: .cloud, model: "voxtral"))
        let silent = await run()
        expect(
            silent?.failure == DictationRetryFailure.noSpeech.localizedDescription,
            "nothing heard is a failure, not an empty entry")
        let calls = fake.calls.count
        let gone = await run(nil)
        expect(
            gone?.failure == DictationRetryFailure.noRecording.localizedDescription && fake.calls.count == calls,
            "a recording no longer kept fails at once, with no transcription")
        fake.result = .failure(CancellationError())
        let cancelled = await run()
        expect(cancelled == nil, "a cancelled retry leaves the entry as it was")
        fake.result = .failure(URLError(.cancelled))
        let dropped = await run()
        expect(dropped == nil, "and so does a cancelled request")
        fake.result = .success(DictationRetryTranscript(text: "late", engine: .cloud, model: "voxtral"))
        fake.holds = true
        let running = Task { await run() }
        while fake.gate == nil { await Task.yield() }
        running.cancel()
        fake.gate?.resume()
        let stopped = await running.value
        expect(stopped == nil, "a retry cancelled while it transcribes lands nothing")
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
