import AppKit

/// The shipped voice coordinators against recorded effects: no network, microphone or Keychain.
@main
@MainActor
struct VoiceCoordinatorTests {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try await cloudConsent()
        try await cloudRouting()
        try await cloudModes()
        try await cloudModesTranscribeFirst()
        try await cloudContext()
        try await cloudContextWithoutVision()
        try await askConsent()
        try await askAnswer()
        try await askInsert()
        try await askNoSpeechAndRefusals()
        try await askSupersede()
        try await askCancelDuringCapture()
        try await askStartAndStopOrder()
        try await askHoldToTalk()
        try await askDismissAndSwitchOff()
        try await askAgent()
        try await askAgentRefusals()
        try await editReplaces()
        try await editSelectionMoved()
        try await editRefusalsAndFailures()
        print("ALL PASSED")
    }

    static let local = AIConnection(
        name: "Local", provider: .openAICompatible, baseURL: "http://127.0.0.1:8080/v1", models: ["voxtral"])
    static let router = AIConnection(name: "Router", provider: .openRouter)
    static let onLocal = AIModelSelection.api(connection: local.id, model: "voxtral", effort: nil)
    static let routerDictation = AIModelSelection.api(
        connection: router.id, model: "google/gemini-3.1-flash-lite", effort: "minimal")
    static let routerAsk = AIModelSelection.api(
        connection: router.id, model: "google/gemini-3.8-flash", effort: "low")

    // MARK: - Cloud transcription

    static func cloudConsent() async throws {
        let world = World(connections: [local])
        defer { world.tearDown() }
        let cloud = world.cloud
        expect(cloud.route == nil, "Before consent no recording has a destination")
        expect(cloud.proposal == onLocal, "The switch proposes the only server that can hear audio")

        world.core.answer = false
        cloud.setEnabled(true)
        try await wait { world.core.dialogs.count == 1 }
        try await settle()
        expect(
            !world.voice.cloudDictation && world.voice.dictationModel == nil, "A declined dialog stores nothing")
        let asked = world.core.dialogs[0]
        expect(asked.title == "Transcribe Dictation in the Cloud?", "Turning it on asks first")
        expect(
            asked.message.contains("Local") && asked.message.contains("voxtral"),
            "The dialog names the connection and the model")
        expect(
            asked.message.contains("with the name and window title of the app you dictate into, and a screenshot if"),
            "and, with Use the app in front on by default, what else goes with each recording")

        world.core.answer = true
        world.voice.appContext = .off
        cloud.setEnabled(true)
        try await wait { world.voice.cloudDictation }
        try await settle()
        expect(world.voice.dictationModel == onLocal, "Approval stores exactly the destination the dialog named")
        expect(
            world.core.dialogs[1].message.contains("keeps no copy of the audio")
                && !world.core.dialogs[1].message.contains("window title"),
            "With it Off, the dialog names the audio alone")
        world.voice.appContext = .title

        world.ai.save(router)
        expect(cloud.route == onLocal, "A connection added later never takes the audio")
        let dialogs = world.core.dialogs.count
        let whisper = AIModelSelection.api(connection: local.id, model: "whisper", effort: nil)
        cloud.choose(whisper)
        expect(
            world.voice.dictationModel == whisper && world.core.dialogs.count == dialogs,
            "Another model on the consented connection needs no new dialog")

        world.core.answer = false
        cloud.choose(routerDictation)
        try await wait { world.core.dialogs.count == dialogs + 1 }
        try await settle()
        expect(world.voice.dictationModel == whisper, "A declined switch keeps the consented route")
        let switched = world.core.dialogs[dialogs]
        expect(
            switched.title == "Send Dictation to Router?"
                && switched.message.contains("google/gemini-3.1-flash-lite"),
            "Another connection is asked for by name, with its model")
        world.core.answer = true
        cloud.choose(routerDictation)
        try await wait { world.voice.dictationModel == routerDictation }
        try await settle()

        world.core.holdDialogs = true
        cloud.choose(onLocal)
        try await wait { world.core.pendingDialogs == 1 }
        cloud.setEnabled(false)
        world.core.answerPending(true)
        try await settle()
        expect(
            !world.voice.cloudDictation && world.voice.dictationModel == routerDictation,
            "Turning it off while a switch is asked for cancels the switch")
    }

    static func cloudRouting() async throws {
        let world = World(connections: [local])
        defer { world.tearDown() }
        let cloud = world.cloud
        world.core.answer = true
        cloud.setEnabled(true)
        try await wait { world.voice.cloudDictation }

        world.ai.setRoute(.api(local.id), enabled: false)
        world.ai.save(router)
        expect(cloud.route == nil, "A disabled connection is never replaced by another")
        try await expectRefusal(cloud, "nor sent anything while disabled")
        world.ai.setRoute(.api(local.id), enabled: true)
        expect(cloud.route == onLocal, "Enabled again, it is the route again")

        world.voice.languages = ["Russian", "English"]
        world.voice.vocabulary = "Redcast"
        let transcription = Task { try await cloud.transcribe(speech) }
        try await wait { Network.streams.count == 1 }
        expect(Network.routes == [onLocal], "The recording goes to the consented route")
        let request = Network.requests[0]
        expect(
            request.instructions == VoicePrompt.dictationInstructions(cleanup: true)
                && request.messages.count == 1 && request.messages.first?.audio.count == 1,
            "as one audio part in one user turn, since a local server's template may insist on alternation")
        expect(
            request.messages.first?.text.hasPrefix("USER DICTIONARY") == true
                && request.messages.first?.text.contains("Russian, English") == true
                && request.messages.first?.text.hasSuffix("Transcribe the recording.") == true,
            "with the words to spell and the languages before the request")
        expect(request.temperature == VoiceRoutePolicy.dictationTemperature, "at a low temperature")
        Network.streams[0].yield(.text("“Привет, "))
        Network.streams[0].yield(.text("мир”"))
        Network.streams[0].finish()
        let transcript = try await transcription.value
        expect(transcript == "Привет, мир", "The streamed transcript is assembled and cleaned")
        expect(
            cloud.lastTranscription
                == .init(text: "Привет, мир", transcript: nil, mode: nil, model: "voxtral"),
            "Dictation History learns the model that heard it, with no mode")

        do {
            _ = try await cloud.transcribe([Float](repeating: 0, count: 32_000))
            expect(false, "Silence is refused")
        } catch {
            expect(error as? VoiceAIFailure == .noSpeech, "Silence is no speech")
            expect(cloud.lastTranscription == nil, "and leaves no transcript for the history")
        }
        try await settle()
        expect(Network.requests.count == 1, "and never leaves the Mac")

        world.ai.removeConnection(id: local.id)
        expect(cloud.route == nil, "A deleted connection is never replaced by another")
        try await expectRefusal(cloud, "nor sent anything once deleted")
        expect(cloud.proposal == routerDictation, "Only a new dialog may propose another")
    }

    static let slack = "com.tinyspeck.slackmacgap"
    static let frame = NSRect(x: 100, y: 100, width: 144, height: 44)

    static func cloudModes() async throws {
        let world = World(connections: [router])
        defer { world.tearDown() }
        let cloud = world.cloud
        let capsule = DictationPanelController()
        cloud.attach(to: capsule)
        world.frontmost = slack
        world.voice.modes.assign(VoiceModeCatalog.translateToEnglish, to: slack)
        capsule.onPlacement?(frame)
        expect(cloud.activeMode == nil && VoiceModeCaption.latest == nil, "With the cloud off no mode applies")
        expect(capsule.onTab?(false) == false, "and Tab passes through")

        world.settings.dictationEnabled = true
        world.core.answer = true
        cloud.setEnabled(true)
        try await wait { world.voice.cloudDictation }
        capsule.onPlacement?(frame)
        expect(cloud.activeMode?.id == VoiceModeCatalog.translateToEnglish, "The capsule takes the app's mode")
        let caption = VoiceModeCaption.latest
        expect(caption?.shown == "Translate to English" && caption?.frame == frame, "and names it above itself")

        expect(capsule.onTab?(false) == true, "Tab switches the mode")
        expect(
            cloud.activeMode?.id == VoiceModeCatalog.polish
                && world.voice.modes.mode(for: slack)?.id == VoiceModeCatalog.polish,
            "to the next one, remembered for the app in front")
        expect(caption?.shown == "Polish", "and the chip follows")
        expect(capsule.onTab?(true) == true && cloud.activeMode?.id == VoiceModeCatalog.translateToEnglish, "⇧Tab goes back")
        _ = capsule.onTab?(true)
        expect(cloud.activeMode == nil && caption?.shown == nil, "past the first mode is the plain transcript")
        expect(world.voice.modes.apps[slack] == nil, "and, being the default, leaves the app no entry")
        _ = capsule.onTab?(false)
        _ = capsule.onTab?(false)

        let transcription = Task { try await cloud.transcribe(speech) }
        try await wait { Network.streams.count == 1 }
        let polish = VoiceModeCatalog.builtIn(VoiceModeCatalog.polish)!
        let request = Network.requests[0]
        expect(
            request.instructions == VoicePrompt.modeInstructions(polish)
                && request.messages.last?.audio.count == 1,
            "Gemini hears the recording and the mode in one request")
        expect(VoiceAppContextReader.reads == [.title], "The capsule read the app in front by name and title")
        capsule.state.phase = .transcribing
        expect(capsule.onTab?(false) == false, "Tab no longer switches once the recording is sent")
        Network.streams[0].yield(.text("Готово."))
        Network.streams[0].finish()
        let typed = try await transcription.value
        expect(typed == "Готово.", "and its text is what is typed")
        expect(
            cloud.lastTranscription
                == .init(
                    text: "Готово.", transcript: nil, mode: "Polish", model: "google/gemini-3.1-flash-lite"),
            "Dictation History learns the mode, and one request leaves no separate transcript")

        capsule.onPlacement?(nil)
        expect(cloud.activeMode == nil && caption?.shown == nil, "Closing the capsule forgets the mode and the chip")
        expect(cloud.lastTranscription == nil, "and the transcript it noted")
        world.frontmost = "com.apple.mail"
        capsule.state.phase = .listening
        capsule.onPlacement?(frame)
        expect(cloud.activeMode == nil, "An app without a mode of its own follows the default, here none")

        world.frontmost = nil
        capsule.onPlacement?(nil)
        capsule.onPlacement?(frame)
        let remembered = (world.voice.modes.defaultMode, world.voice.modes.apps)
        expect(
            capsule.onTab?(false) == true && cloud.activeMode?.id == VoiceModeCatalog.translateToEnglish,
            "Over an app with no bundle id, Tab still switches this recording's mode")
        expect(
            world.voice.modes.defaultMode == remembered.0 && world.voice.modes.apps == remembered.1,
            "but remembers nothing, so the default mode for every app stays as it was")
    }

    static func cloudModesTranscribeFirst() async throws {
        let world = World(connections: [local])
        defer { world.tearDown() }
        world.settings.dictationEnabled = true
        world.core.answer = true
        world.cloud.setEnabled(true)
        try await wait { world.voice.cloudDictation }
        let capsule = DictationPanelController()
        world.cloud.attach(to: capsule)
        world.voice.modes.defaultMode = VoiceModeCatalog.asMessage
        capsule.onPlacement?(frame)
        let transcription = Task { try await world.cloud.transcribe(speech) }
        try await wait { Network.streams.count == 1 }
        let first = Network.requests[0]
        expect(
            first.instructions == VoicePrompt.dictationInstructions(cleanup: true)
                && first.messages.first?.text.hasSuffix("Transcribe the recording.") == true
                && first.messages.first?.audio.count == 1,
            "Another model first transcribes, as plain dictation")
        Network.streams[0].yield(.text("ну короче завтра в десять"))
        Network.streams[0].finish()
        try await wait { Network.streams.count == 2 }
        let second = Network.requests[1]
        let message = VoiceModeCatalog.builtIn(VoiceModeCatalog.asMessage)!
        expect(
            second.messages.first?.text == "Text:\nну короче завтра в десять"
                && second.messages.first?.audio.isEmpty == true
                && second.instructions?.contains(message.instructions) == true,
            "then rewrites the transcript as text, by the mode")
        expect(Network.routes == [onLocal], "both on the consented route")
        Network.streams[1].yield(.text("Завтра в десять."))
        Network.streams[1].finish()
        let rewritten = try await transcription.value
        expect(rewritten == "Завтра в десять.", "and the rewrite is typed")
        expect(
            world.cloud.lastTranscription
                == .init(
                    text: "Завтра в десять.", transcript: "ну короче завтра в десять", mode: "As a message",
                    model: "voxtral"),
            "Dictation History keeps the transcript the mode rewrote")
    }

    static func cloudContext() async throws {
        let world = World(connections: [router])
        defer { world.tearDown() }
        world.settings.dictationEnabled = true
        world.core.answer = true
        world.cloud.setEnabled(true)
        try await wait { world.voice.cloudDictation }
        let typed = AIModelSelection.api(connection: router.id, model: "google/gemini-3-flash-preview", effort: nil)
        world.cloud.choose(typed)
        expect(world.voice.dictationModel == typed, "A model typed on the consented connection is saved as typed")
        expect(world.voice.languages == ["English"] && world.voice.appContext == .title, "The defaults")
        let russian = VoiceAISettings(defaults: world.defaults, preferredLanguages: ["ru-RU"])
        expect(russian.languages == ["Russian", "English"], "A Russian Mac starts with English beside Russian")
        let capsule = DictationPanelController()
        world.cloud.attach(to: capsule)
        world.voice.vocabulary = "Redcast"
        world.voice.languages = ["Russian", "English"]
        world.voice.appContext = .screenshot
        let picture = AIImage(data: Data([0xFF, 0xD8]), mimeType: "image/jpeg")
        VoiceAppContextReader.next = VoiceAppContext(
            appName: "Slack", windowTitle: "general - Acme", screenshot: picture)
        capsule.onPlacement?(frame)
        try await settle()
        expect(
            VoiceAppContextReader.reads == [.screenshot] && VoiceAppContextReader.apps == [.current],
            "The capsule reads the app Dictation types into once, as allowed")

        let transcription = Task { try await world.cloud.transcribe(speech) }
        try await wait { Network.streams.count == 1 }
        expect(
            Network.routes == [.api(connection: router.id, model: "google/gemini-3-flash-preview", effort: "low")],
            "A Gemini Flash typed with no effort, unknown to the catalog, dictates at low")
        let request = Network.requests[0]
        expect(
            request.messages.count == 2 && request.messages[0].text.hasPrefix("USER DICTIONARY")
                && request.messages[0].text.contains("Russian, English") && request.messages[0].audio.isEmpty,
            "Gemini hears the dictionary and the languages in a turn of their own")
        expect(
            request.messages[1].text.hasPrefix("USER CONTEXT")
                && request.messages[1].text.contains("App: Slack\nWindow title: \"general - Acme\"\nScreenshot: attached")
                && request.messages[1].images == [picture] && request.messages[1].audio.count == 1,
            "then the app in front, its picture and the recording")
        expect(request.temperature == nil, "at Gemini's own temperature")
        Network.streams[0].yield(.text("Sure, here it is: <transcript>Созвонимся "))
        Network.streams[0].yield(.text("в субботу.</transcript>"))
        Network.streams[0].finish()
        let typedText = try await transcription.value
        expect(typedText == "Созвонимся в субботу.", "Only the tag's text is typed")

        capsule.onPlacement?(nil)
        world.voice.appContext = .off
        capsule.onPlacement?(frame)
        try await settle()
        expect(VoiceAppContextReader.reads == [.screenshot], "Off reads nothing")
        let plain = Task { try await world.cloud.transcribe(speech) }
        try await wait { Network.streams.count == 2 }
        expect(
            Network.requests[1].messages.last?.text == "Transcribe the recording."
                && Network.requests[1].messages.last?.images.isEmpty == true,
            "and sends no context")
        Network.streams[1].yield(.text("<transcript>[[NO_SPEECH]]</transcript>"))
        Network.streams[1].finish()
        do {
            _ = try await plain.value
            expect(false, "The sentinel in its tag types nothing")
        } catch {
            expect(error as? VoiceAIFailure == .noSpeech, "The sentinel in its tag is no speech")
        }

        capsule.onPlacement?(nil)
        world.voice.appContext = .screenshot
        world.dictated = nil
        capsule.onPlacement?(frame)
        try await settle()
        expect(VoiceAppContextReader.reads == [.screenshot], "Dictating into a Note reads nothing of the app behind it")
        let note = Task { try await world.cloud.transcribe(speech) }
        try await wait { Network.streams.count == 3 }
        expect(
            Network.requests[2].messages.last?.text == "Transcribe the recording."
                && Network.requests[2].messages.last?.images.isEmpty == true,
            "and sends none of it")
        Network.streams[2].yield(.text("<transcript>Заметка.</transcript>"))
        Network.streams[2].finish()
        _ = try await note.value

        capsule.onPlacement?(nil)
        world.dictated = .current
        VoiceAppContextReader.delay = .seconds(5)
        capsule.onPlacement?(frame)
        try await settle()
        let started = ContinuousClock.now
        let late = Task { try await world.cloud.transcribe(speech) }
        try await wait { Network.streams.count == 4 }
        expect(
            ContinuousClock.now - started < .seconds(2) && Network.requests[3].messages.last?.images.isEmpty == true
                && Network.requests[3].messages.last?.text == "Transcribe the recording.",
            "A capture still running when the recording ends is left behind after a short grace")
        Network.streams[3].yield(.text("<transcript>Поздно.</transcript>"))
        Network.streams[3].finish()
        _ = try await late.value
        VoiceAppContextReader.delay = nil
    }

    static func cloudContextWithoutVision() async throws {
        let world = World(connections: [local])
        defer { world.tearDown() }
        world.settings.dictationEnabled = true
        world.core.answer = true
        world.cloud.setEnabled(true)
        try await wait { world.voice.cloudDictation }
        let capsule = DictationPanelController()
        world.cloud.attach(to: capsule)
        world.voice.appContext = .screenshot
        VoiceAppContextReader.next = VoiceAppContext(
            appName: "Slack", windowTitle: "general", screenshot: AIImage(data: Data([0xFF]), mimeType: "image/jpeg"))
        capsule.onPlacement?(frame)
        try await settle()
        let transcription = Task { try await world.cloud.transcribe(speech) }
        try await wait { Network.streams.count == 1 }
        let request = Network.requests[0]
        expect(
            request.messages.count == 1 && request.messages[0].images.isEmpty
                && request.messages[0].text.contains("App: Slack\nWindow title: \"general\"\n\nTranscribe")
                && request.messages[0].audio.count == 1,
            "A model not known to see pictures gets the name and title but no screenshot, so it is not refused")
        Network.streams[0].yield(.text("<transcript>Да.</transcript>"))
        Network.streams[0].finish()
        _ = try await transcription.value
    }

    static func expectRefusal(_ cloud: VoiceCloudTranscriber, _ message: String) async throws {
        let before = Network.routes.count
        do {
            _ = try await cloud.transcribe(speech)
            expect(false, message)
        } catch {
            expect(
                error as? VoiceAIFailure == .noDictationModel && Network.routes.count == before,
                "A recording without its route is refused, \(message)")
        }
    }

    // MARK: - Ask by Voice

    static func askConsent() async throws {
        let world = World(connections: [router])
        defer { world.tearDown() }
        let ask = world.ask
        expect(ask.route == nil && ask.proposal == routerAsk, "Ask proposes Flash on OpenRouter before consent")

        world.core.answer = false
        ask.setEnabled(true)
        try await wait { world.core.dialogs.count == 1 }
        try await settle()
        expect(
            !world.voice.askEnabled && world.voice.askModel == nil && world.microphoneRequests == 0,
            "A declined dialog stores nothing and never asks for the microphone")
        expect(
            world.core.dialogs[0].title == "Enable Ask by Voice?"
                && world.core.dialogs[0].message.contains("Router")
                && world.core.dialogs[0].message.contains("google/gemini-3.8-flash"),
            "The dialog names the connection and the model")

        world.core.answer = true
        world.microphone = false
        ask.setEnabled(true)
        try await wait { world.microphoneRequests == 1 }
        try await settle()
        expect(
            !world.voice.askEnabled && world.voice.askModel == nil
                && world.core.messages == ["Allow Tinycast to use the microphone in System Settings"],
            "Without the microphone nothing is enabled or stored")

        world.microphone = true
        let ensured = Permissions.ensured
        ask.setEnabled(true)
        try await wait { world.voice.askEnabled }
        try await settle()
        expect(world.voice.askModel == routerAsk, "Approval stores exactly the destination the dialog named")
        expect(Permissions.ensured == ensured + 1, "then Accessibility is asked for")

        world.ai.save(local)
        expect(ask.route == routerAsk, "A connection added later never hears a question")
        let dialogs = world.core.dialogs.count
        world.core.answer = false
        ask.choose(onLocal)
        try await wait { world.core.dialogs.count == dialogs + 1 }
        try await settle()
        expect(
            world.voice.askModel == routerAsk && world.core.dialogs[dialogs].title == "Send Ask by Voice to Local?",
            "Another connection asks again, and a refusal keeps the route")
        world.core.answer = true
        ask.choose(onLocal)
        try await wait { world.voice.askModel == onLocal }
        try await settle()
        expect(world.microphoneRequests == 2, "A switch asks only for consent")

        world.ai.removeConnection(id: local.id)
        expect(ask.route == nil, "A deleted connection is never replaced by another")
        ask.pressed()
        expect(
            world.core.messages.last == "Choose a model for Ask by Voice in Settings → AI.",
            "A press without its route is refused")
        expect(DictationCapture.latest == nil && Network.routes.isEmpty, "before anything is recorded or sent")
    }

    static func askAnswer() async throws {
        let world = try await World.asking()
        defer { world.tearDown() }
        let ask = world.ask
        ask.pressed()
        try await wait { world.recorder?.isRecording == true && DictationPanelController.latest?.isVisible == true }
        expect(world.ducker.begins == 1, "Recording ducks the volume")
        ask.pressed()
        try await wait { Network.streams.count == 1 }
        expect(Network.routes == [routerAsk], "The question goes to the consented route")
        expect(world.ducker.begins == world.ducker.ends, "and the volume is back once it is sent")
        let request = Network.requests[0]
        expect(
            request.messages.first?.audio.count == 1
                && request.messages.first?.text.contains("Window text") == true,
            "with the recording and the window's text")

        Network.streams[0].yield(.text("ANSWER\nQ: Что это?\n\nЭто "))
        try await wait { world.panel?.state != nil }
        let panel = world.panel!.state!
        expect(panel.title == "Что это?" && panel.text == "Это ", "An answer opens the panel titled by the question")
        expect(DictationPanelController.latest?.isVisible == false, "and closes the capsule")
        Network.streams[0].yield(.text("окно."))
        Network.streams[0].finish()
        try await wait { panel.finished != nil }
        expect(panel.finished == "Это окно." && panel.text == "Это окно.", "and streams the rest into it")
        let asked = world.history.first
        expect(
            world.history.count == 1 && asked?.kind == .ask && asked?.text == "Это окно."
                && asked?.transcript == "Что это?" && asked?.model == "google/gemini-3.8-flash"
                && asked?.engine == .cloud && asked?.duration == nil,
            "Dictation History keeps the question and the answer, marked as an Ask")

        world.panel?.onReplace?("Это окно.")
        world.injector.drain()
        expect(world.injector.delivered == ["Это окно."], "↵ types the answer into the app it came from")
        world.panel?.onContinueInChat?("Это окно.")
        let continued = world.core.aiChatCoordinator.continued
        expect(
            continued.count == 1 && continued[0].model == routerAsk
                && continued[0].prompt.hasPrefix("Что это?\n\n"),
            "⌘J continues on the same route, seeded with the question and the screen")
    }

    static func askInsert() async throws {
        let world = try await World.asking()
        defer { world.tearDown() }
        try await world.askAndReply("INSERT\nQ: Ответь\n\n«Приду в десять»")
        try await wait { world.injector.queued == 1 }
        world.injector.drain()
        expect(world.injector.delivered == ["Приду в десять"], "An INSERT is typed into the focused field")
        expect(
            world.history.last?.text == "Приду в десять" && world.history.last?.transcript == "Ответь",
            "and kept in Dictation History with what was asked")
        expect(world.panel == nil, "with no panel")

        try await world.askAndReply("INSERT\nQ: Ответь\n\nПоздно", stream: 1)
        try await wait { world.injector.queued == 1 }
        world.ask.pressed()
        world.injector.drain()
        expect(world.injector.delivered.count == 1, "A new press keeps a queued INSERT from being typed")
        DictationPanelController.latest?.onCancel?()

        world.screen.focused = false
        try await world.askAndReply("INSERT\nQ: Ответь\n\nТекст", stream: 2)
        try await wait { world.panel?.state?.finished != nil }
        expect(
            world.panel?.state?.finished == "Текст" && world.injector.delivered.count == 1,
            "Without a focused field it is shown for ↵ instead")

        world.screen.focused = true
        world.injector.fails = true
        try await world.askAndReply("INSERT\nQ: Ответь\n\nЕщё", stream: 3)
        try await wait { world.injector.queued == 1 }
        world.injector.drain()
        try await wait { world.panel?.state?.finished == "Ещё" }
        expect(
            world.core.messages.last == "Couldn't type into this app — the reply is shown instead.",
            "A failed delivery shows the reply and says so")
    }

    static func askNoSpeechAndRefusals() async throws {
        let world = try await World.asking()
        defer { world.tearDown() }
        let ask = world.ask
        ask.pressed()
        try await wait { world.recorder?.isRecording == true }
        world.recorder?.samples = [Float](repeating: 0, count: 32_000)
        ask.pressed()
        try await wait { world.core.messages.last == "No speech was recorded" }
        try await settle()
        expect(Network.streams.isEmpty, "Silence is never sent")

        world.recorder?.samples = speech
        try await world.askAndReply("ANSWER\nQ:\n\n[[NO_SPEECH]]")
        try await wait { world.core.messages.count == 2 }
        expect(
            world.core.messages.last == "No speech was recorded" && world.panel == nil,
            "The no-speech sentinel is a message, never a panel")
        expect(world.history.isEmpty, "and nothing reaches Dictation History")

        world.settings.dictationEnabled = true
        world.core.dictationCoordinator.isBusy = true
        let starts = world.recorder?.starts
        ask.pressed()
        expect(
            world.core.messages.last == "Finish the current dictation first." && world.recorder?.starts == starts,
            "A press while Dictation records is refused")
        world.core.dictationCoordinator.isBusy = false

        Network.failure = .unavailable("Add an API key in Settings.")
        ask.pressed()
        expect(
            world.core.messages.last == "Add an API key in Settings." && world.recorder?.starts == starts,
            "A missing key is refused before anything is recorded")
        Network.failure = nil

        Permissions.trusted = false
        ask.pressed()
        expect(
            world.core.screenAwarenessCoordinator.refusals == 1 && world.recorder?.starts == starts,
            "Without Accessibility Screen Awareness's dialog refuses")
        Permissions.trusted = true
    }

    static func askSupersede() async throws {
        let world = try await World.asking()
        defer { world.tearDown() }
        try await world.askAndReply("ANSWER\nQ: Первый?\n\nСтарый", finishing: false)
        try await wait { world.panel?.state?.text == "Старый" }
        let first = world.panel!.state!
        world.ask.pressed()
        try await wait { Network.cancelled == 1 && world.recorder?.isRecording == true }
        expect(world.panel?.state == nil, "A press while replying dismisses the old answer")
        expect(world.recorder?.starts == 2, "and records the next question")
        Network.streams[0].yield(.text(" и лишнее"))
        world.ask.pressed()
        try await wait { Network.streams.count == 2 }
        Network.streams[1].yield(.text("ANSWER\nQ: Второй?\n\nНовый"))
        Network.streams[1].finish()
        try await wait { world.panel?.state?.finished != nil }
        expect(
            world.panel?.state?.title == "Второй?" && world.panel?.state?.finished == "Новый",
            "The new question gets its own answer")
        expect(first.finished == nil && first.text == "Старый", "and the superseded one never changes again")

        world.ask.pressed()
        try await wait { world.recorder?.isRecording == true }
        world.ask.pressed()
        try await wait { Network.streams.count == 3 }
        world.ask.pressed()
        try await wait { Network.cancelled == 2 }
        expect(world.recorder?.isRecording == true, "A press before any answer shows also stops that reply")
        expect(world.recorder?.overlapped == false, "One recorder never ran two sessions")
    }

    static func askCancelDuringCapture() async throws {
        let world = try await World.asking()
        defer { world.tearDown() }
        world.screen.holdCapture = true
        world.ask.pressed()
        try await wait { world.recorder?.isRecording == true && world.screen.pending != nil }
        world.ask.pressed()
        try await wait { world.recorder?.isRecording == false }
        // The recording is encoded by now, so the reply waits on the capture alone.
        try await settle()
        DictationPanelController.latest?.onCancel?()
        world.screen.release()
        try await settle()
        expect(Network.requests.isEmpty, "A capture that lands after Escape sends nothing")
        expect(world.panel == nil && world.core.messages.isEmpty, "and shows nothing")
        world.screen.holdCapture = false
        try await world.askAndReply("ANSWER\nQ: Снова\n\nДа")
        try await wait { world.panel?.state?.finished == "Да" }
    }

    static func askStartAndStopOrder() async throws {
        let world = try await World.asking()
        defer { world.tearDown() }
        let ask = world.ask
        ask.pressed()
        try await wait { world.recorder?.isRecording == true }
        let recorder = world.recorder!
        recorder.holdStop = true
        DictationPanelController.latest?.onCancel?()
        try await wait { recorder.pendingStop != nil }
        ask.pressed()
        try await settle()
        expect(recorder.starts == 1, "A new recording waits for the last one to stop")
        recorder.releaseStop()
        try await wait { recorder.starts == 2 && recorder.isRecording }
        recorder.holdStop = false
        DictationPanelController.latest?.onCancel?()
        try await wait { !recorder.isRecording }

        recorder.holdStart = true
        ask.pressed()
        try await wait { recorder.pendingStart != nil }
        ask.pressed()
        recorder.releaseStart()
        try await wait { Network.streams.count == 1 }
        expect(recorder.stops == 3, "A press while starting finishes the recording once it has started")
        DictationPanelController.latest?.onCancel?()

        ask.pressed()
        try await wait { recorder.pendingStart != nil }
        DictationPanelController.latest?.onCancel?()
        try await settle()
        expect(recorder.stops == 3, "Cancelling a start stops nothing yet")
        recorder.releaseStart()
        try await wait { recorder.stops == 4 }
        expect(!recorder.isRecording, "then stops what started, so the microphone never stays on")
        expect(!recorder.overlapped, "and never overlapped a start with a stop")
        expect(world.ducker.begins == world.ducker.ends, "The volume is back after every ending")
    }

    static func askHoldToTalk() async throws {
        let world = try await World.asking()
        defer { world.tearDown() }
        world.voice.askMode = .pushToTalk
        world.hotKeys.bindings[.command(.askByVoice)] = .init(shortcut: 1)
        expect(world.ask.holdShortcutIssue == nil, "A combination can be held")
        world.ask.pressed()
        try await wait { world.recorder?.isRecording == true }
        world.ask.released()
        try await wait { Network.streams.count == 1 }

        Network.streams[0].finish()
        try await wait { !world.core.messages.isEmpty }
        world.ask.applyHoldMode()
        expect(
            world.hotKeys.heldCommands == [.askByVoice, .editByVoice],
            "Hold mode lends a single modifier to both voice commands")
        world.hotKeys.bindings[.command(.askByVoice)] = .init(shortcut: nil, holdKey: 1)
        expect(world.ask.holdShortcutIssue == nil, "A single modifier can be held")
        world.ask.pressed()
        try await wait { world.recorder?.isRecording == true }
        world.ask.released()
        try await wait { Network.streams.count == 2 }
        Network.streams[1].finish()
        try await wait { world.core.messages.count == 2 }
        world.hotKeys.conflict = "Dictation"
        expect(
            world.ask.holdShortcutIssue == "This shortcut is also used by Dictation. Record another shortcut.",
            "A modifier another hold reserves is named")
        world.hotKeys.conflict = nil
        world.hotKeys.bindings[.command(.askByVoice)] = .init(shortcut: nil)
        expect(world.ask.holdShortcutIssue != nil, "A double tap in hold mode says it acts as a toggle")
        world.ask.pressed()
        try await wait { world.recorder?.isRecording == true }
        world.ask.released()
        try await settle()
        expect(world.recorder?.isRecording == true, "and its release does not end the recording")
        world.ask.pressed()
        try await wait { Network.streams.count == 3 }
        world.voice.askMode = .toggle
        world.ask.applyHoldMode()
        expect(world.hotKeys.heldCommands.isEmpty, "and toggle mode takes it back")
    }

    static func askDismissAndSwitchOff() async throws {
        let world = try await World.asking()
        defer { world.tearDown() }
        try await world.askAndReply("ANSWER\nQ: Долгий?\n\nНачало", finishing: false)
        try await wait { world.panel?.state?.text == "Начало" }
        let panel = world.panel!.state!
        world.panel?.dismiss()
        try await wait { Network.cancelled == 1 }
        Network.streams[0].yield(.text(" и конец"))
        Network.streams[0].finish()
        try await settle()
        expect(panel.text == "Начало" && panel.finished == nil, "Dismissing a streaming answer cancels it")

        try await world.askAndReply("ANSWER\nQ: Короткий?\n\nДа", stream: 1)
        try await wait { world.panel?.state?.finished == "Да" }
        world.panel?.dismiss()
        try await settle()
        expect(Network.cancelled == 1, "Dismissing a finished answer cancels nothing")

        world.ask.pressed()
        try await wait { world.recorder?.isRecording == true }
        world.ask.setEnabled(false)
        world.ask.applyEnabled()
        try await wait { world.recorder?.isRecording == false }
        expect(world.appIndex.visible == false, "Turning it off hides the row and stops the recording")
        try await settle()
        expect(Network.streams.count == 2 && world.ducker.begins == world.ducker.ends, "sending nothing")
        world.ask.pressed()
        expect(world.recorder?.starts == 3, "and its shortcut does nothing")
    }

    // MARK: - Ask an agent

    static func askAgent() async throws {
        let world = try await World.asking()
        defer { world.tearDown() }
        let coder = AgentProfile(id: UUID(), name: "Coder")
        world.core.agentCoordinator.agents = [coder]
        world.voice.askAgent = coder.id
        world.voice.vocabulary = "Tinycast"
        world.settings.screenAwarenessScreenshot = true
        expect(world.ask.agent?.id == coder.id, "An agent can answer Ask by Voice")

        world.ask.pressed()
        try await wait { world.recorder?.isRecording == true }
        world.ask.pressed()
        try await wait { Network.streams.count == 1 }
        expect(world.screen.screenshots == [true], "The window is read with its picture, for the agent's model")
        let request = Network.requests[0]
        let fixture = VoicePrompt.agentRequest(audio: AIAudio(data: Data(), format: "wav"), vocabulary: "Tinycast")
        expect(
            Network.routes == [routerAsk] && request.instructions == fixture.instructions,
            "The request is only written down, as dictation on Ask by Voice's route")
        expect(
            request.messages.count == 2 && request.messages[0].text.hasPrefix("USER DICTIONARY")
                && request.messages[1].text == VoicePrompt.transcribeRequest
                && request.messages[1].audio.count == 1 && request.messages.allSatisfy(\.images.isEmpty),
            "and the voice route hears only the words to spell, never the window's text or picture")
        Network.streams[0].yield(.text("«Проверь эту "))
        Network.streams[0].yield(.text("страницу»"))
        Network.streams[0].finish()
        let runs = world.core.agentCoordinator.background
        try await wait { runs.started.count == 1 }
        expect(
            runs.started[0].task == "Проверь эту страницу" && runs.started[0].agent == coder.id,
            "The agent runs the transcript as its background task")
        expect(runs.started[0].attachments.map(\.name) == ["Fixture", "picture"], "with the window attached")
        expect(
            world.panel == nil && DictationPanelController.latest?.isVisible == false
                && world.ducker.begins == world.ducker.ends,
            "No panel opens and the capsule closes")

        world.core.paletteCoordinator.isVisible = true
        world.core.paletteCoordinator.targetApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock"
        ).first
        QuickActionRunner.selected = "Hello"
        try await world.editAndReply("INSERT\nQ: Короче\n\nHi", stream: 1)
        try await wait { world.injector.queued == 1 }
        expect(
            Network.requests[1].instructions == VoicePrompt.editInstructions && runs.started.count == 1,
            "Editing a selection stays with the model")
        world.core.paletteCoordinator.isVisible = false

        try await world.askAndReply("[[NO_SPEECH]]", stream: 2)
        try await wait { world.core.messages.last == "No speech was recorded" }
        expect(runs.started.count == 1, "Silence starts no run")

        world.ask.pressed()
        try await wait { world.recorder?.isRecording == true }
        world.ask.pressed()
        try await wait { Network.streams.count == 4 }
        DictationPanelController.latest?.onCancel?()
        Network.streams[3].yield(.text("Поздно"))
        Network.streams[3].finish()
        try await settle()
        expect(runs.started.count == 1, "Escape while it is written down starts nothing")

        world.core.agentCoordinator.agents = []
        expect(world.ask.agent == nil, "A deleted agent leaves the model to answer")
        try await world.askAndReply("ANSWER\nQ: Что?\n\nЭто", stream: 4)
        try await wait { world.panel?.state?.finished == "Это" }
        expect(Network.requests[4].instructions == VoicePrompt.askInstructions, "as an ordinary question")
    }

    static func askAgentRefusals() async throws {
        let world = try await World.asking()
        defer { world.tearDown() }
        let coder = AgentProfile(id: UUID(), name: "Coder")
        world.core.agentCoordinator.agents = [coder]
        world.voice.askAgent = coder.id
        world.core.agentCoordinator.runs = AgentRunLedger(busy: [coder.id], activeCount: 1)
        world.ask.pressed()
        expect(
            world.core.messages.last == "Coder is still working on another task" && world.recorder == nil,
            "An agent still at work refuses the press before anything is recorded")
        world.core.agentCoordinator.runs = AgentRunLedger(busy: [], activeCount: 3)
        world.ask.pressed()
        expect(
            world.core.messages.last == "Three agents are already running" && world.recorder == nil,
            "as do three running agents")
        world.core.agentCoordinator.runs = AgentRunLedger(busy: [], activeCount: 2)
        world.ask.pressed()
        try await wait { world.recorder?.isRecording == true }
        expect(Network.requests.isEmpty, "Room for one more records, and sends only once finished")
    }

    // MARK: - Edit Selection by Voice

    static func editReplaces() async throws {
        let world = try await World.editing(selected: "  Hello, world.\n")
        defer { world.tearDown() }
        try await world.editAndReply("INSERT\nQ: Короче\n\n«Hi.»")
        let request = Network.requests[0]
        expect(request.instructions == VoicePrompt.editInstructions, "An edit carries its own rules")
        expect(
            request.messages.first?.text == "Text:\n  Hello, world.\n" && request.messages.first?.audio.count == 1,
            "with the selection as material and the spoken instruction")
        try await wait { world.injector.queued == 1 }
        world.injector.drain()
        expect(world.injector.replaced == ["  Hi.\n"], "The unchanged selection is replaced, keeping its outer space")
        expect(
            world.history.count == 1 && world.history[0].kind == .edit && world.history[0].text == "  Hi.\n"
                && world.history[0].transcript == "Короче" && world.history[0].bundleID == "com.apple.dock",
            "Dictation History keeps the edit and the instruction, marked as an edit")
        expect(QuickActionRunner.reads == 2 && world.panel == nil, "after reading it again, with no panel")
        expect(world.ducker.begins == world.ducker.ends, "and the volume is back")

        world.voice.vocabulary = "Tinycast"
        try await world.editAndReply("Shorter.", stream: 1)
        let spelled = Network.requests[1].messages.first?.text ?? ""
        expect(
            spelled.hasPrefix("Spell these as written when you hear them: Tinycast.\n\nText:\n"),
            "The vocabulary comes before the selection")
        try await wait { world.injector.queued == 1 }
        world.injector.drain()
        expect(world.injector.replaced.last == "  Shorter.\n", "A reply without its header is the edit whole")
    }

    static func editSelectionMoved() async throws {
        let world = try await World.editing(selected: "Hello, world.")
        defer { world.tearDown() }
        try await world.editAndReply("INSERT\nQ: Короче\n\nHi.", finishing: false)
        QuickActionRunner.selected = "Something else"
        Network.streams[0].finish()
        try await wait { world.panel?.state?.finished != nil }
        let panel = world.panel!.state!
        expect(
            panel.title == "Короче" && panel.finished == "Hi." && world.injector.queued == 0,
            "A selection that moved is never replaced: the panel shows the edit, titled by the instruction")
        expect(
            world.core.messages.last == "The selection changed, so the result is shown instead.",
            "and says why")
        world.panel?.onContinueInChat?("Hi.")
        expect(
            world.core.aiChatCoordinator.continued.last?.prompt == "Короче\n\nHello, world."
                && world.core.aiChatCoordinator.continued.last?.model == routerAsk,
            "⌘J seeds a chat with the instruction and the original text")
        world.panel?.onReplace?("Hi.")
        world.injector.drain()
        expect(world.injector.delivered == ["Hi."], "↵ types it over whatever is selected now")
    }

    static func editRefusalsAndFailures() async throws {
        let world = try await World.editing(selected: "Hello")
        defer { world.tearDown() }
        QuickActionRunner.failure = .noSelection
        world.ask.pressed(.editByVoice)
        try await wait { world.core.messages.last == "Select some text first." }
        try await wait { world.recorder?.isRecording == false }
        try await settle()
        expect(Network.requests.isEmpty && world.ducker.begins == world.ducker.ends, "Nothing selected: nothing is sent")
        QuickActionRunner.failure = nil

        try await world.editAndReply("INSERT\nQ:\n\n[[NO_SPEECH]]")
        try await wait { world.core.messages.last == "No speech was recorded" }
        expect(world.panel == nil && world.injector.queued == 0, "Silence edits nothing")

        world.injector.fails = true
        try await world.editAndReply("INSERT\nQ: Короче\n\nHi", stream: 1)
        try await wait { world.injector.queued == 1 }
        world.injector.drain()
        try await wait { world.panel?.state?.finished == "Hi" }
        expect(
            world.core.messages.last == "Couldn't replace the selection — the result is shown instead.",
            "A replacement that fails shows the edit and says so")
        world.injector.fails = false

        VoiceSelectionAccess.writable = false
        try await world.editAndReply("INSERT\nQ: Короче\n\nRead-only", stream: 2)
        try await wait { world.panel?.state?.finished == "Read-only" }
        expect(
            world.injector.queued == 0 && QuickActionRunner.reads == 5,
            "A selection that cannot be written is shown, not pasted where it would land nowhere")
        VoiceSelectionAccess.writable = true

        world.core.paletteCoordinator.targetApp = nil
        world.ask.pressed(.editByVoice)
        expect(
            world.core.messages.last == "Select text in another app first." && Network.requests.count == 3,
            "Without an app to edit nothing starts")
    }

    // MARK: - Helpers

    static let speech: [Float] = (0..<16_000).map {
        0.2 * Float(sin(2 * Double.pi * 220 * Double($0) / Double(VoiceAudio.sampleRate)))
    }

    static func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CocoaError(.coderInvalidValue) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Long enough for every hop the coordinators make to land.
    static func settle() async throws {
        try await Task.sleep(for: .milliseconds(60))
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        print("PASS  \(message)")
    }
}

