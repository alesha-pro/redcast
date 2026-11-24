# Live Voice

A spoken, two-way conversation with a realtime model that can see the screen, point at things on it,
put exact text in front of the reader, call connected MCP tools and hand longer work to a background
agent.

Enable **Live Voice** in **Settings → AI → Live Voice** (off by default; requires an OpenAI or
Google Gemini connection). Once enabled, start or stop a session from the launcher (**Live Voice**)
or by binding a global shortcut under **Settings → AI → Commands**. While active, a floating
non-activating capsule shows the session state (connecting, listening, thinking, speaking, muted,
reconnecting) with controls to interrupt a reply, mute the microphone or end the session.

## Invariants

- **`AppCore` owns it; idle costs nothing.** `AppCore` holds `liveVoiceSettings` and
  `liveVoiceCoordinator`; `LiveVoiceSettingsSection` reaches them through `@Environment`. When no
  session is running, no `AVAudioEngine`, WebSocket, pointer window or capsule panel exists.
- **Explicit consent everywhere.** Turning on Live Voice asks once, naming the live connection and
  model (and the screen pointer connection and model when available), before requesting microphone
  access. Switching to another connection re-asks consent. `liveVoiceEnabled` stays out of
  `settings.json` and out of `.redcast` settings backups; Full Backup records it as a consent and
  never turns it on during import.
- **Session-wide screen consent.** When screen sharing is set to *Every turn* or *When asked*, each
  session asks once at launch (*Share Screen*, *Voice Only*, or *Cancel*), naming every connection
  that will receive screenshots. If Screen Recording permission is off or revoked, Live Voice informs
  the user honestly and starts voice-only without screen tools.
- **Mutual exclusion on the microphone.** Live Voice, Dictation and Ask / Edit by Voice refuse to
  start while another voice session is active.
- **One interface, any provider.** `LiveVoiceWire` is a provider's whole dialect as pure functions:
  what to send for the opening, audio, a picture, typed text, a note, a tool's result, manual reply
  cancellation and a cut reply, and how to read a message back into `LiveVoiceEvent`s.
  `LiveVoiceSession` knows only that vocabulary.
- **A tool family is a source.** `LiveVoiceToolSource` lists `AITool`s and runs an `AIToolCall`, the
  types MCP and agents already use, so `LiveVoiceToolList(tools: mcp.tools(scopedTo: nil)) { await
  mcp.invoke($0, in: chatID) }` connects every enabled MCP server under its existing trust policy.
- **The live model has no hands of its own.** Its built-in tools look (`look_at_screen`), point
  (`point_at`), show text (`show_text`) and start a task (`start_task`). Files, commands and the
  network belong to the selected agent under `AgentBackgroundCoordinator` and that agent's consent
  rules.
- **The screen is material, not instructions.** The prompt and every screenshot's caption say so.
- **The prompt states only the tools the session offers**, as an agent's prompt does.
- **Credentials stay in Keychain; media stays in memory.** `LiveVoiceRoute` reads keys and custom
  headers from `KeychainSecretStore.aiAPIKeys` and `KeychainSecretStore.aiRequestHeaders` for the
  consented connections only. Every socket and locator request uses a private `.ephemeral`
  `URLSession` with `urlCache = nil`. Raw audio and screenshots are never written to disk.
- **Clean audio teardown.** Stopping a session or quitting Redcast cancels in-flight tools and
  waiters, closes the socket, disables voice processing (`setVoiceProcessingEnabled(false)`), resets
  and releases `AVAudioEngine`, and dismisses the capsule and pointer.

## Layout

