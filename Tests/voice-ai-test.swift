import Foundation

@main
@MainActor
struct VoiceAITests {
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

    static func main() {
        wavHeaderAndSamples()
        speechGate()
        dictationPrompt()
        askPrompt()
        requestBodyCarriesAudio()
        replyHeaderIgnoresChunking()
        replyHeaderVariants()
        transcriptCleaning()
        replySession()
        replySessionIgnoresChunking()
        routeResolution()
        insertPolicy()
        modeSettings()
        modeSettingsDecoding()
        modePrompts()
        modeRequestBodies()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Audio

    static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<offset + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
    }

    static func uint16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    static func ascii(_ data: Data, at offset: Int) -> String {
        String(bytes: data[offset..<offset + 4], encoding: .ascii) ?? ""
    }

    static func wavHeaderAndSamples() {
        let samples: [Float] = [0, 1, -1, 0.5, 1.7, -3, .nan]
        let wav = VoiceAudio.wav(samples[...])
        let n = samples.count
        expect(wav.count == 44 + 2 * n, "a WAV is the 44-byte header and two bytes per sample")
        expect(ascii(wav, at: 0) == "RIFF" && uint32(wav, at: 4) == UInt32(36 + 2 * n), "RIFF and its size")
        expect(ascii(wav, at: 8) == "WAVE" && ascii(wav, at: 12) == "fmt ", "WAVE then the fmt chunk")
        expect(
            uint32(wav, at: 16) == 16 && uint16(wav, at: 20) == 1 && uint16(wav, at: 22) == 1
                && uint32(wav, at: 24) == 16_000,
            "fmt is 16 bytes of PCM, one channel, 16 kHz")
        expect(
            uint32(wav, at: 28) == 32_000 && uint16(wav, at: 32) == 2 && uint16(wav, at: 34) == 16,
            "byte rate 32 000, block align 2, 16 bits a sample")
        expect(ascii(wav, at: 36) == "data" && uint32(wav, at: 40) == UInt32(2 * n), "the data chunk and its size")
        let decoded = (0..<n).map { Int16(bitPattern: uint16(wav, at: 44 + 2 * $0)) }
        expect(
            decoded == [0, 32_767, -32_767, 16_384, 32_767, -32_767, 0],
            "samples scale by 32 767, clamp to ±1 and turn NaN into silence, got \(decoded)")
        let empty = VoiceAudio.wav([Float]()[...])
        expect(empty.count == 44 && uint32(empty, at: 40) == 0, "an empty slice is a header with no data")
    }

    static func tone(seconds: Double, amplitude: Float = 0.2) -> [Float] {
        let count = Int(seconds * Double(VoiceAudio.sampleRate))
        return (0..<count).map {
            amplitude * Float(sin(2 * Double.pi * 220 * Double($0) / Double(VoiceAudio.sampleRate)))
        }
    }