@MainActor
final class World {
    let suite = "tinycast.voice-coordinator-test.\(UUID())"
    let defaults: UserDefaults
    let settings = AppSettings()
    let ai: AISettingsStore
    let voice: VoiceAISettings
    let core = AppCore()
    let hotKeys = HotKeyManager()
    let injector = TextInjector()
    let ducker = DictationAudioDucker()
    let appIndex = AppIndex()
    var microphone = true
    var microphoneRequests = 0
    var history: [DictationHistoryEntry] = []
    var frontmost: String?
    var dictated: NSRunningApplication? = .current
    var screen: ScreenAwarenessCoordinator { core.screenAwarenessCoordinator }
    var recorder: DictationCapture? { DictationCapture.latest }
    var panel: QuickActionPanelController? { QuickActionPanelController.latest }

    lazy var cloud = VoiceCloudTranscriber(
        settings: settings, voice: voice, aiSettings: ai,
        confirm: { [core] in
            await core.confirm(
                title: $0, message: $1, symbol: nil, confirmTitle: "Continue", tone: .neutral,
                confirmRole: .standard)
        },
        frontmostBundleID: { [weak self] in self?.frontmost },
        dictatedApp: { [weak self] in self?.dictated })
    lazy var ask = VoiceAskCoordinator(
        settings: settings, voice: voice, aiSettings: ai, appIndex: appIndex, hotKeys: hotKeys,
        injector: injector, audioDucker: ducker, core: core,
        requestMicrophone: { [weak self] in
            guard let self else { return false }
            microphoneRequests += 1
            return microphone
        },
        history: { [weak self] in self?.history.append($0) })