| File | Holds |
| --- | --- |
| `Model/LiveVoiceWire.swift` | The provider interface |
| `Model/OpenAIRealtimeWire.swift` | OpenAI Realtime (`gpt-realtime-2.1`): server VAD, reasoning effort, manual `response.cancel`, cut-reply truncation |
| `Model/GeminiLiveWire.swift` | Gemini Live (`gemini-3.8-live`): `x-goog-api-key` header, `sessionResumption`, `goAway`, `toolCallCancellation`, video frames |
| `Model/LiveVoiceProvider.swift` | Providers, voices, connection lifetime limits, and pure settings enums |
| `Model/LiveVoiceEvent.swift` | Events, usage, setup (including resumption handle), image |
| `Model/LiveVoiceToolSource.swift` | `LiveVoiceToolSource`, `LiveVoiceToolList`, `LiveVoiceToolbox`, `LiveVoiceToolContext` |
| `Model/LiveVoiceBuiltInTools.swift` | `show_text` and `start_task` (with synchronous refusal when busy/full) |
| `Model/LiveVoicePrompt.swift` | Instructions and built-in tool names |
| `Model/LiveVoiceFrame.swift` | Screenshot fraction to global display point |
| `Model/LiveVoicePointRequest.swift` | Pointer locator request payload and coordinate parser |
| `Model/LiveVoiceTranscript.swift` | Ordered turn/tool transcript builder and reconnect recap formatter |
| `Model/LiveVoiceRoutePolicy.swift` | Pure consent, endpoint mapping, locator eligibility and language resolution |
| `Service/LiveVoiceRoute.swift` | Resolves consented selections and Keychain credentials into wires and locators |
| `Service/LiveVoiceSession.swift` | One conversation: socket, reconnect/resumption, audio, screen, tools, barge-in |
| `Service/LiveVoiceConnection.swift` | Private `.ephemeral` WebSocket with one ordered sender |
| `Service/LiveVoiceAudio.swift` | Lazy `AVAudioEngine` capture/playback, echo modes, 21-bar spectrum meter, clean teardown |
| `Service/LiveVoiceScreenshotter.swift` | Display under cursor as 1,280 px JPEG, excluding Redcast's own windows |
| `Service/LiveVoiceScreenTools.swift` | `look_at_screen` and `point_at` against the latest screenshot |
| `Service/LiveVoicePointLocator.swift` | Private `.ephemeral` request to the user's consented OpenAI-compatible vision endpoint |
| `Settings/LiveVoiceSettings.swift` | `@Observable` store backed by `UserDefaults` (`AppSettingsKey.liveVoice*`) |
| `Settings/LiveVoiceSettingsSection.swift` | Settings → AI → Live Voice UI |
| `UI/LiveVoiceCoordinator.swift` | App integration: consent, screen permission, agent/MCP/chat/usage wiring, session lifecycle |
| `UI/LiveVoiceCapsuleController.swift` | Floating non-activating status/waveform capsule with interrupt, mute and close controls |
| `UI/LiveVoicePointerController.swift` | Theme-styled click-through pointer overlay across displays and Spaces |

## Agents, tools, chat history and usage

- **Agent persona and memory.** When an agent is selected, `AgentContextLoader.load` runs off the
  main actor at session start and feeds bounded instructions (`persona`) and `memory.md` (`memory`)
  into `LiveVoicePrompt`.
- **Background tasks.** `start_task` calls `AgentBackgroundCoordinator.start`, returning a refusal
  immediately if the agent is busy or three background agents are already running, and otherwise
  awaiting `AgentBackgroundCoordinator.awaitCompletion(of:)` to announce the finished summary back
  into the conversation. Stopping Live Voice cancels the waiter without killing the background run.
- **MCP servers.** When MCP is enabled, `MCPCoordinator.warmUpAndWait` gives cold-starting servers a
  brief window so their tools join the opening setup; every call runs through `MCPCoordinator.invoke`
  under its chat trust policy.
- **Show text.** `show_text` opens a Markdown card (`QuickActionPanelController`) supporting Copy,
  Paste into the active app and Continue in AI Chat.
- **Chat history and usage.** Transcripts save incrementally after each reply and on session close
  into `ChatHistoryStore`, bound to the chosen agent via `AgentStore.setAgent` when an agent is
  selected. The saved chat stores `model: nil` so continuing in AI Chat uses a standard chat model,
  while realtime token usage is logged to `UsageLedger` (`origin: .voice`) under the realtime model.

## Reconnects and session limits

- **Gemini Live** requests `sessionResumption`, stores every `sessionResumptionUpdate` handle and
  reconnects cleanly on `goAway` (before its ~10-minute session limit) as well as on unexpected
  drops, keeping `AVAudioEngine` open across the handoff. If a stale handle fails setup, one retry
  starts fresh. Because Gemini does not reliably emit speech-start events, *Every turn* mode sends an
  initial screenshot on ready and also exposes `look_at_screen`.
- **OpenAI Realtime** schedules a proactive reconnect at 55 minutes (ahead of its 60-minute limit)
  between turns, sending a compact system recap from `LiveVoiceTranscript.recap()` so context carries
  over. Interrupting from the capsule sends `response.cancel` and truncates the played item.

## Speed

Measured on 2026-11-20 with a recorded Russian question played into the session at real speed
(`--speech`), from the provider reporting the pause to the reply's first sound; add the 350 ms pause
and about 0.2 s for the time since the last word.

| Turn | `gpt-realtime-2.1` | `gpt-realtime-2.1-mini` |
| --- | ---: | ---: |
| A plain question | 0.7–1.1 s | 0.4–0.6 s |
| About the screen, a screenshot with every turn | 1.0 s | 1.5 s |
| About the screen, through `look_at_screen` | 3.0 s | not measured |
| A request to point: the voice / the pointer landing | 2.3 s / 1.5–2.2 s after the call | 2.1 s / 2.5–3.0 s |