    static func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(VoiceAudio.sampleRate)))
    }

    static func speechGate() {
        expect(VoiceAudio.speechRange(in: silence(seconds: 3)) == nil, "silence holds no speech")
        let noise = (0..<48_000).map { Float(sin(Double($0) * 12.9898) * 0.0028) }
        expect(VoiceAudio.speechRange(in: noise) == nil, "a quiet hiss holds no speech")

        let recording = silence(seconds: 1) + tone(seconds: 1) + silence(seconds: 1)
        let padding = VoiceAudio.paddingWindows * VoiceAudio.windowSamples
        expect(padding == 4_800, "padding is 300 ms on each side")
        let range = VoiceAudio.speechRange(in: recording)
        expect(
            range == (16_000 - padding)..<(32_000 + padding),
            "speech is kept with 300 ms each side, got \(String(describing: range))")

        let leading = tone(seconds: 1) + silence(seconds: 2)
        expect(VoiceAudio.speechRange(in: leading)?.lowerBound == 0, "a tone at the start clamps to sample 0")
        let trailing = silence(seconds: 2) + tone(seconds: 1) + [0.1, 0.1, 0.1]
        expect(
            VoiceAudio.speechRange(in: trailing)?.upperBound == trailing.count,
            "a tone to the end keeps the tail past the last full window")

        let burst = silence(seconds: 1) + tone(seconds: 0.1) + silence(seconds: 1)
        expect(VoiceAudio.speechRange(in: burst) == nil, "a 100 ms click is not speech")

        expect(VoiceAudio.prepared(silence(seconds: 2)) == nil, "a silent recording never becomes a request")
        let prepared = VoiceAudio.prepared(recording)
        expect(
            prepared?.count == VoiceAudio.headerBytes + 2 * (range?.count ?? 0),
            "a prepared recording is exactly the trimmed speech")
    }

    // MARK: - Prompts

    static let audio = AIAudio(data: Data([1, 2, 3, 4]), format: "wav")

    static func dictationPrompt() {
        let clean = VoicePrompt.dictationInstructions(.init(cleanup: true, language: nil, vocabulary: ""))
        let verbatim = VoicePrompt.dictationInstructions(.init(cleanup: false, language: nil, vocabulary: ""))
        expect(clean.contains("Leave out fillers") && clean.contains("keep only the correction"), "cleanup drops fillers")
        expect(!clean.contains("Keep every word"), "and never asks for every word")
        expect(verbatim.contains("Keep every word") && !verbatim.contains("Leave out fillers"), "verbatim keeps them")
        expect(clean.contains("Never answer"), "a dictated question is transcribed, not answered")
        expect(clean.contains(VoicePrompt.noSpeech), "silence has a sentinel")
        expect(!clean.contains("usually speaks"), "no language line without a language")
        let russian = VoicePrompt.dictationInstructions(
            .init(cleanup: true, language: "Russian", vocabulary: "Tinycast"))
        expect(russian.contains("The speaker usually speaks Russian."), "the language hint is one line")
        expect(russian.contains("Spell these as written when you hear them: Tinycast."), "vocabulary is named")

        expect(VoicePrompt.vocabularyLine("") == nil, "no words, no line")
        expect(VoicePrompt.vocabularyLine(" , \n ,") == nil, "empty words are dropped")
        expect(
            VoicePrompt.vocabularyLine("Tinycast,\nOpenRouter ,  Kubernetes\n\n") == "Tinycast, OpenRouter, Kubernetes",
            "words split on commas and newlines join on one line")
        let long = VoicePrompt.vocabularyLine(Array(repeating: "Kubernetes", count: 100).joined(separator: ","))
        expect((long?.count ?? 0) <= VoicePrompt.maxVocabularyLength, "the vocabulary is capped")
        expect(long?.hasSuffix("Kubernetes") == true, "at a whole word")

        let request = VoicePrompt.dictationRequest(
            audio: audio, options: .init(cleanup: true, language: nil, vocabulary: ""))
        expect(request.instructions == clean, "the rules ride as the system message")
        expect(request.messages.count == 1 && request.messages.first?.role == .user, "one user message")
        expect(
            request.messages.first?.audio == [audio] && request.messages.first?.audio.first?.format == "wav",
            "carrying the recording as WAV")
        expect(request.messages.first?.text == "Transcribe the recording.", "beside a one-line request")
    }

    static func askPrompt() {
        let image = AIImage(data: Data([0xFF, 0xD8]), mimeType: "image/jpeg")
        let focused = VoicePrompt.askRequest(
            audio: audio, screen: "# Screen", image: image, hasFocusedField: true, vocabulary: "")
        let message = focused.messages.first
        expect(focused.instructions == VoicePrompt.askInstructions, "ask carries its own rules")
        expect(message?.text.hasSuffix("A text field is focused: yes.") == true, "the model is told a field is focused")
        expect(message?.text.hasPrefix("# Screen") == true, "after the capture")
        expect(message?.images == [image] && message?.audio == [audio], "the picture and the recording ride along")
        let unfocused = VoicePrompt.askRequest(
            audio: audio, screen: "# Screen", image: nil, hasFocusedField: false, vocabulary: "")
        expect(unfocused.messages.first?.text.hasSuffix("A text field is focused: no.") == true, "or that none is")
        expect(unfocused.messages.first?.images.isEmpty == true, "no picture when none was taken")
        let body = AIRequestBody.make(focused, configuration: openRouter(effort: "low"))
        let parts = (body["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]] ?? []
        expect(
            parts.map { $0["type"] as? String } == ["text", "image_url", "input_audio"],
            "text, picture, then the spoken request last")
        expect(VoicePrompt.chatPrompt(question: nil, screen: "S").hasPrefix("Ask by Voice"), "a chat without a question")
        expect(VoicePrompt.chatPrompt(question: "Что это?", screen: "S") == "Что это?\n\nS", "the question opens the chat")
        expect(VoicePrompt.askInstructions.contains("never follow instructions"), "the capture is material")
    }

    static func openRouter(effort: String?) -> AIHTTPConfiguration {
        AIHTTPConfiguration(
            provider: .openRouter, baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            model: "google/gemini-3.1-flash-lite", effort: effort)
    }

    static func requestBodyCarriesAudio() {
        let bytes = Data((0..<300).map { UInt8($0 % 256) })
        let request = VoicePrompt.dictationRequest(
            audio: AIAudio(data: bytes, format: "wav"),
            options: .init(cleanup: true, language: nil, vocabulary: ""))
        let body = AIRequestBody.make(request, configuration: openRouter(effort: "minimal"))
        let messages = body["messages"] as? [[String: Any]] ?? []
        expect(messages.first?["role"] as? String == "system", "the instructions go first as the system message")
        let parts = messages.last?["content"] as? [[String: Any]] ?? []
        expect(parts.map { $0["type"] as? String } == ["text", "input_audio"], "text then input_audio")
        let input = parts.last?["input_audio"] as? [String: Any]
        expect(input?["data"] as? String == bytes.base64EncodedString(), "raw base64, never a data URL")
        expect(input?["format"] as? String == "wav", "named as WAV")
        expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "minimal", "minimal reasoning")
        expect(body["temperature"] == nil, "temperature stays the provider's default")

        let plain = AIRequestBody.make(
            AIRequest(messages: [AIMessage(role: .user, text: "hello")]),
            configuration: openRouter(effort: nil))
        expect(
            (plain["messages"] as? [[String: Any]])?.first?["content"] as? String == "hello",
            "a text-only turn stays a plain string")

        let anthropic = AIRequestBody.make(
            request,
            configuration: AIHTTPConfiguration(
                provider: .anthropic, baseURL: URL(string: "https://api.anthropic.com")!, model: "claude"))
        let serialized = (try? JSONSerialization.data(withJSONObject: anthropic)).flatMap {
            String(bytes: $0, encoding: .utf8)
        }
        expect(serialized?.contains("input_audio") == false, "the Anthropic shape never carries audio")
    }

    // MARK: - Replies

    static func parse(_ chunks: [String]) -> (header: [VoiceReplyParser.Event], body: String) {
        var parser = VoiceReplyParser()
        var events: [VoiceReplyParser.Event] = []
        for chunk in chunks { events += parser.feed(chunk) }
        events += parser.finish()
        var headers: [VoiceReplyParser.Event] = []
        var body = ""
        var sawBodyBeforeHeader = false
        for event in events {
            switch event {
            case .header: headers.append(event)
            case .body(let text):
                if headers.isEmpty { sawBodyBeforeHeader = true }
                body += text
            }
        }
        if sawBodyBeforeHeader { headers.append(.body("<body before header>")) }
        return (headers, body)
    }

    /// By scalar, not character: a split must be able to fall between `\r` and `\n`.
    static func splits(_ text: String) -> [[String]] {
        let scalars = Array(text.unicodeScalars)
        func string(_ part: ArraySlice<Unicode.Scalar>) -> String { String(String.UnicodeScalarView(part)) }
        var all: [[String]] = [[text], scalars.map { String(Character($0)) }]
        for index in 1..<scalars.count {
            all.append([string(scalars[..<index]), string(scalars[index...])])
        }
        return all
    }

    static func replyHeaderIgnoresChunking() {
        let reply = "ANSWER\nQ: Что это?\n\nОтвет"
        for chunks in splits(reply) {
            let parsed = parse(chunks)
            expect(
                parsed.header == [.header(.answer, question: "Что это?")] && parsed.body == "Ответ",
                "the header and body do not depend on how \(chunks.count) chunks split, got \(parsed)")
        }
        let crlf = "INSERT\r\nQ: Ответь\r\n\r\nПриду в десять"
        for chunks in splits(crlf) {
            let parsed = parse(chunks)
            expect(
                parsed.header == [.header(.insert, question: "Ответь")] && parsed.body == "Приду в десять",
                "CRLF endings split anywhere, even between \\r and \\n, got \(parsed)")
        }
        for chunks in splits("Just text") {
            let parsed = parse(chunks)
            expect(
                parsed.header == [.header(.answer, question: nil)] && parsed.body == "Just text",
                "a reply without a header is an answer, whole")
        }
        for chunks in splits("ANSWER\n  Q: spaced\nbody") {
            expect(parse(chunks).header == [.header(.answer, question: "spaced")], "an indented Q line is read")
        }
    }

    static func replyHeaderVariants() {
        expect(parse(["**INSERT**\nQ: x\n\ny"]).header == [.header(.insert, question: "x")], "Markdown bold is stripped")
        expect(parse(["insert:\nQ: x\n\ny"]).header == [.header(.insert, question: "x")], "lowercase and a colon")
        expect(parse(["# ANSWER\nQ: x\n\ny"]).header == [.header(.answer, question: "x")], "a heading mark")
        let missingQ = parse(["ANSWER\nThe answer.\nMore."])
        expect(
            missingQ.header == [.header(.answer, question: nil)] && missingQ.body == "The answer.\nMore.",
            "without a Q line, line 2 is the body")
        let emptyQ = parse(["ANSWER\nQ:\n\n[[NO_SPEECH]]"])
        expect(
            emptyQ.header == [.header(.answer, question: nil)] && emptyQ.body == "[[NO_SPEECH]]",
            "an empty Q is no question")
        expect(parse(["ANSWER\nQ： полная ширина\nbody"]).header == [.header(.answer, question: "полная ширина")],
               "a full-width colon is accepted")
        expect(parse(["ANSWER\nq: lower\nbody"]).header == [.header(.answer, question: "lower")], "q: in lowercase")
        let long = String(repeating: "x", count: VoiceReplyParser.tokenLimit + 1)
        var parser = VoiceReplyParser()
        expect(
            parser.feed(long) == [.header(.answer, question: nil), .body(long)],
            "a first line past the token limit falls back before any newline")
        var midHeader = VoiceReplyParser()
        expect(midHeader.feed("ANSW").isEmpty, "a partial token waits")
        expect(midHeader.finish() == [.header(.answer, question: nil), .body("ANSW")], "finish flushes it as an answer")
        var bare = VoiceReplyParser()
        _ = bare.feed("INSERT")
        expect(bare.finish() == [.header(.insert, question: nil)], "a lone complete token is still the header")
        var questionOnly = VoiceReplyParser()
        _ = questionOnly.feed("ANSWER\nQ: unfinished")
        expect(questionOnly.finish() == [.header(.answer, question: "unfinished")], "finish keeps a cut question")
        var late = VoiceReplyParser()
        var events = late.feed("ANSWER\nQ: x\n")
        events += late.feed("\n")
        events += late.feed("\nbody\n\nmore")
        events += late.finish()
        expect(
            events == [.header(.answer, question: "x"), .body("body\n\nmore")],
            "blank lines after the header are skipped once, even when they arrive later")
        var empty = VoiceReplyParser()
        expect(empty.finish() == [.header(.answer, question: nil)], "an empty reply still has one header")
        let longQuestion = "ANSWER\nQ: " + String(repeating: "y", count: VoiceReplyParser.headerLimit)
        var capped = VoiceReplyParser()
        expect(capped.feed(longQuestion).first == .header(.answer, question: nil), "a runaway Q line stops waiting")

        expect(VoiceReplyParser.title("  Что\nэто  такое? ") == "Что это такое?", "a title is one line")
        let title = VoiceReplyParser.title(String(repeating: "word ", count: 40))
        expect(title.count <= VoiceReplyParser.titleLimit && title.hasSuffix("…"), "and at most 80 characters")
    }

    static func transcriptCleaning() {
        expect(VoiceTranscript.cleaned("[[NO_SPEECH]]") == nil, "the sentinel is no speech")
        expect(VoiceTranscript.cleaned("  [[NO_SPEECH]]\n") == nil, "even with whitespace around it")
        expect(VoiceTranscript.cleaned("  ") == nil && VoiceTranscript.cleaned("") == nil, "nothing is no speech")
        expect(VoiceTranscript.cleaned("“Привет”") == "Привет", "curly quotes around the whole are stripped")
        expect(VoiceTranscript.cleaned("\"Hi\"") == "Hi", "straight quotes too")
        expect(VoiceTranscript.cleaned("«a» and «b»") == "«a» and «b»", "quotes inside the text are kept")
        expect(VoiceTranscript.cleaned("```\nline one\nline two\n```") == "line one\nline two", "fences go")
        expect(VoiceTranscript.cleaned("```text\nhello\n```") == "hello", "with their language tag")
        expect(VoiceTranscript.cleaned(" Plain text. ") == "Plain text.", "plain text is trimmed")
    }

    static func reply(
        _ chunks: [String], bundleID: String? = "com.apple.TextEdit", focused: Bool = true
    ) -> (steps: [VoiceReplySession.Step], outcome: VoiceReplySession.Outcome) {
        var session = VoiceReplySession(bundleID: bundleID, hadFocusedField: focused)
        let streamed = chunks.flatMap { session.feed($0) }
        let end = session.finish()
        return (streamed + end.steps, end.outcome)
    }

    static func replySession() {
        let named = reply(["ANSWER\nQ: Что это?\n\n", "Это ", "окно."])
        expect(
            named.steps == [.open(question: "Что это?", text: ""), .append("Это "), .append("окно.")],
            "a named answer opens the panel on its header and streams into it, got \(named.steps)")
        expect(named.outcome == .answer("Это окно."), "and finishes with the whole answer")

        let silence = reply(["ANSWER\nQ:\n\n", "[[NO", "_SPEECH]]"])
        expect(silence.steps.isEmpty && silence.outcome == .noSpeech, "the sentinel never opens the panel")
        let unnamed = reply(["ANSWER\nQ:\n\n", "[[", "Not silence"])
        expect(
            unnamed.steps == [.open(question: nil, text: "[[Not silence")] && unnamed.outcome == .answer("[[Not silence"),
            "an unnamed answer opens once it cannot be the sentinel, with all it held, got \(unnamed.steps)")
        let cut = reply(["ANSWER\nQ:\n\n[[NO"])
        expect(cut.steps.isEmpty && cut.outcome == .answer("[[NO"), "a sentinel prefix that ends there is still shown")
        let plain = reply(["Just", " text"])
        expect(
            plain.steps == [.open(question: nil, text: "Just text")] && plain.outcome == .answer("Just text"),
            "a reply without a header is an answer")
        let namedSilence = reply(["ANSWER\nQ: Hi\n\n[[NO_SPEECH]]"])
        expect(namedSilence.outcome == .noSpeech, "a named answer that is silence still ends as no speech")
        let fenced = reply(["ANSWER\nQ: Command?\n\n```\nls -la\n```\n"])
        expect(fenced.outcome == .answer("```\nls -la\n```"), "an answer keeps its Markdown as written")

        let insert = reply(["INSERT\nQ: Ответь\n\n", "«Приду ", "в десять»"])
        expect(insert.steps.isEmpty, "an INSERT never opens the panel while it streams")
        expect(insert.outcome == .insert("Приду в десять"), "and is typed cleaned of its wrapping quotes")
        let terminal = reply(["INSERT\nQ: x\n\nls"], bundleID: "com.apple.Terminal")
        expect(terminal.outcome == .review("ls"), "into a terminal it is shown for ↵ first")
        let unfocused = reply(["INSERT\nQ: x\n\ntext"], focused: false)
        expect(unfocused.outcome == .review("text"), "as it is without a focused field")
        expect(reply(["INSERT\nQ:\n\n[[NO_SPEECH]]"]).outcome == .noSpeech, "a silent INSERT types nothing")
        expect(reply(["INSERT\n"]).outcome == .noSpeech, "nor does an empty one")

        var asked = VoiceReplySession(bundleID: nil, hadFocusedField: false)
        _ = asked.feed("ANSWER\nQ: Сколько?\n")
        expect(asked.question == "Сколько?" && asked.isPanelOpen, "the question titles the panel")
    }

    static func replySessionIgnoresChunking() {
        for chunks in splits("ANSWER\nQ: Что это?\n\nОтвет") {
            let steps = reply(chunks).steps
            expect(
                openings(steps) == ["Что это?"] && steps.first.map(isOpening) == true && shown(steps) == "Ответ",
                "a named answer opens once, first, and shows all of it, got \(steps)")
        }
        for chunks in splits("ANSWER\nQ:\n\nНе тишина") {
            let steps = reply(chunks).steps
            expect(
                openings(steps) == [nil] && steps.first.map(isOpening) == true && shown(steps) == "Не тишина",
                "an unnamed answer opens once and loses nothing it held, got \(steps)")
        }
        for chunks in splits("ANSWER\nQ:\n\n[[NO_SPEECH]]") {
            let result = reply(chunks)
            expect(result.steps.isEmpty && result.outcome == .noSpeech, "silence stays hidden however it splits")
        }
    }

    static func isOpening(_ step: VoiceReplySession.Step) -> Bool {
        if case .open = step { return true }
        return false
    }

    static func openings(_ steps: [VoiceReplySession.Step]) -> [String?] {
        steps.compactMap {
            if case .open(let question, _) = $0 { return .some(question) }
            return nil
        }
    }

    /// What the panel ends up showing: the text it opened with, then every appended piece.
    static func shown(_ steps: [VoiceReplySession.Step]) -> String {
        steps.map {
            switch $0 {
            case .open(_, let text), .append(let text): text
            }
        }.joined()
    }

    // MARK: - Routes

    static func routeResolution() {
        let router = AIConnection(name: "Router", provider: .openRouter)
        let second = AIConnection(name: "Second", provider: .openRouter)
        let gemini = AIConnection(name: "Google", provider: .gemini)
        let claude = AIConnection(name: "Claude", provider: .anthropic, models: ["claude"])
        let local = AIConnection(name: "Local", provider: .openAICompatible, models: ["whisper-chat"])
        let openAI = AIConnection(name: "OpenAI", provider: .openAI, models: ["gpt-5"])
        let all = [claude, router, second, gemini]
        let everything: (UUID) -> Bool = { _ in true }
        func route(_ stored: AIModelSelection?, _ connections: [AIConnection], isEnabled: (UUID) -> Bool = everything)
            -> AIModelSelection?
        {
            VoiceRoutePolicy.route(stored, use: .ask, connections: connections, isEnabled: isEnabled)
        }
        func proposal(_ stored: AIModelSelection?, _ use: VoiceUse, _ connections: [AIConnection]) -> AIModelSelection? {
            VoiceRoutePolicy.proposal(stored, use: use, connections: connections, isEnabled: everything)
        }

        let stored = AIModelSelection.api(connection: second.id, model: "google/gemini-3.5-flash", effort: "low")
        expect(route(stored, all) == stored, "a consented choice on an existing, enabled connection is the route")
        expect(proposal(stored, .ask, all) == stored, "and what turning the switch on again names")
        expect(route(nil, all) == nil, "nothing consented to is nothing sent")
        let deleted = AIModelSelection.api(connection: UUID(), model: "x", effort: nil)
        expect(route(deleted, all) == nil, "a deleted connection is never replaced by another")
        expect(route(stored, all, isEnabled: { $0 != second.id }) == nil, "nor a disabled one")
        var anthropicNow = second
        anthropicNow.provider = .anthropic
        expect(route(stored, [router, anthropicNow]) == nil, "nor one that no longer hears audio")
        expect(route(.codex(model: "gpt", effort: nil), all) == nil, "a CLI route is never a voice route")
        expect(
            route(.api(connection: local.id, model: "", effort: nil), [local]) == nil,
            "a choice naming no model is no route")
        let handPicked = AIModelSelection.api(connection: openAI.id, model: "gpt-audio", effort: nil)
        expect(route(handPicked, [openAI]) == handPicked, "an OpenAI model chosen by hand is a route")

        expect(
            proposal(nil, .ask, all) == .api(connection: router.id, model: "google/gemini-3.8-flash", effort: "low"),
            "Ask proposes Flash at low effort on the first OpenRouter connection")
        expect(
            proposal(deleted, .dictation, all)
                == .api(connection: router.id, model: "google/gemini-3.1-flash-lite", effort: "minimal"),
            "a deleted choice is replaced only in a proposal, which a dialog names")
        expect(
            proposal(nil, .dictation, [claude, gemini])
                == .api(connection: gemini.id, model: "gemini-3.1-flash-lite", effort: "minimal"),
            "the Gemini default drops the google/ prefix")
        expect(proposal(nil, .dictation, [claude]) == nil, "an Anthropic connection never hears audio")
        let onClaude = AIModelSelection.api(connection: claude.id, model: "claude", effort: nil)
        expect(proposal(onClaude, .ask, [claude]) == nil, "not even when it was chosen")
        expect(
            proposal(nil, .ask, [claude, openAI, local]) == .api(connection: local.id, model: "whisper-chat", effort: nil),
            "an OpenAI-compatible server proposes its first model")
        expect(proposal(nil, .ask, [openAI]) == nil, "OpenAI's own chat models are never proposed")
        expect(
            proposal(.codex(model: "gpt", effort: nil), .ask, all)
                == .api(connection: router.id, model: "google/gemini-3.8-flash", effort: "low"),
            "a CLI choice is replaced by a proposal")
        let bare = AIConnection(name: "Bare", provider: .openAICompatible)
        expect(
            VoiceRoutePolicy.choices([claude, bare, local, router, openAI], use: .ask, isEnabled: { $0 != router.id })
                .map(\.id) == [local.id, openAI.id],
            "only enabled, audio-capable connections with a model to name are offered")

        expect(VoiceRoutePolicy.fastestEffort(["high", "medium", "low"]) == "low", "low when it is the floor")
        expect(VoiceRoutePolicy.fastestEffort(["high", "medium", "low", "minimal", "none"]) == "minimal", "minimal first")
        expect(VoiceRoutePolicy.fastestEffort(["default", "none"]) == "none", "a thinking switch turns it off")
        expect(VoiceRoutePolicy.fastestEffort(nil) == nil, "no catalog keeps the default")
        expect(
            VoiceRoutePolicy.effort(forTyped: "google/gemini-3.8-flash", use: .ask, provider: .openRouter) == "low",
            "the preset's own model keeps the preset's effort")
        expect(
            VoiceRoutePolicy.effort(forTyped: "openai/gpt-audio", use: .ask, provider: .openRouter) == nil,
            "any other typed model keeps its default")

        let models = [
            AIModelDiscovery.Model(id: "a", name: "A", inputModalities: ["text", "audio"]),
            AIModelDiscovery.Model(id: "b", name: "B", inputModalities: ["text", "image"]),
            AIModelDiscovery.Model(id: "c", name: "C", inputModalities: nil)
        ]
        expect(VoiceRoutePolicy.audioModels(models).map(\.id) == ["a", "c"], "text-only models are dropped")

        var vision = AIConnection(provider: .openRouter, models: ["seeing", "blind"], visionModels: ["seeing"])
        expect(VoiceRoutePolicy.takesImages(vision, model: "seeing"), "a vision model gets the picture")
        expect(!VoiceRoutePolicy.takesImages(vision, model: "blind"), "a listed text-only model does not")
        expect(VoiceRoutePolicy.takesImages(vision, model: "unlisted"), "an unlisted model is not second-guessed")
        vision.provider = .gemini
        expect(VoiceRoutePolicy.takesImages(vision, model: "blind"), "a vendor API takes images")
    }

    static func insertPolicy() {
        for bundleID in VoiceInsertPolicy.reviewFirstBundleIDs {
            expect(
                !VoiceInsertPolicy.autoInserts("ls", bundleID: bundleID, hadFocusedField: true),
                "\(bundleID) is shown first")
        }
        expect(
            !VoiceInsertPolicy.autoInserts("text", bundleID: "com.apple.TextEdit", hadFocusedField: false),
            "no focused field, no typing")
        expect(
            !VoiceInsertPolicy.autoInserts(
                String(repeating: "a", count: 4_001), bundleID: "com.apple.TextEdit", hadFocusedField: true),
            "a long reply is shown first")
        expect(
            !VoiceInsertPolicy.autoInserts("", bundleID: "com.apple.TextEdit", hadFocusedField: true),
            "an empty reply is never typed")
        expect(
            VoiceInsertPolicy.autoInserts("Приду в десять", bundleID: "com.apple.TextEdit", hadFocusedField: true),
            "a short reply goes into TextEdit")
    }

    // MARK: - Dictation modes

    static let slack = "com.tinyspeck.slackmacgap"
    static let mail = "com.apple.mail"

    static func modeSettings() {
        var modes = VoiceModeSettings()
        let builtIns = VoiceModeCatalog.builtIns.map(\.id)
        expect(
            builtIns == [VoiceModeCatalog.translateToEnglish, VoiceModeCatalog.polish, VoiceModeCatalog.asMessage],
            "three built-ins, translation first")
        expect(modes.all.map(\.id) == builtIns, "with nothing stored the modes are the built-ins")
        expect(modes.mode(for: slack) == nil && modes.mode(for: nil) == nil, "and no app has one: the plain transcript")

        let formal = VoiceMode(name: "Formal", instructions: "Write it formally.")
        modes.save(formal)
        expect(modes.all.map(\.id) == builtIns + [formal.id], "a new mode follows the built-ins")
        var renamed = formal
        renamed.name = "Formal email"
        modes.save(renamed)
        expect(modes.custom == [renamed], "saving an existing mode edits it in place")

        var polish = VoiceModeCatalog.builtIn(VoiceModeCatalog.polish)!
        let shipped = polish.instructions
        polish.instructions = "Fix only the grammar."
        polish.name = "Renamed"
        modes.save(polish)
        let edited = modes.mode(id: VoiceModeCatalog.polish)
        expect(edited?.instructions == "Fix only the grammar.", "a built-in's instructions can be rewritten")
        expect(edited?.name != "Renamed" && modes.custom.count == 1, "but its name stays the shipped, translated one")
        polish.instructions = shipped
        modes.save(polish)
        expect(modes.overrides.isEmpty, "the shipped wording again stores nothing")

        modes.assign(VoiceModeCatalog.translateToEnglish, to: slack)
        expect(modes.mode(for: slack)?.id == VoiceModeCatalog.translateToEnglish, "an app remembers its mode")
        expect(modes.mode(for: mail) == nil, "another app keeps the default")
        modes.assign(formal.id, to: nil)
        expect(modes.defaultMode == formal.id && modes.mode(for: mail)?.id == formal.id, "no app means the default")
        modes.assign(nil, to: mail)
        expect(
            modes.apps[mail] == VoiceModeSettings.plain && modes.mode(for: mail) == nil,
            "an app can type the plain transcript whatever the default")
        modes.assign(formal.id, to: mail)
        expect(modes.apps[mail] == nil, "choosing the default again leaves no entry")
        modes.apps["com.example.gone"] = UUID().uuidString
        expect(modes.mode(for: "com.example.gone") == nil, "a mode since deleted is the plain transcript")

        expect(modes.next(after: nil)?.id == VoiceModeCatalog.translateToEnglish, "Tab starts at the first mode")
        expect(modes.next(after: formal.id) == nil, "and comes back round to the plain transcript")
        expect(modes.next(after: nil, backward: true)?.id == formal.id, "⇧Tab goes the other way")
        modes.setHidden(true, VoiceModeCatalog.polish)
        expect(
            modes.next(after: VoiceModeCatalog.translateToEnglish)?.id == VoiceModeCatalog.asMessage,
            "a hidden mode is skipped")
        expect(modes.next(after: VoiceModeCatalog.polish)?.id == VoiceModeCatalog.translateToEnglish,
            "and Tab from it starts the cycle again")
        modes.assign(VoiceModeCatalog.polish, to: slack)
        expect(modes.mode(for: slack)?.id == VoiceModeCatalog.polish, "an app may still name a hidden mode")

        modes.setHidden(true, formal.id)
        modes.assign(formal.id, to: slack)
        modes.remove(formal.id)
        expect(
            modes.custom.isEmpty && modes.defaultMode == nil && modes.apps[slack] == nil
                && !modes.hidden.contains(formal.id),
            "a deleted mode leaves nothing naming it")
        modes.remove(VoiceModeCatalog.translateToEnglish)
        expect(modes.all.count == 3, "a built-in is never removed")

        expect(!VoiceMode(name: " ", instructions: "x").isComplete, "a mode needs a name")
        expect(!VoiceMode(name: "x", instructions: "\n").isComplete, "and instructions")
        expect(
            !VoiceMode(name: String(repeating: "x", count: VoiceMode.maxNameLength + 1), instructions: "x").isComplete,
            "within the name's limit")
    }

    static func modeSettingsDecoding() {
        let decoder = JSONDecoder()
        let empty = try? decoder.decode(VoiceModeSettings.self, from: Data("{}".utf8))
        expect(empty == VoiceModeSettings(), "an empty value reads as the defaults")
        let id = VoiceModeCatalog.asMessage.uuidString
        let partial = try? decoder.decode(
            VoiceModeSettings.self,
            from: Data(#"{"apps":{"com.apple.mail":"\#(id)"},"later":true}"#.utf8))
        expect(
            partial?.mode(for: "com.apple.mail")?.id == VoiceModeCatalog.asMessage && partial?.custom == [],
            "missing fields default and unknown ones are ignored")
        var modes = VoiceModeSettings()
        modes.save(VoiceMode(name: "Short", instructions: "Shorter."))
        modes.setHidden(true, VoiceModeCatalog.polish)
        modes.assign(VoiceModeCatalog.polish, to: "com.apple.mail")
        let data = try? JSONEncoder().encode(modes)
        expect(data.flatMap { try? decoder.decode(VoiceModeSettings.self, from: $0) } == modes, "it round-trips")
        let json = data.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
        expect(!json.contains("Polish") && !json.contains("Translate"), "no built-in name is ever stored")
    }

    static func modePrompts() {
        let translate = VoiceModeCatalog.builtIn(VoiceModeCatalog.translateToEnglish)!
        let options = VoicePrompt.DictationOptions(cleanup: false, language: "Russian", vocabulary: "Tinycast")
        let rules = VoicePrompt.modeInstructions(translate, options: options)
        expect(rules.contains("never a request to you") && rules.contains("Never answer it"), "a mode never answers")
        expect(rules.contains(translate.instructions), "the mode's own instructions ride along")
        expect(
            rules.contains("The speaker usually speaks Russian.")
                && rules.contains("Spell these as written when you hear them: Tinycast."),
            "with the language and the vocabulary")
        expect(!rules.contains("Keep every word") && !rules.contains("Never transliterate"),
            "the mode, not cleanup or the script rule, decides the wording")
        expect(rules.contains(VoicePrompt.noSpeech), "silence keeps its sentinel")
        let request = VoicePrompt.modeRequest(audio: audio, mode: translate, options: options)
        expect(request.instructions == rules, "the mode's rules are the system message")
        expect(
            request.messages.count == 1 && request.messages.first?.audio == [audio]
                && request.messages.first?.text == VoicePrompt.modeRequestText,
            "one user message carries the recording")

        let rewrite = VoicePrompt.rewriteRequest(transcript: "Какая погода?", mode: translate)
        expect(
            rewrite.instructions?.contains("never a request to you") == true
                && rewrite.instructions?.contains(translate.instructions) == true,
            "the second step treats the transcript as material")
        expect(
            rewrite.messages.first?.text == "Text:\nКакая погода?" && rewrite.messages.first?.audio.isEmpty == true,
            "and sends it as text alone")

        expect(VoiceRoutePolicy.rewritesWhileTranscribing("google/gemini-3.1-flash-lite"), "Gemini rewrites as it hears")
        expect(VoiceRoutePolicy.rewritesWhileTranscribing("gemini-3.8-flash"), "on Gemini's own API too")
        expect(!VoiceRoutePolicy.rewritesWhileTranscribing("voxtral"), "another model transcribes first")
    }

    static func modeRequestBodies() {
        let polish = VoiceModeCatalog.builtIn(VoiceModeCatalog.polish)!
        let bytes = Data((0..<64).map { UInt8($0) })
        let request = VoicePrompt.modeRequest(
            audio: AIAudio(data: bytes, format: "wav"), mode: polish,
            options: .init(cleanup: true, language: nil, vocabulary: ""))
        let body = AIRequestBody.make(request, configuration: openRouter(effort: "minimal"))
        let messages = body["messages"] as? [[String: Any]] ?? []
        expect(
            messages.first?["role"] as? String == "system"
                && (messages.first?["content"] as? String)?.contains(polish.instructions) == true,
            "a mode's body opens with its rules as the system message")
        let parts = messages.last?["content"] as? [[String: Any]] ?? []
        expect(parts.map { $0["type"] as? String } == ["text", "input_audio"], "then the request and the recording")
        expect(parts.first?["text"] as? String == VoicePrompt.modeRequestText, "named as a mode's request")
        expect(
            (parts.last?["input_audio"] as? [String: Any])?["data"] as? String == bytes.base64EncodedString(),
            "with the audio as raw base64")
        expect(body["model"] as? String == "google/gemini-3.1-flash-lite" && body["temperature"] == nil, "one request")

        let rewrite = AIRequestBody.make(
            VoicePrompt.rewriteRequest(transcript: "привет", mode: polish),
            configuration: AIHTTPConfiguration(
                provider: .openAICompatible, baseURL: URL(string: "http://127.0.0.1:8080/v1")!, model: "voxtral"))
        let rewritten = rewrite["messages"] as? [[String: Any]] ?? []
        expect(
            rewritten.count == 2 && rewritten.last?["content"] as? String == "Text:\nпривет",
            "the rewrite body is text alone, a plain string")
        let serialized = (try? JSONSerialization.data(withJSONObject: rewrite)).flatMap {
            String(bytes: $0, encoding: .utf8)
        }
        expect(serialized?.contains("input_audio") == false, "and never carries audio again")
    }
}