    init(connections: [AIConnection]) {
        defaults = UserDefaults(suiteName: suite)!
        ai = AISettingsStore(defaults: defaults)
        voice = VoiceAISettings(defaults: defaults, preferredLanguages: ["en-US", "xx"])
        connections.forEach(ai.save)
        Network.reset()
        QuickActionRunner.reset()
        VoiceSelectionAccess.writable = true
        VoiceAppContextReader.next = nil
        VoiceAppContextReader.reads = []
        VoiceAppContextReader.apps = []
        VoiceAppContextReader.delay = nil
        DictationCapture.latest = nil
        DictationPanelController.latest = nil
        VoiceModeCaption.latest = nil
        QuickActionPanelController.latest = nil
    }

    /// Ask by Voice switched on over OpenRouter, the way the settings toggle does it.
    static func asking() async throws -> World {
        let world = World(connections: [VoiceCoordinatorTests.router])
        world.core.answer = true
        world.ask.setEnabled(true)
        try await VoiceCoordinatorTests.wait { world.voice.askEnabled }
        try await VoiceCoordinatorTests.settle()
        world.core.dialogs = []
        world.core.messages = []
        return world
    }

    /// Ask by Voice on, with `selected` selected in an app behind the palette.
    static func editing(selected: String) async throws -> World {
        let world = try await asking()
        world.core.paletteCoordinator.isVisible = true
        world.core.paletteCoordinator.targetApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock"
        ).first
        QuickActionRunner.selected = selected
        return world
    }

    /// One spoken edit, recorded and sent, then `reply` streamed back on stream number `stream`.
    func editAndReply(_ reply: String, stream: Int = 0, finishing: Bool = true) async throws {
        ask.pressed(.editByVoice)
        try await VoiceCoordinatorTests.wait { recorder?.isRecording == true }
        ask.pressed(.editByVoice)
        try await VoiceCoordinatorTests.wait { Network.streams.count == stream + 1 }
        Network.streams[stream].yield(.text(reply))
        if finishing { Network.streams[stream].finish() }
    }

    /// One question, recorded and sent, then `reply` streamed back on stream number `stream`.
    func askAndReply(_ reply: String, stream: Int = 0, finishing: Bool = true) async throws {
        ask.pressed()
        try await VoiceCoordinatorTests.wait { recorder?.isRecording == true }
        ask.pressed()
        try await VoiceCoordinatorTests.wait { Network.streams.count == stream + 1 }
        Network.streams[stream].yield(.text(reply))
        if finishing { Network.streams[stream].finish() }
    }

    func tearDown() {
        ask.prepareForTermination()
        defaults.removePersistentDomain(forName: suite)
    }
}