- On OpenAI, *Every turn* sends a screenshot when speech starts so screen questions need no tool
  round trip (`look_at_screen` is omitted to avoid redundant calls). A 1,280 px JPEG is ~380 input
  tokens and captures in 0.10–0.16 s.
- The microphone is read through an `AVAudioSinkNode` in 20 ms chunks sent from the audio thread.

## Pointing

The live model does not output pixel coordinates. `point_at` accepts a plain description of the
target, replies immediately, and `LiveVoicePointLocator` queries the user's consented vision model
(defaulting to `google/gemini-3.1-flash-lite` on OpenRouter or `gemini-3.1-flash-lite` on Gemini)
for `[y, x]` out of 1,000. On measured buttons this landed 8–10 points off on average (vs 280–365
points from the live model directly). Setting **Screen pointer** to *Off* omits `point_at`.

## Pronunciation

`LiveVoicePrompt` names the chosen default language (system language by default, or *Automatic*, or
a specific language) and asks for native pronunciation while passing the ISO code as OpenAI's
transcription language hint. On measured Russian runs (2026-11-20), `marin` and `cedar` scored best
and appear first in OpenAI's voice list.

## Echo

`LiveVoiceAudio.Echo` offers three modes (mapped from Settings → Echo handling):

- **Automatic** (`.cancelled`): attaches and connects playback (`player → mainMixerNode → outputNode`)
  before enabling macOS voice processing on `inputNode` so VPIO initializes cleanly and speakers are
  cancelled out of the mic. If voice processing still cannot initialize on an external device pair,
  `LiveVoiceAudio` logs the exact CoreAudio domain/code to `OSLog` (`io.redcast` / `LiveVoiceAudio`),
  tears down the failed engine, and falls back to **split engines** in `.muted` mode.
- **Headphones** (`.open`): uses two separate `AVAudioEngine` instances (one playback-only, one
  capture-only) so macOS never synthesizes an implicit aggregate device across mismatched hardware,
  giving full duplex without voice processing.
- **Mute while speaking** (`.muted`): uses the same split capture/playback engines and gates the mic
  during playback plus a 250 ms tail.

If a user-selected microphone fails to open in split mode, `LiveVoiceAudio` logs the failure and
retries the system default input before reporting a short localized error (`LiveVoiceAudio.Failure`).

## Stand and testing

A standalone terminal stand still drives the core layers directly without launching Redcast:

```sh
OPENAI_API_KEY=… ./Scripts/live-voice.sh                     # speak; Ctrl-C ends
OPENAI_API_KEY=… ./Scripts/live-voice.sh --screen tool       # the model asks for each screenshot
OPENAI_API_KEY=… ./Scripts/live-voice.sh --text "What is on my screen?" --linger 5
GEMINI_API_KEY=… ./Scripts/live-voice.sh --provider gemini
```

Automated harnesses:

- `live-voice-test`: OpenAI and Gemini wires (opening, audio, image, tool results, cancellation,
  resumption, `goAway`, `error`), frame geometry, prompt generation, toolbox routing, synchronous
  task refusal and delayed completion announcements, `LiveVoiceScreenTools`, `LiveVoicePointRequest`,
  `LiveVoiceTranscript`, `LiveVoiceRoutePolicy` and `LiveVoiceSettings` persistence.
- `live-voice-session-test`: full `LiveVoiceSession` + `LiveVoiceConnection` against a local
  scripted WebSocket server — typed turns, `look_at_screen`, Gemini `sessionResumption` + `goAway`
  reconnect, OpenAI lifetime reconnect with transcript recap, manual interrupt (`response.cancel`),
  unexpected socket drop reconnect and Gemini `toolCallCancellation`.
- `Tests/live-voice-live.swift`: listed in `run-tests.sh` as `index` only so editors resolve it
  without calling paid APIs during `./Scripts/run-tests.sh`.

## Live-environment checks still needed manually

Unit and scripted-server harnesses cover protocol framing, reconnect paths, settings and backup
invariants, but real-world hardware and hosted API checks should be verified in a signed app build:

- Gemini Live end-to-end with a real Google AI Studio key (including `x-goog-api-key` auth,
  `sessionResumption` across the ~10-minute boundary and Russian voice quality).
- macOS Voice Processing (`AVAudioInputNode.setVoiceProcessingEnabled(true)`) inside the signed
  `.app` bundle on external USB audio interfaces as well as built-in speakers/mic, plus barge-in
  timing.
- Multi-display and full-screen Space behavior of `LiveVoicePointerController` and the floating
  capsule.
