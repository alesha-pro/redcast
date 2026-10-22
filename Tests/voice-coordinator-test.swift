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
        try await askConsent()
        try await askAnswer()
        try await askInsert()
        try await askNoSpeechAndRefusals()
        try await askSupersede()
        try await askCancelDuringCapture()
        try await askStartAndStopOrder()
        try await askHoldToTalk()
        try await askDismissAndSwitchOff()
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

        world.core.answer = true
        cloud.setEnabled(true)
        try await wait { world.voice.cloudDictation }
        try await settle()
        expect(world.voice.dictationModel == onLocal, "Approval stores exactly the destination the dialog named")

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

        let transcription = Task { try await cloud.transcribe(speech, language: "Russian") }
        try await wait { Network.streams.count == 1 }
        expect(Network.routes == [onLocal], "The recording goes to the consented route")
        let request = Network.requests[0]
        expect(
            request.messages.first?.audio.count == 1 && request.instructions?.contains("Russian") == true,
            "as one audio part, with the language")
        Network.streams[0].yield(.text("“Привет, "))
        Network.streams[0].yield(.text("мир”"))
        Network.streams[0].finish()
        let transcript = try await transcription.value
        expect(transcript == "Привет, мир", "The streamed transcript is assembled and cleaned")

        do {
            _ = try await cloud.transcribe([Float](repeating: 0, count: 32_000), language: nil)
            expect(false, "Silence is refused")
        } catch {
            expect(error as? VoiceAIFailure == .noSpeech, "Silence is no speech")
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

        let transcription = Task { try await cloud.transcribe(speech, language: nil) }
        try await wait { Network.streams.count == 1 }
        let polish = VoiceModeCatalog.builtIn(VoiceModeCatalog.polish)!
        let request = Network.requests[0]
        expect(
            request.instructions?.contains(polish.instructions) == true
                && request.messages.first?.audio.count == 1,
            "Gemini hears the recording and the mode in one request")
        capsule.state.phase = .transcribing
        expect(capsule.onTab?(false) == false, "Tab no longer switches once the recording is sent")
        Network.streams[0].yield(.text("Готово."))
        Network.streams[0].finish()
        let typed = try await transcription.value
        expect(typed == "Готово.", "and its text is what is typed")

        capsule.onPlacement?(nil)
        expect(cloud.activeMode == nil && caption?.shown == nil, "Closing the capsule forgets the mode and the chip")
        world.frontmost = "com.apple.mail"
        capsule.state.phase = .listening
        capsule.onPlacement?(frame)
        expect(cloud.activeMode == nil, "An app without a mode of its own follows the default, here none")
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
        world.voice.modes.assign(VoiceModeCatalog.asMessage, to: nil)
        capsule.onPlacement?(frame)
        let transcription = Task { try await world.cloud.transcribe(speech, language: nil) }
        try await wait { Network.streams.count == 1 }
        let first = Network.requests[0]
        expect(
            first.messages.first?.text == "Transcribe the recording." && first.messages.first?.audio.count == 1,
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
    }

    static func expectRefusal(_ cloud: VoiceCloudTranscriber, _ message: String) async throws {
        let before = Network.routes.count
        do {
            _ = try await cloud.transcribe(speech, language: nil)
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
        expect(world.hotKeys.heldCommands == [.askByVoice], "Hold mode lends a single modifier to the command")
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
    var frontmost: String?
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
        frontmostBundleID: { [weak self] in self?.frontmost })
    lazy var ask = VoiceAskCoordinator(
        settings: settings, voice: voice, aiSettings: ai, appIndex: appIndex, hotKeys: hotKeys,
        injector: injector, audioDucker: ducker, core: core,
        requestMicrophone: { [weak self] in
            guard let self else { return false }
            microphoneRequests += 1
            return microphone
        })

    init(connections: [AIConnection]) {
        defaults = UserDefaults(suiteName: suite)!
        ai = AISettingsStore(defaults: defaults)
        voice = VoiceAISettings(defaults: defaults)
        connections.forEach(ai.save)
        Network.reset()
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
    var name: String { "Ask by Voice" }
    var sfSymbol: String { "waveform" }
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
    let isVisible = false
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

    func captureTarget() -> NSRunningApplication? { .current }
    func reportMissingAccessibility() { refusals += 1 }

    func capture(_ target: NSRunningApplication, screenshot: Bool) async -> Capture? {
        if holdCapture { await withCheckedContinuation { pending = $0 } }
        let field = focused ? ScreenContext.FocusedField(role: "AXTextArea", label: nil, value: "") : nil
        return Capture(
            context: ScreenContext(
                appName: "Fixture", bundleID: nil, focusedField: field, windowText: ["Window text"],
                capturedAt: Date(timeIntervalSince1970: 0)),
            screenshot: nil)
    }

    func release() {
        let waiting = pending
        pending = nil
        waiting?.resume()
    }
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

    func drain() {
        let landing = pending
        pending = []
        landing.forEach { $0() }
    }
}