// MARK: - Recorded effects

@MainActor
enum Network {
    static var routes: [AIModelSelection] = []
    static var requests: [AIRequest] = []
    static var streams: [AIProviderStream.Continuation] = []
    static var cancelled = 0
    static var failure: AIProviderError?
    /// A stream an earlier test left behind may still end; its hop must not count in this one.
    static var generation = 0

    static func reset() {
        generation += 1
        routes = []
        requests = []
        streams = []
        cancelled = 0
        failure = nil
    }
}

@MainActor
enum VoiceAIRoute {
    static func provider(for selection: AIModelSelection, settings: AISettingsStore) throws -> any AIProvider {
        Network.routes.append(selection)
        if let failure = Network.failure { throw failure }
        return RecordedProvider(generation: Network.generation)
    }
}

struct RecordedProvider: AIProvider {
    let generation: Int

    func stream(_ request: AIRequest) -> AIProviderStream {
        let (stream, continuation) = AIProviderStream.makeStream()
        continuation.onTermination = { [generation] termination in
            guard case .cancelled = termination else { return }
            Task { @MainActor in
                if generation == Network.generation { Network.cancelled += 1 }
            }
        }
        Task { @MainActor [generation] in
            guard generation == Network.generation else { return }
            Network.requests.append(request)
            Network.streams.append(continuation)
        }
        return stream
    }
}

