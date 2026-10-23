# Voice AI

Two features over one small folder, both on a Gemini Flash model through the user's own OpenRouter or
Gemini connection:

- **Cloud transcription** is a second engine for the Dictation shortcut. Whatever the shortcut is
  (hold Fn, toggle, a double tap), the finished recording goes to the model and the cleaned transcript
  is typed at the cursor through `TextInjector`, exactly where the on-device model's would be — the
  fork's take on Wispr Flow. A **dictation mode** — Translate to English, Polish, As a message or
  one of the reader's own — rewrites it on the way: per app, named in the capsule, switched with Tab.
- **Ask by Voice** is a command with its own shortcut. It records a spoken question while Screen
  Awareness reads the window in front, sends the audio, the window's text and, when allowed, a
  screenshot in one request, and streams the answer into the Quick Action panel — or types it into the
  focused field when the question asked for that.
- **Edit Selection by Voice** comes with it: select text, press its shortcut, say "make this
  shorter", and the selection is rewritten in place — or, if it moved meanwhile, shown in the panel.
- **An agent can answer** Ask by Voice instead of its model: the request is written down and runs as
  that agent's background task, exactly as `@handle request` typed in root search, with the window
  attached.

Upstream declined voice control (#1550), so this lives in `Features/VoiceAI/` plus a few lines in
`AIRequest`, `AIRequestBody`, `DictationCoordinator`, `ScreenAwarenessCoordinator`,
`AgentBackgroundCoordinator`, `QuickActionPanelController`, `HotKeyManager`, the launcher's command
tables and `AppCore`.

## Invariants

- **Off by default, and each switch is consent.** `VoiceAISettings.cloudDictation` and `askEnabled`
  start false; turning either on asks first through `DialogController`, naming the connection and the
  model that will hear the audio, and approving saves exactly that choice as `dictationModel` or
  `askModel`. Ask by Voice also needs AI and Screen Awareness on, asks for the microphone, then
  Accessibility, and saves nothing unless both are granted. Both flags grant a capability, so no Voice
  AI key travels in a backup or has a settings-file key.
- **Audio goes only where consent was given.** `VoiceRoutePolicy.route` is the saved choice while its
  connection exists, is enabled and hears audio, and nil otherwise; nothing else is ever sent to. A
  connection added later never takes over, and a removed, disabled or changed one is refused with
  "Choose a model…" rather than replaced. Choosing another connection in the row asks again, naming it;
  another model on the same connection does not. The OpenRouter, Gemini and OpenAI-compatible fallbacks
  in `VoiceRoutePolicy.proposal` only fill a dialog.
- **Network only after a recording ends.** One POST per finished recording (two for a mode on a model
  that only transcribes), plus an agent's own turn when one answers; the model list is fetched
  only when **Choose…** is clicked. While idle there is no timer, observer, tap, session or process:
  `VoiceCloudTranscriber` holds only references, and `VoiceAskCoordinator` builds its recorder,
  capsule and panel controller on the first press. Ask by Voice registers one Carbon hotkey, only when
  bound.
- **Audio stays in memory and is never stored.** The recording becomes a WAV `Data` in memory and the
  float samples are released once encoded; it is sent once on `HTTPAIProvider`'s private `.ephemeral`
  session with `urlCache = nil` and never written to disk, logged or put in chat history. A question
  reaches chat history only if the reader continues it in AI Chat, or when an agent answers it: the
  run's chat is saved like any `@handle` run's, with the transcribed request, the window's text and
  any picture, and the **Answer with** caption and the section footer say so.
- **Silence never leaves the Mac.** `VoiceAudio.speechRange` trims silence at both ends with 300 ms of
  padding and returns nil for a recording without 200 ms of speech; nil means "No speech was
  recorded" and no request. A `[[NO_SPEECH]]` reply covers what slips through, and is never shown.
- **INSERT needs a focused field, and never goes straight into a terminal.** An INSERT reply is typed
  only when the capture found a focused text field, the text is at most 4,000 characters and the app
  is not a terminal (`VoiceInsertPolicy`); otherwise the panel shows it and ↵ types it. A delivery that
  fails shows the panel too.
- **An edit replaces only the selection it was given.** The selection is read again just before
  replacing, with the same reader, and the edit lands only if it is the same text (line endings
  aside), Accessibility says the focused element's selected text can be written, and the app is not a
  terminal; otherwise the panel shows the edit for ↵, so it never lands nowhere. A selection that
  cannot be read refuses the press and stops the recording at once, so nothing is sent.
- **The capture is material, not instructions.** The Ask instructions say so, the screen Markdown
  opens by saying so, and the spoken request travels last, after the text and the picture.
- **Only a body Tinycast writes with `input_audio` hears audio.** `VoiceRoutePolicy.accepts` takes
  every OpenAI-compatible connection and never Anthropic. A disabled route is skipped.
- **`minimal` effort is the floor for Gemini 3, and temperature is never sent.** Gemini 3 cannot turn
  reasoning off and loops below its default temperature; `fastestEffort` prefers any real level to
  `none`.
- **Hold to talk on a single modifier adds no monitor.** The modifier is watched by the shared
  listen-only tap, which exists only while some modifier-only shortcut is bound; with the binding
  unset there is no tap, timer or observer. A held modifier is reserved like Dictation's, so a double
  tap of it bound elsewhere is refused, and a binding that collides holds nothing.
- **Shift never ends a hold that has begun.** ⇧Tab switches the mode back while Fn or a single
  modifier is held, so `ModifierKeyDetector` lets Shift join and leave the key that holds, and that
  key's release still finishes the recording, with Shift down or not; any other modifier cancels.
- **A mode rewrites, it never answers.** Every mode prompt says the speech is material to rewrite,
  never a request, and never to be answered or carried out, the dictation prompt's own guard; the
  transcribe-then-rewrite path sends the transcript as `Text:` material. A mode applies only with
  Cloud transcription on, on the route already consented to: it adds no destination and no request
  for Gemini, and one text request for any other model.
- **The mode is the one the capsule names.** It is resolved from the app in front when the capsule
  shows, Tab changes it only while listening, and the request uses that one; closing the capsule
  forgets it and releases the chip. No built-in mode's name is ever stored, so it follows the app's
  language, and the stored value reads field by field, so a missing or unknown field never loses it.
- **An agent gets the window; the voice route gets only the recording.** With an agent under
  **Answer with**, the recording goes to Ask by Voice's consented route as a dictation request and
  nothing else, and the window's text and picture are staged in the agent's own run chat, where its
  model decides whether it sees the picture. The run is `AgentBackgroundCoordinator.start`, the
  `@handle` path, with its HUDs, time limit and unattended consent. A busy agent or three running
  agents refuse the press before anything is recorded; a deleted agent means the model again; Edit
  Selection by Voice always answers with the model.
- **Insert while recording is off with the cloud engine.** Each chunk would be a paid request, so
  `DictationCoordinator` never starts the live loop while `cloudIsOn()`.
- **Retention is the provider's.** Tinycast keeps no copy. What OpenRouter and Google keep follows the
  OpenRouter account's privacy settings (data collection and Zero Data Retention); Tinycast adds no
  body field for them. `VoiceAIRoute` wraps both uses in the usage log's recorder, so only the tokens
  and cost a reply reported are written (see [usage-dashboard.md](usage-dashboard.md)).

## Layout

| File | Holds |
| --- | --- |
| `Model/VoiceAudio.swift` | The speech gate and the in-memory 16 kHz mono PCM16 WAV encoder |
| `Model/VoicePrompt.swift` | The dictation and Ask instructions and requests, the chat prompt, the vocabulary line |
| `Model/VoiceReply.swift` | `VoiceReplyParser` (the streamed ANSWER/INSERT header), `VoiceTranscript.cleaned` |
| `Model/VoiceReplySession.swift` | One Ask reply: when the panel opens, what streams into it, and what it ends as |
| `Model/VoiceRoutePolicy.swift` | Defaults, eligible connections, the consented route and the proposal, effort, images |
| `Model/VoiceInsertPolicy.swift` | When an INSERT reply may be typed, or an edit replace its selection, without review |
| `Model/VoiceEditReply.swift` | One edit's reply: the instruction from its header, the text fitted to the selection |
| `Model/VoiceMode.swift` | `VoiceMode`, and `VoiceModeCatalog`: the three built-ins with fixed ids and their symbols |
| `Model/VoiceModeSettings.swift` | Custom modes, rewritten built-in instructions, hidden modes, the default and each app's mode |
| `Model/VoiceAIFailure.swift` | The feature's own errors |
| `Service/VoiceAIRoute.swift` | A selection to an `HTTPAIProvider`: Keychain key and headers, endpoint policy |
| `Service/VoiceMediaEncoder.swift` | Off the main actor: samples to WAV, the window's PNG to a bounded JPEG |
| `Service/VoiceSelectionAccess.swift` | Whether the focused element's selected text can be written in place |
| `Service/VoiceCloudTranscriber.swift` | The engine `DictationCoordinator` calls, its consent dialogs and the active mode |
| `UI/VoiceAskCoordinator.swift` | The funnel for both voice commands: shortcuts, launcher rows, capsule keys and panel |
| `UI/VoiceModeCaption.swift` | The chip above the dictation capsule naming the active mode |
| `Settings/VoiceAISettings.swift` | The fork's own `@Observable` store over `AppSettingsKey` keys |
| `Settings/VoiceModelRow.swift` | Connection and model, the catalog loaded on a click; a new connection goes through `choose` |
| `Settings/VoiceCloudDictationSection.swift` | The Dictation pane's Cloud transcription section |
| `Settings/VoiceModesSection.swift` | Dictation modes and Modes by app, shown while Cloud transcription is on |
| `Settings/VoiceModeEditorPanel.swift` | A mode's name and instructions; a built-in's can be reset |
| `Settings/VoiceAskSettingsSection.swift` | The AI pane's Ask by Voice section, after Screen Awareness; Answer with |

`AIMessage.audio` carries the recording; `AIRequestBody` writes it as an `input_audio` part with raw
base64 and a `format`, on the OpenAI-compatible shape only ([AI](ai.md#web-search-and-attachments)).

## Cloud transcription

`DictationCoordinator` takes two closures with defaults, `cloudIsOn` and `cloudTranscribe`, and
replaces only its transcription call: capture, the capsule, ducking, Return and Escape, spacing and
capitalization, and the paste or copy destination stay Dictation's. The AI Chat composer mic goes
through the same coordinator, so it uses the same engine, and `hasModel` is true without a downloaded
model. `VoiceCloudTranscriber.transcribe` takes the consented route (none is "Choose a model…" and
no request), builds the provider (so a missing key surfaces before any encoding), gates and encodes,
sends, collects the text deltas and cleans them.
Cancelling Dictation cancels the task, and the stream's termination cancels the URL session task.

## Dictation modes

A mode is a name and instructions that rewrite what was said before it is typed. Three ship: Translate
to English (speak Russian, get English), Polish, and As a message. Their instructions can be rewritten
and reset, and the reader adds, edits and deletes their own; a checkbox leaves any of them out of the
Tab cycle. Settings → Dictation shows them while Cloud transcription is on.

When the capsule shows, `VoiceCloudTranscriber` reads the app in front and takes its entry in **Modes
by app**, else the **Default mode**, else none. The chip above the capsule (`VoiceModeCaption`, a
nonactivating, mouse-transparent panel) names it and shows ⇥. Tab and ⇧Tab cycle none → each mode
not left out → none while listening, and the choice is that app's from then on (an entry equal to the
default is dropped, so the app follows the default again). Tab is the capsule's even during a held
shortcut, as Return and Escape are, and so is ⇧Tab: Shift joining a held Fn or single modifier
doesn't cancel the hold (see [hotkeys.md](hotkeys.md#modifier-only-shortcuts)).

`DictationPanelController` reports its frame on show and nil on close through `onPlacement` and
offers Tab through `onTab`; `DictationCoordinator` lends its capsule once, through a `capsule`
closure with a default, and `VoiceCloudTranscriber.attach` sets both hooks. With the cloud engine
off, the hooks do nothing and Tab passes through.

A Gemini model gets one request: the mode's rules as the system message, then the recording — Gemini
translates and rewrites speech as it transcribes it. Any other model is trusted only to transcribe:
the plain dictation request first, then a text request on the same route with the transcript as
`Text:` material (`VoiceRoutePolicy.rewritesWhileTranscribing`). Clean up speech shapes only plain
dictation and that first step; a mode decides its own wording.

## Ask by Voice

`CommandID.askByVoice` brings its shortcut, launcher row and conflict handling; `SettingsTab.ai` lists
its recorder among the AI pane's commands. The row leaves the launcher while AI, Screen Awareness or
the switch is off, and the bound shortcut stays registered but does nothing.

A press, from the shortcut or the row, is refused with a HUD while Dictation is busy, when Tinycast
itself is in front, when the consented route is gone or its key is missing, and with Screen Awareness's
dialog when Accessibility is missing. Otherwise it hides the palette, starts the window capture and the
microphone together, and shows Dictation's capsule (`DictationCapture` and `DictationPanelController`
instances of its own, sharing `AppCore.dictationAudioDucker`). The capture finishes while the reader
is still speaking.

A recording ends on release of a held key combination or single modifier, a second press in either
mode, Return in the capsule, or the five-minute cap. A combination's release comes from Carbon,
Secure Input's equivalents included. A single modifier, such as right Option, is held through
`ModifierTapMonitor`, the listen-only tap Screen Awareness's double right ⌘ already uses: while
Shortcut behavior is Hold to talk, `HotKeyManager.heldCommands` lends the command its modifier, which
starts the recording after 250 ms held alone and finishes it on release; any other key, modifier or
click cancels it, except Return, Escape and Tab, which belong to the capsule, and Shift once the hold
has begun. A double tap in hold mode acts as a toggle and the settings say so, as they name a modifier
another hold already reserves.
Every start waits for the previous stop, so one recorder never runs two sessions.

The reply's first two lines are a header, read by `VoiceReplyParser` as they stream; a reply without
one is an answer. `VoiceReplySession` turns the parsed reply into steps for the panel and an outcome,
so the coordinator only presents:

- **ANSWER** closes the capsule and opens the Quick Action panel, titled with the transcribed question
  (one line, at most 80 characters), with the answer streaming in. ⌘J continues it in AI Chat, seeded
  with the question and the screen text on the same route; ⌘C copies; ↵ types it into the app the
  question came from, at its caret or over its selection. An answer without a question is held back
  until it cannot be the no-speech sentinel.
- **INSERT** keeps the capsule's processing wave, buffers the text and, when `VoiceInsertPolicy`
  allows, types it through `TextInjector` into the captured app; otherwise, or when delivery fails
  (with a HUD saying so), the panel shows it for ↵.

Escape in the capsule cancels everything. Dismissing the panel while a reply streams cancels the
reply through `QuickActionPanelController`'s `onDismiss`. A new press while replying cancels the old
reply and records again. Turning a switch off, and quitting, cancel too; a quit while recording
restores the volume at once. A session token keeps a cancelled or superseded reply from touching the
panel or typing anything.

The screenshot follows **Include a screenshot** and is re-encoded as a JPEG of at most 1,568 px on the
long edge before upload. A model the connection's own catalog marks text-only gets none, and a missing
Screen Recording grant is one HUD line, as in Screen Awareness.

## Edit Selection by Voice

`CommandID.editByVoice` is a second command under the same switch, route, consent and Shortcut
behavior; the AI pane lists its recorder beside Ask by Voice's, and its launcher row comes and goes
with Ask by Voice's. The consent dialog names the text you selected beside the window in front.

A press takes the app in front, or behind the palette, and starts the microphone and the capsule
while `QuickActionRunner.selection` reads the selection exactly as Quick Actions do: Accessibility
first, a borrowed ⌘C second. A refusal ("Select some text first.", an app that shares no text, a
missing Accessibility grant) cancels the recording as soon as it is known, with its message. A second
press of either voice command, a release in hold mode or Return finishes the recording.

One request goes to Ask by Voice's route: the edit rules, the words to spell, the selection as
`Text:`, then the spoken instruction. The reply opens with the Ask header (`INSERT`, `Q:` and the
instruction transcribed), parsed by `VoiceReplyParser`; a reply without it is the edit whole.
`VoiceEditReply` keeps the selection's own leading and trailing whitespace and drops wrapping quotes
or a code fence only when the selection had none. The capsule's processing wave stays until the
reply is complete, then:

- if the app is not a terminal and Accessibility says the focused element's selected text can be
  written (`VoiceSelectionAccess`; a web page or a label cannot), the selection is read again, and
  if it is the same text the edit replaces it through `TextInjector.replaceSelection`;
- otherwise the panel shows the edit, titled with the instruction ("The selection changed, so the
  result is shown instead."): ↵ types it over whatever is selected now, ⌘C copies, ⌘J continues in
  AI Chat with the instruction and the original text;
- a replacement that fails shows the panel too, with a HUD.

## Ask an agent by voice

**Answer with**, under Ask by Voice's model while some agent exists, is the model above or any agent
(`VoiceAISettings.askAgent`, an id that travels in no backup and has no settings-file key, since
agents never travel either). With an agent chosen, a press of Ask by Voice is refused at once with
the background run's own message when that agent is still working or three agents are, so nothing is
recorded for a run that could not start. Otherwise it records and reads the window exactly as a
question does, with the picture whenever **Include a screenshot** is on, since the agent's model, not
the voice route, will look at it.

When the recording ends, `VoicePrompt.agentRequest` (the dictation request with Clean up speech on
and the vocabulary) goes to Ask by Voice's route, and the cleaned transcript, unless it is empty or
`[[NO_SPEECH]]`, becomes the task. The capsule closes and `AgentBackgroundCoordinator.start(task,
with: agent, attachments:)` runs it as the launcher would: a fresh chat bound to the agent, the
window's text as a Markdown document and the picture staged in it (a model that cannot see images
gets the text alone and a HUD says so), then the send. From there it is an ordinary background run:
its menu-bar item, its HUDs, its limit and its consent rules ([background
agents](background-agents.md)). Escape while the request is being written down starts nothing.

That chat is saved to AI Chat's history as it goes, like every background run's, so the request, the
window's Markdown and the picture stay on disk until the reader deletes the chat. The caption under
**Answer with** says so where the agent is chosen, and the section footer names the agent's run as
the one place besides AI Chat where a question is kept. The recording itself is never saved.

## Routes and models

`VoiceRoutePolicy.route` is the saved choice while its connection exists, hears audio and is enabled,
and nil otherwise; it is the only thing a recording is sent to. `VoiceRoutePolicy.proposal` is what a
switch's dialog names: that saved choice, else the first enabled OpenRouter connection, then Gemini,
with the preset, and last an OpenAI-compatible server with the first model it lists. The OpenAI API
itself is never proposed, because its usual chat models take no audio; it can be chosen in the row.
With no proposal, each switch is disabled and says to add a connection. While a switch is on and its
route is gone, the row shows None and says nothing is sent until a connection is chosen.

| Use | OpenRouter | Gemini | Effort |
| --- | --- | --- | --- |
| Dictation | `google/gemini-3.1-flash-lite` | `gemini-3.1-flash-lite` | `minimal` |
| Ask by Voice | `google/gemini-3.8-flash` | `gemini-3.8-flash` | `low` |

The presets come from OpenRouter's live catalog on 2026-10-22; `~google/gemini-flash-latest` is never a
default because it changes model silently. **Choose…** lists the connection's models that take audio
(OpenRouter's catalog says which; one that doesn't say keeps every model) and saves the cheapest
effort it lists. A typed model id keeps the preset's effort only when it is the preset's own model.
`VoiceAIRoute` mirrors `AIProviderFactory`'s API case but skips its effort filter, since a voice model
need not be in the connection's own model list. The flex and priority service tiers are never
requested.

## Prompts

Prompts are never localized. Both send their rules as the system message.

**Dictation** sends one user message: the text part "Transcribe the recording." and then the audio. The
rules ask for what was said and never an answer, even to a dictated question; each word in the
language and script it was spoken in, with no transliteration, for mixed Russian and English; usual
spellings for products, code and acronyms; punctuation and paragraphs. **Clean up speech** (on by
default) drops fillers, stutters and accidental repeats and keeps only a self-correction; off keeps
every word. The Dictation language, when one is set, becomes "The speaker usually speaks …". **Words
to spell exactly** become one line of at most 500 characters. The reply is the transcript only, or
`[[NO_SPEECH]]`; `VoiceTranscript.cleaned` strips one pair of wrapping quotes and a code fence.

**A mode** keeps the guard and the spelling and language hints, says mixed languages are to be
understood rather than kept, and gives the mode's instructions; the reply is the rewritten text only,
or `[[NO_SPEECH]]`. The second step of the two-request path says the same of a text.

**Ask** sends the screen Markdown (`ScreenContextFormatter`, within `AIAttachmentBudget`), a line saying
whether a text field is focused and the vocabulary, then the JPEG, then the audio. The rules ask for
the `ANSWER`/`INSERT` and `Q:` header, INSERT only for a request to write into the focused field, the
field's text alone in the conversation's language and tone, and otherwise a brief Markdown answer in
the language the reader spoke. Silence is `ANSWER`, an empty `Q:` and `[[NO_SPEECH]]`.

**Agent** is the dictation request with Clean up speech on, no language and the vocabulary: the
voice route writes the request down and never sees the window.

**Edit** sends its rules as the system message, then one user message: "Spell these as written when
you hear them: …" when there is a vocabulary, `Text:` and the selection, then the audio. The rules ask
for the `INSERT` and `Q:` header, then the edited text alone, in the text's own language and format
unless the instruction says otherwise, and treat the selection as material whatever it asks for.
Silence is `INSERT`, an empty `Q:` and `[[NO_SPEECH]]`.

## Costs

The encoding sets only the upload size: Gemini bills 32 tokens per second of audio whatever the
format. At the standard tier, twenty seconds of dictation on `gemini-3.1-flash-lite` at `minimal` is
about $0.0005 (640 audio tokens, about 350 prompt and 80 output tokens); an Ask on `gemini-3.8-flash` at
`low` is about $0.01, mostly the screen text (up to about 8,000 tokens) and the picture. A request
for an agent costs a dictation's worth on the Ask model, plus the agent's own turn on its model.

Memory is transient: 15 s of speech is 480 KB of WAV, about 640 KB as base64 in the body, plus about
0.3 MB of JPEG and 32 KB of screen text for an Ask. The worst case, the five-minute cap, is a 9.6 MB WAV,
12.8 MB of base64 and a 12.8 MB body, under Google's 20 MB inline limit, all freed when the request
ends.

## Manual sweep

- **Cloud transcription setup.** With the switch off, the Dictation pane shows only the toggle under
  Cloud transcription. With no OpenRouter, Gemini or OpenAI-compatible connection it is disabled with
  a caption. Add one, turn it on: the dialog names the connection and the model.
- **The route stays where consent was given.** With cloud transcription on a local OpenAI-compatible
  server, add an OpenRouter connection: dictation still goes to the server (a proxy shows it). Disable
  the server in AI settings: the row shows None with its caption, Dictation says "Choose a model for
  cloud transcription…" and nothing is sent. Choose OpenRouter in the row: a dialog names it, Cancel
  keeps None, Continue saves it. Change only the model: no dialog. Repeat for Ask by Voice.
- **Hold Fn.** In TextEdit say "Привет, это тест OpenRouter и Kubernetes, ну, как бы, в пятницу, нет, в
  субботу": clean Cyrillic and Latin text, no fillers, "в субботу".
- **Cleanup off and vocabulary.** Turn Clean up speech off: the fillers stay. Add "Tinycast" to Words
  to spell exactly and say it: it is spelled right.
- **A dictated question.** Dictate "Какая сегодня погода?": it is transcribed, not answered.
- **Dictation modes.** With Cloud transcription on, open Slack and hold Fn: no chip. Press Tab while
  listening: "Translate to English ⇥" appears above the capsule; say "Привет, я буду через десять
  минут": English is typed. Dictate in Slack again: the chip is already there. Dictate in Mail: no
  chip. Set Default mode to Polish: Mail shows it, Slack keeps Translate. Still holding Fn, ⇧Tab back
  to none in Slack: the recording goes on, and its entry disappears from Modes by app. Hold Fn, press
  Shift, let go of Fn first: the recording finishes as usual. Dictate "Какая сегодня погода?" in As a
  message: it is written as a message, not answered. Press Tab after Return, while the capsule
  processes: nothing changes. Leave Polish out of the Tab cycle: Tab skips it. Rewrite Polish's
  instructions, then Reset to Default. Add a mode, choose it for an app, delete it: the app types the
  plain transcript. With a local OpenAI-compatible model, a mode makes two requests (a proxy shows the
  audio then the text).
- **Silence and cancelling.** Hold for 2 s in silence: "No speech was recorded", and a proxy shows no
  request. Escape while the capsule processes: nothing is typed. Wi-Fi off: the network error is a HUD.
- **The composer mic** in AI Chat uses the cloud engine; switching cloud off returns it to the
  on-device model.
- **Ask by Voice setup.** Turn on Screen Awareness, then Ask by Voice: the dialog names the
  connection and the model, then the microphone and Accessibility are asked for. Bind ⌃⌥Space under
  the AI pane's commands and choose Hold to talk. Hold it and ask about a Safari page: the capsule
  shows, and on release the panel streams an answer titled with the question. Try ⌘J (a chat seeded
  with the question, the screen text and the answer), ⌘C, and ↵ (typed into Safari's field when one
  is focused).
- **INSERT.** In Mail with the caret in a reply, hold and say "Ответь, что я приду завтра в десять": the
  text is typed into the reply with no panel. Repeat in Terminal: the panel shows the text, and ↵
  types it.
- **Hold on a single modifier.** Record right Option for Ask by Voice and choose Hold to talk: hold
  it, speak, let go, and the question is sent. Hold it and press a letter: the recording is cancelled
  and nothing is sent. A quick tap records nothing. Try to bind a double right Option elsewhere: it is
  refused while the hold owns the key. Switch to Press to start or stop: a tap of right Option starts
  and a second tap finishes.
- **Hold-mode edge cases.** Bind a double tap in hold mode: the settings caption appears, and it acts
  as a toggle. Run it from the launcher row: recording starts over the app behind the palette, and
  Return finishes. Hold a combination briefly: a recording too short is "No speech was recorded".
- **Edit Selection by Voice.** Bind it and select a paragraph in TextEdit; press, say "сделай короче",
  press again: the paragraph is replaced by a shorter one, its trailing newline kept, and ⌘Z undoes
  it. Say "translate this to English" over a Russian sentence: English replaces it. Select text, press,
  and click elsewhere in the document before the reply lands: the panel shows the edit titled with
  what you said, with a HUD; ↵ types it at the new selection. Select text in Terminal: the panel
  always shows it, as does a selection on a web page, which cannot be written. In Slack or another
  Electron field, note whether it replaces in place or shows the panel. With nothing selected: "Select
  some text first." at once and the recording stops. Hold its single-modifier shortcut in Hold to
  talk: release finishes.
- **Ask an agent by voice.** With an agent set up, choose it under Answer with. Open a Safari page,
  press Ask by Voice, say "Сделай краткую выжимку этой страницы в заметку", press again: the capsule
  closes, "<agent> is working in the background" appears with the menu-bar item, and the run's chat
  shows the request as typed text, the window as `Screen — Safari.md` and, with Include a screenshot
  on, the picture (a proxy shows the voice route got only the audio). AI Chat's history keeps that
  chat with all three, as the Answer with caption says. Press again while it runs: refused at once,
  with no recording. Stay silent: "No speech was recorded" and no run. Escape in the
  capsule while it processes: no run. Edit Selection by Voice still edits with the model. Delete the
  agent: Answer with shows the model, and a question opens the panel again.
- **Refusals.** Ask while Dictation records: a HUD refuses. With Tinycast in front: refused. Without
  Screen Recording: text only plus a HUD. Escape in the panel mid-stream: the stream stops (a proxy
  shows it cancelled).
- **Turning things off.** Turn off Screen Awareness: the Ask by Voice row disappears and the shortcut
  is inert. Quit while recording: the volume is restored and nothing is sent.
- **Choose….** Click it: one GET to the connection's catalog, and only models that take audio are
  listed.
- **Idle.** Activity Monitor shows memory unchanged against a build without the feature, and no new
  threads or wakeups while idle.
- **Measure before tuning the presets** (it spends a fraction of a cent of the owner's credit):

  ```sh
  afconvert -f WAVE -d LEI16@16000 -c 1 sample.m4a /tmp/s.wav && base64 -i /tmp/s.wav > /tmp/s.b64
  printf '%s' "You transcribe dictation. Reply with the transcript only." > /tmp/sys.txt
  jq -n --rawfile a /tmp/s.b64 --arg m google/gemini-3.1-flash-lite --rawfile sys /tmp/sys.txt \
    '{model:$m, stream:true, reasoning:{effort:"minimal"}, messages:[{role:"system",content:$sys},
      {role:"user",content:[{type:"text",text:"Transcribe the recording."},
      {type:"input_audio",input_audio:{data:($a|rtrimstr("\n")),format:"wav"}}]}]}' > /tmp/body.json
  curl -sSN https://openrouter.ai/api/v1/chat/completions -H "Authorization: Bearer $OPENROUTER_API_KEY" \
    -H 'Content-Type: application/json' --data @/tmp/body.json -o /tmp/out.sse \
    -w 'ttfb=%{time_starttransfer}s total=%{time_total}s up=%{size_upload}B\n'
  ```

  Expect SSE text deltas and a last chunk whose `usage` carries `cost` and
  `prompt_tokens_details.audio_tokens`. Repeat with `gemini-3.5-flash-lite/minimal` and with
  `google/gemini-3.8-flash` and `reasoning:{effort:"low"}` for Ask, and tune `VoiceAudio`'s gate
  constants with the built-in microphone and a headset.
- Harnesses: `voice-ai-test` (WAV header and samples, the gate, the prompts, every request body —
  dictation, Ask, a mode in one and two steps, an edit, an agent's — the reply header and
  `VoiceReplySession` under every chunking, transcript cleanup, the route and the proposal, the insert
  policy, mode settings); `voice-coordinator-test` (the shipped `VoiceCloudTranscriber` and
  `VoiceAskCoordinator` against recorded effects: consent saving exactly what it named and asking
  again for another connection, no rerouting, the session token through capture, delivery, supersede
  and dismissal, and the recorder's start and stop order; dictation modes on the capsule; Edit
  Selection by Voice replacing an unchanged selection, showing a moved one, refusing an unreadable
  one; an agent getting the transcript and the window while the route gets the audio alone, and
  refusing a press while it or three agents are busy); `dictation-field-test` (the cloud seam in
  `DictationCoordinator`); `hotkey-dispatch-test` (a command's release, Secure Input's included, and
  a voice command held on a single modifier); `hotkey-test` (Shift joining and leaving a held key
  while another modifier still cancels it).
