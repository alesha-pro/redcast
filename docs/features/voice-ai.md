# Voice AI

Two features over one small folder, both on a Gemini Flash model through the user's own OpenRouter or
Gemini connection:

- **Cloud transcription** is a second engine for the Dictation shortcut. Whatever the shortcut is
  (hold Fn, toggle, a double tap), the finished recording goes to the model and the cleaned transcript
  is typed at the cursor through `TextInjector`, exactly where the on-device model's would be — the
  fork's take on Wispr Flow.
- **Ask by Voice** is a command with its own shortcut. It records a spoken question while Screen
  Awareness reads the window in front, sends the audio, the window's text and, when allowed, a
  screenshot in one request, and streams the answer into the Quick Action panel — or types it into the
  focused field when the question asked for that.

Upstream declined voice control (#1550), so this lives in `Features/VoiceAI/` plus a few lines in
`AIRequest`, `AIRequestBody`, `DictationCoordinator`, `ScreenAwarenessCoordinator`,
`QuickActionPanelController`, `HotKeyManager`, the launcher's command tables and `AppCore`.

## Invariants

- **Off by default, and each switch is consent.** `VoiceAISettings.cloudDictation` and `askEnabled`
  start false; turning either on asks first through `DialogController`, naming the connection that
  will hear the audio. Ask by Voice also needs AI and Screen Awareness on, asks for the microphone, then
  Accessibility. Both flags grant a capability, so no Voice AI key travels in a backup or has a
  settings-file key.
- **Network only after a recording ends.** One POST per finished recording; the model list is fetched
  only when **Choose…** is clicked. While idle there is no timer, observer, tap, session or process:
  `VoiceCloudTranscriber` holds only references, and `VoiceAskCoordinator` builds its recorder,
  capsule and panel controller on the first press. Ask by Voice registers one Carbon hotkey, only when
  bound.
- **Audio stays in memory and is never stored.** The recording becomes a WAV `Data` in memory and the
  float samples are released once encoded; it is sent once on `HTTPAIProvider`'s private `.ephemeral`
  session with `urlCache = nil` and never written to disk, logged or put in chat history. A question
  reaches chat history only if the reader continues it in AI Chat.
- **Silence never leaves the Mac.** `VoiceAudio.speechRange` trims silence at both ends with 300 ms of
  padding and returns nil for a recording without 200 ms of speech; nil means "No speech was
  recorded" and no request. A `[[NO_SPEECH]]` reply covers what slips through, and is never shown.
- **INSERT needs a focused field, and never goes straight into a terminal.** An INSERT reply is typed
  only when the capture found a focused text field, the text is at most 4,000 characters and the app
  is not a terminal (`VoiceInsertPolicy`); otherwise the panel shows it and ↵ types it. A delivery that
  fails shows the panel too.
- **The capture is material, not instructions.** The Ask instructions say so, the screen Markdown
  opens by saying so, and the spoken request travels last, after the text and the picture.
- **Only a body Tinycast writes with `input_audio` hears audio.** `VoiceRoutePolicy.accepts` takes
  every OpenAI-compatible connection and never Anthropic. A disabled route is skipped.
- **`minimal` effort is the floor for Gemini 3, and temperature is never sent.** Gemini 3 cannot turn
  reasoning off and loops below its default temperature; `fastestEffort` prefers any real level to
  `none`.
- **Insert while recording is off with the cloud engine.** Each chunk would be a paid request, so
  `DictationCoordinator` never starts the live loop while `cloudIsOn()`.
- **Retention is the provider's.** Tinycast keeps no copy. What OpenRouter and Google keep follows the
  OpenRouter account's privacy settings (data collection and Zero Data Retention); Tinycast adds no
  body field for them.

## Layout

| File | Holds |
| --- | --- |
| `Model/VoiceAudio.swift` | The speech gate and the in-memory 16 kHz mono PCM16 WAV encoder |
| `Model/VoicePrompt.swift` | The dictation and Ask instructions and requests, the chat prompt, the vocabulary line |
| `Model/VoiceReply.swift` | `VoiceReplyParser` (the streamed ANSWER/INSERT header), `VoiceTranscript.cleaned` |
| `Model/VoiceReplySession.swift` | One Ask reply: when the panel opens, what streams into it, and what it ends as |
| `Model/VoiceRoutePolicy.swift` | Defaults, eligible connections, selection repair, effort choice, image gating |
| `Model/VoiceInsertPolicy.swift` | When an INSERT reply may be typed without review |
| `Model/VoiceAIFailure.swift` | The feature's own errors |
| `Service/VoiceAIRoute.swift` | A selection to an `HTTPAIProvider`: Keychain key and headers, endpoint policy |
| `Service/VoiceMediaEncoder.swift` | Off the main actor: samples to WAV, the window's PNG to a bounded JPEG |
| `Service/VoiceCloudTranscriber.swift` | The engine `DictationCoordinator` calls, and its consent dialog |
| `UI/VoiceAskCoordinator.swift` | The Ask by Voice funnel: shortcut, launcher row, capsule keys and panel |
| `Settings/VoiceAISettings.swift` | The fork's own `@Observable` store over `AppSettingsKey` keys |
| `Settings/VoiceModelRow.swift` | Connection and model, the catalog loaded on a click |
| `Settings/VoiceCloudDictationSection.swift` | The Dictation pane's Cloud transcription section |
| `Settings/VoiceAskSettingsSection.swift` | The AI pane's Ask by Voice section, after Screen Awareness |

`AIMessage.audio` carries the recording; `AIRequestBody` writes it as an `input_audio` part with raw
base64 and a `format`, on the OpenAI-compatible shape only ([AI](ai.md#web-search-and-attachments)).

## Cloud transcription

`DictationCoordinator` takes two closures with defaults, `cloudIsOn` and `cloudTranscribe`, and
replaces only its transcription call: capture, the capsule, ducking, Return and Escape, spacing and
capitalization, and the paste or copy destination stay Dictation's. The AI Chat composer mic goes
through the same coordinator, so it uses the same engine, and `hasModel` is true without a downloaded
model. `VoiceCloudTranscriber.transcribe` resolves the route, builds the provider (so a missing key
surfaces before any encoding), gates and encodes, sends, collects the text deltas and cleans them.
Cancelling Dictation cancels the task, and the stream's termination cancels the URL session task.

## Ask by Voice

`CommandID.askByVoice` brings its shortcut, launcher row and conflict handling; `SettingsTab.ai` lists
its recorder among the AI pane's commands. The row leaves the launcher while AI, Screen Awareness or
the switch is off, and the bound shortcut stays registered but does nothing.

A press, from the shortcut or the row, is refused with a HUD while Dictation is busy, when Tinycast
itself is in front, when no route resolves or its key is missing, and with Screen Awareness's dialog
when Accessibility is missing. Otherwise it hides the palette, starts the window capture and the
microphone together, and shows Dictation's capsule (`DictationCapture` and `DictationPanelController`
instances of its own, sharing `AppCore.dictationAudioDucker`). The capture finishes while the reader
is still speaking.

A recording ends on release of a held key combination, a second press in either mode, Return in the
capsule, or the five-minute cap. Hold to talk needs a combination, because `HotKeyManager` reports a
command's release only from Carbon, Secure Input's equivalents included; a double tap or single
modifier in hold mode acts as a toggle and the settings say so. Every start waits for the previous
stop, so one recorder never runs two sessions.

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

## Routes and models

`VoiceRoutePolicy.resolve` keeps a stored choice while its connection exists, hears audio and is
enabled. Otherwise it takes the first enabled OpenRouter connection, then Gemini, with the preset, and
last any other OpenAI-compatible connection with the first model it lists. With none, each switch is
disabled and says to add a connection.

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

**Ask** sends the screen Markdown (`ScreenContextFormatter`, within `AIAttachmentBudget`), a line saying
whether a text field is focused and the vocabulary, then the JPEG, then the audio. The rules ask for
the `ANSWER`/`INSERT` and `Q:` header, INSERT only for a request to write into the focused field, the
field's text alone in the conversation's language and tone, and otherwise a brief Markdown answer in
the language the reader spoke. Silence is `ANSWER`, an empty `Q:` and `[[NO_SPEECH]]`.

## Costs

The encoding sets only the upload size: Gemini bills 32 tokens per second of audio whatever the
format. At the standard tier, twenty seconds of dictation on `gemini-3.1-flash-lite` at `minimal` is
about $0.0005 (640 audio tokens, about 350 prompt and 80 output tokens); an Ask on `gemini-3.8-flash` at
`low` is about $0.01, mostly the screen text (up to about 8,000 tokens) and the picture.

Memory is transient: 15 s of speech is 480 KB of WAV, about 640 KB as base64 in the body, plus about
0.3 MB of JPEG and 32 KB of screen text for an Ask. The worst case, the five-minute cap, is a 9.6 MB WAV,
12.8 MB of base64 and a 12.8 MB body, under Google's 20 MB inline limit, all freed when the request
ends.

## Manual sweep

- **Cloud transcription setup.** With the switch off, the Dictation pane shows only the toggle under
  Cloud transcription. With no OpenRouter, Gemini or OpenAI-compatible connection it is disabled with
  a caption. Add one, turn it on: the dialog names the connection and the model.
- **Hold Fn.** In TextEdit say "Привет, это тест OpenRouter и Kubernetes, ну, как бы, в пятницу, нет, в
  субботу": clean Cyrillic and Latin text, no fillers, "в субботу".
- **Cleanup off and vocabulary.** Turn Clean up speech off: the fillers stay. Add "Tinycast" to Words
  to spell exactly and say it: it is spelled right.
- **A dictated question.** Dictate "Какая сегодня погода?": it is transcribed, not answered.
- **Silence and cancelling.** Hold for 2 s in silence: "No speech was recorded", and a proxy shows no
  request. Escape while the capsule processes: nothing is typed. Wi-Fi off: the network error is a HUD.
- **The composer mic** in AI Chat uses the cloud engine; switching cloud off returns it to the
  on-device model.
- **Ask by Voice setup.** Turn on Screen Awareness, then Ask by Voice: the dialog names the connection,
  then the microphone and Accessibility are asked for. Bind ⌃⌥Space under the AI pane's commands and
  choose Hold to talk. Hold it and ask about a Safari page: the capsule shows, and on release the panel
  streams an answer titled with the question. Try ⌘J (a chat seeded with the question, the screen text
  and the answer), ⌘C, and ↵ (typed into Safari's field when one is focused).
- **INSERT.** In Mail with the caret in a reply, hold and say "Ответь, что я приду завтра в десять": the
  text is typed into the reply with no panel. Repeat in Terminal: the panel shows the text, and ↵
  types it.
- **Hold-mode edge cases.** Bind a double tap in hold mode: the settings caption appears, and it acts
  as a toggle. Run it from the launcher row: recording starts over the app behind the palette, and
  Return finishes. Hold a combination briefly: a recording too short is "No speech was recorded".
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
- Harness: `voice-ai-test` (WAV header and samples, the gate, both prompts, the `input_audio` body, the
  reply header and `VoiceReplySession` under every chunking, transcript cleanup, route resolution, the
  insert policy).