struct InterfaceSize {
    let metrics = 0
}

@MainActor
final class AppSettings {
    var aiEnabled = true
    var screenAwarenessEnabled = true
    var screenAwarenessScreenshot = false
    var dictationEnabled = false
    var dictationMicrophone: String?
    let interfaceSize = InterfaceSize()
}

enum CommandID: Hashable {
    case askByVoice
    case editByVoice
    var name: String { self == .askByVoice ? "Ask by Voice" : "Edit Selection by Voice" }
    var sfSymbol: String { self == .askByVoice ? "waveform" : "pencil.and.scribble" }
}

@MainActor
enum VoiceAppContextReader {
    static var next: VoiceAppContext?
    static var reads: [VoiceAppContext.Level] = []
    static var apps: [NSRunningApplication] = []
    static var delay: Duration?

    static func read(_ level: VoiceAppContext.Level, of app: NSRunningApplication) async -> VoiceAppContext? {
        reads.append(level)
        apps.append(app)
        if let delay { try? await Task.sleep(for: delay) }
        return next
    }
}

@MainActor
enum VoiceSelectionAccess {
    static var writable = true
    static func isWritable(in app: NSRunningApplication) -> Bool { writable }
}

@MainActor
enum QuickActionRunner {
    static var selected = ""
    static var failure: QuickActionFailure?
    static var reads = 0

    static func reset() {
        selected = ""
        failure = nil
        reads = 0
    }

    static func selection(in app: NSRunningApplication?, using injector: TextInjector) async throws -> String {
        reads += 1
        if let failure { throw failure }
        return selected
    }
}

enum HotKeyAction: Hashable {
    case command(CommandID)
}

@MainActor
final class HotKeyManager {
    struct Binding {
        var shortcut: Int?
        var holdKey: Int?
    }
    var bindings: [HotKeyAction: Binding] = [:]
    var heldCommands: Set<CommandID> = []
    var conflict: String?
    func binding(for action: HotKeyAction) -> Binding? { bindings[action] }
    func conflictOwner(of binding: Binding, excluding action: HotKeyAction) -> String? { conflict }
}

@MainActor
final class AppIndex {
    var visible: Bool?
    func setCommandsVisible(_ commands: Set<CommandID>, _ visible: Bool) { self.visible = visible }
}

enum DialogTone { case success, neutral, danger }

enum DialogAction {
    enum Role { case standard }
}

@MainActor
final class AppCore {
    let dictationCoordinator = DictationCoordinator()
    let agentCoordinator = AgentCoordinator()
    let screenAwarenessCoordinator = ScreenAwarenessCoordinator()
    let paletteCoordinator = PaletteCoordinator()
    let aiChatCoordinator = AIChatCoordinator()
    var messages: [String] = []
    var dialogs: [(title: String, message: String)] = []
    var answer = false
    var holdDialogs = false
    var pendingDialogs = 0
    private var held: [CheckedContinuation<Bool, Never>] = []

    func showMessage(_ message: String, tone: DialogTone = .success) { messages.append(message) }

    func confirm(
        title: String, message: String?, symbol: String?, confirmTitle: String, tone: DialogTone,
        confirmRole: DialogAction.Role
    ) async -> Bool {
        dialogs.append((title, message ?? ""))
        guard holdDialogs else { return answer }
        pendingDialogs += 1
        defer { pendingDialogs -= 1 }
        return await withCheckedContinuation { held.append($0) }
    }

    func answerPending(_ approved: Bool) {
        let waiting = held
        held = []
        waiting.forEach { $0.resume(returning: approved) }
    }
}

@MainActor
final class DictationCoordinator {
    var isBusy = false
}

@MainActor
final class PaletteCoordinator {
    var isVisible = false
    var targetApp: NSRunningApplication?
    func hidePalette(restoreFocus: Bool) {}
}

@MainActor
final class AIChatCoordinator {
    var continued: [(prompt: String, model: AIModelSelection?)] = []
    func continueQuickAction(prompt: String, reply: String, model: AIModelSelection?) {
        continued.append((prompt, model))
    }
}

@MainActor
final class ScreenAwarenessCoordinator {
    struct Capture: Sendable {
        let context: ScreenContext
        let screenshot: Data?
    }

    var focused = true
    var holdCapture = false
    var pending: CheckedContinuation<Void, Never>?
    var refusals = 0
    var screenshots: [Bool] = []

    func captureTarget() -> NSRunningApplication? { .current }
    func reportMissingAccessibility() { refusals += 1 }

    func capture(_ target: NSRunningApplication, screenshot: Bool) async -> Capture? {
        screenshots.append(screenshot)
        if holdCapture { await withCheckedContinuation { pending = $0 } }
        let field = focused ? ScreenContext.FocusedField(role: "AXTextArea", label: nil, value: "") : nil
        return Capture(
            context: ScreenContext(
                appName: "Fixture", bundleID: nil, focusedField: field, windowText: ["Window text"],
                capturedAt: Date(timeIntervalSince1970: 0)),
            screenshot: screenshot ? Data() : nil)
    }

    func attachments(for capture: Capture) -> [ChatAttachmentReader.Staged] {
        [.init(name: capture.context.appName)] + (capture.screenshot == nil ? [] : [.init(name: "picture")])
    }

    func release() {
        let waiting = pending
        pending = nil
        waiting?.resume()
    }
}

struct AgentProfile {
    let id: UUID
    let name: String
}

enum ChatAttachmentReader {
    struct Staged {
        let name: String
    }
}

struct AgentRunLedger {
    var busy: Set<UUID> = []
    var activeCount = 0
    func isBusy(agent: UUID) -> Bool { busy.contains(agent) }
}

@MainActor
final class AgentBackgroundCoordinator {
    static let maxConcurrent = 3
    var started: [(task: String, agent: UUID, attachments: [ChatAttachmentReader.Staged])] = []

    func start(_ task: String, with agent: AgentProfile, attachments: [ChatAttachmentReader.Staged] = []) {
        started.append((task, agent.id, attachments))
    }
}

@MainActor
final class AgentCoordinator {
    var agents: [AgentProfile] = []
    var runs: AgentRunLedger?
    let background = AgentBackgroundCoordinator()
}

@MainActor
enum Permissions {
    static var trusted = true
    static var ensured = 0
    static func isAccessibilityTrusted() -> Bool { trusted }
    @discardableResult
    static func ensureAccessibility() -> Bool {
        ensured += 1
        return true
    }
}

@MainActor
enum ScreenRecordingAccess {
    static let isGranted = true
}

/// Records the order of starts and stops, so an overlap is caught however briefly it lasts.
@MainActor
final class DictationCapture {
    static weak var latest: DictationCapture?
    var onLevels: (([Float]) -> Void)?
    var onLimit: (() -> Void)?
    var samples = VoiceCoordinatorTests.speech
    var isRecording = false
    var starts = 0
    var stops = 0
    var overlapped = false
    var holdStart = false
    var holdStop = false
    var pendingStart: CheckedContinuation<Void, Never>?
    var pendingStop: CheckedContinuation<Void, Never>?
    private var starting = false

    init() { Self.latest = self }

    func start(microphoneID: String?) async throws {
        if isRecording || starting { overlapped = true }
        starts += 1
        starting = true
        if holdStart { await withCheckedContinuation { pendingStart = $0 } }
        starting = false
        isRecording = true
    }

    func stop() async -> [Float] {
        if starting { overlapped = true }
        stops += 1
        if holdStop { await withCheckedContinuation { pendingStop = $0 } }
        isRecording = false
        return samples
    }

    func releaseStart() {
        let waiting = pendingStart
        pendingStart = nil
        waiting?.resume()
    }

    func releaseStop() {
        let waiting = pendingStop
        pendingStop = nil
        waiting?.resume()
    }
}

@MainActor
final class DictationPanelController {
    enum Phase { case listening, transcribing }

    @MainActor
    final class State {
        var phase = Phase.listening
        var levels: [Float] = []
    }

    static weak var latest: DictationPanelController?
    let state = State()
    var onAccept: (() -> Void)?
    var onCancel: (() -> Void)?
    var onPlacement: ((NSRect?) -> Void)?
    var onTab: ((Bool) -> Bool)?
    var isVisible = false

    init() { Self.latest = self }
    func show() { isVisible = true }
    func close() { isVisible = false }
}

@MainActor
final class VoiceModeCaption {
    static weak var latest: VoiceModeCaption?
    var shown: String?
    var frame: NSRect?

    init() { Self.latest = self }

    func show(_ name: String, above capsule: NSRect) {
        shown = name
        frame = capsule
    }

    func close() { shown = nil }
}

@MainActor
final class DictationAudioDucker {
    var begins = 0
    var ends = 0
    func begin() { begins += 1 }
    func end() { ends += 1 }
    func restoreImmediately() {}
}

enum QuickAction {
    case custom(CustomQuickAction)
}

@MainActor
final class QuickActionPanelState {
    let title: String
    var text = ""
    var finished: String?
    var failed: String?

    init(action: QuickAction, original: String, targetLanguage: Locale.Language) {
        switch action {
        case .custom(let custom): title = custom.name
        }
    }

    func append(_ delta: String) { text += delta }
    func finish(_ text: String) {
        self.text = text
        finished = text
    }
    func fail(_ message: String) { failed = message }
}

/// Mirrors the real panel's one-at-a-time presentation and its onDismiss on every dismissal.
@MainActor
final class QuickActionPanelController {
    static weak var latest: QuickActionPanelController?
    var state: QuickActionPanelState?
    var onReplace: ((String) -> Void)?
    var onContinueInChat: ((String) -> Void)?
    private var onDismiss: (() -> Void)?

    init() { Self.latest = self }

    func present(
        _ state: QuickActionPanelState, metrics: Int, languages: [Locale.Language],
        onRetranslate: @escaping (Locale.Language) -> Void, onReplace: @escaping (String) -> Void,
        onContinueInChat: ((String) -> Void)?, onDismiss: (() -> Void)? = nil
    ) {
        dismiss()
        self.state = state
        self.onReplace = onReplace
        self.onContinueInChat = onContinueInChat
        self.onDismiss = onDismiss
    }

    func dismiss() {
        guard state != nil else { return }
        let ended = onDismiss
        onDismiss = nil
        state = nil
        ended?()
    }
}

struct InjectedText {
    let text: String
    init(_ text: String) { self.text = text }
}

enum InjectionTarget {
    case external(NSRunningApplication)
}

struct AutomaticGeneration {}

/// Queues like the real one, so a delivery is checked for validity when it lands, not when asked.
@MainActor
final class TextInjector {
    var delivered: [String] = []
    var fails = false
    private var pending: [() -> Void] = []
    var queued: Int { pending.count }

    func deliver(
        _ injected: InjectedText, target: InjectionTarget?, expectedKeyword: String?, keywordLength: Int,
        automaticGeneration: AutomaticGeneration?, isValid: @escaping @MainActor () -> Bool = { true },
        onDelivered: @escaping @MainActor () -> Void = {}, onFailed: @escaping @MainActor () -> Void = {}
    ) {
        pending.append { [weak self] in
            guard let self, isValid() else { return }
            guard !fails else { return onFailed() }
            delivered.append(injected.text)
            onDelivered()
        }
    }

    var replaced: [String] = []

    func replaceSelection(
        with text: String, in targetApp: NSRunningApplication?,
        onDelivered: @escaping @MainActor () -> Void = {}, onFailed: @escaping @MainActor () -> Void = {}
    ) {
        pending.append { [weak self] in
            guard let self else { return }
            guard !fails else { return onFailed() }
            replaced.append(text)
            onDelivered()
        }
    }

    func drain() {
        let landing = pending
        pending = []
        landing.forEach { $0() }
    }
}
