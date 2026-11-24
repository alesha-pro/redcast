# Live Voice (prototype)

A spoken, two-way conversation with a realtime model that can see the screen, point at things on it,
put exact text in front of the reader and hand longer work to a background agent. It is the fork's
take on HeyClicky's voice mode.

**It is not wired into the app.** Nothing in `AppCore`, the launcher, Settings or the hotkeys reaches
it, so the shipped app never opens a microphone or a socket for it. The sources build with the app so
they keep compiling, and a hand-run stand drives them from a terminal:

```sh
OPENAI_API_KEY=… ./Scripts/live-voice.sh                     # speak; Ctrl-C ends
OPENAI_API_KEY=… ./Scripts/live-voice.sh --screen tool       # the model asks for each screenshot
OPENAI_API_KEY=… ./Scripts/live-voice.sh --text "What is on my screen?" --linger 5   # no microphone
OPENAI_API_KEY=… ./Scripts/live-voice.sh --speech question.aiff --linger 3          # a recorded voice
GEMINI_API_KEY=… ./Scripts/live-voice.sh --provider gemini
```

With `OPENROUTER_API_KEY` set as well, `point_at` is offered (see [Pointing](#pointing)). `--model`,
`--voice`, `--effort` (OpenAI's reasoning effort, `minimal` by default), `--silence`, `--edge`,
`--locator`, `--language` and `--headphones` are the other switches; the stand prints what was heard
and said, each tool call, the seconds to the reply's first sound, and the tokens each reply reported.
`--show-prompt` prints the instructions, `--instructions FILE` replaces them to try a wording, and
`--record FILE` writes every reply's sound as raw PCM16 mono at 24 kHz.

The terminal the stand runs in needs Screen Recording permission. Without it no screenshot reaches
the model and `point_at` has nothing to point in; the stand says so at launch, and the session tells
the model once so it stops guessing what is on screen.

OpenRouter has no realtime endpoint (its compatibility table lists `/v1/realtime` as not supported),
so a live session needs OpenAI's own key or a Google AI Studio key; OpenRouter serves only the
pointer's locator here.

## Rules it already keeps

- **One interface, any provider.** `LiveVoiceWire` is a provider's whole dialect as pure functions:
  what to send for the opening, audio, a picture, typed text, a note, a tool's result and a cut
  reply, and how to read a message back into `LiveVoiceEvent`s. `LiveVoiceSession` knows only that
  vocabulary. A new provider is one wire file and one case in `LiveVoiceProvider`; a provider that is
  not JSON over a WebSocket does not fit, and none is planned, since WebRTC would need a library.
- **A tool family is a source.** `LiveVoiceToolSource` lists `AITool`s and runs an `AIToolCall`, the
  types MCP and agents already use, so `LiveVoiceToolList(tools: mcp.tools(scopedTo: nil)) { await
  mcp.invoke($0, in: chat) }` is all an MCP server needs to join. `LiveVoiceToolbox` routes a call to
  the first source offering its name and refuses any other name.
- **The live model has no hands of its own.** Its built-in tools look (`look_at_screen`), point
  (`point_at`), show text (`show_text`) and start a task (`start_task`). Files, commands and the
  network belong to the agent a task goes to, under that agent's own consent rules.
- **The screen is material, not instructions.** The prompt and every screenshot's caption say so.
- **The prompt states only the tools the session offers**, as an agent's prompt does.
- **The socket is a private `.ephemeral` session with `urlCache = nil`.** Audio and screenshots stay
  in memory and are never written to disk.

## Layout

| File | Holds |
| --- | --- |
| `Model/LiveVoiceWire.swift` | The provider interface |
| `Model/OpenAIRealtimeWire.swift` | OpenAI Realtime (`gpt-realtime-2.1`): server VAD, the client asks for a reply after a tool or a note, a cut reply is truncated |
| `Model/GeminiLiveWire.swift` | Gemini Live (`gemini-3.8-live`): blocking function calls, a screenshot as one video frame, the server starts and cuts replies |
| `Model/LiveVoiceProvider.swift` | The providers and their default models |
| `Model/LiveVoiceEvent.swift` | Events, usage, the setup, a picture |
| `Model/LiveVoiceToolSource.swift` | The tool source protocol, `LiveVoiceToolList`, `LiveVoiceToolbox` |
| `Model/LiveVoiceBuiltInTools.swift` | `show_text` and `start_task`, each over an injected closure |
| `Model/LiveVoicePrompt.swift` | The instructions, and the built-in tools' names |
| `Model/LiveVoiceFrame.swift` | A place in a screenshot to a global display point |
| `Model/LiveVoicePointRequest.swift` | The locator's question and the point in its reply |
| `Service/LiveVoiceSession.swift` | One conversation: socket, audio, screen, tools, when a reply is owed |
| `Service/LiveVoiceConnection.swift` | The WebSocket, with one ordered sender |
| `Service/LiveVoiceAudio.swift` | Microphone and speaker on one `AVAudioEngine`, echo handling, what a cut reply had played |
| `Service/LiveVoiceScreenshotter.swift` | The display under the cursor as a 1,280 px JPEG, Redcast's own windows left out |
| `Service/LiveVoiceScreenTools.swift` | `look_at_screen` and `point_at`, against the screenshot the model last saw |
| `Service/LiveVoicePointLocator.swift` | One request to an OpenAI-compatible endpoint that finds a described target |
| `UI/LiveVoicePointerController.swift` | The pointer: one click-through panel that exists only while it shows |

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

- A screenshot with every turn (`--screen turn`, the default) is sent when the user starts speaking,
  so an answer about the screen needs no tool round trip; `look_at_screen` is then not offered, since
  the model called it anyway and paid the round trip. A 1,280 px screenshot is about 380 input tokens.
- The mini model answers a plain question sooner but calls tools it was not asked for.
- The microphone is read through an `AVAudioSinkNode` in 20 ms chunks sent from the audio thread; a
  tap would deliver 100 ms at best.
- OpenAI: `reasoning.effort` is `minimal` and the server ends a turn after 350 ms of silence
  (OpenAI's default is 500). Gemini: 500 ms, the bottom of Google's suggested range;
  `gemini-3.8-live` has no thinking level to lower.
- A capture takes 0.10 to 0.16 s on the development Mac (2560×1440, about 115 KB).
- Gemini reports no start of speech in the documented flow, so there a screenshot rides a typed
  question only.

## Pointing

The live model does not place the pointer. Asked for pixel coordinates in its own screenshot,
`gpt-realtime-2.1` missed eight labelled buttons by 280 to 365 points on average, at `minimal`, `low`
and `medium` effort and at 1,280 and 1,920 px. So `point_at` takes the target in words ("the Deploy
button"), answers at once, and `LiveVoicePointLocator` asks a vision model that grounds well where
that is in the same screenshot: `google/gemini-3.1-flash-lite` on OpenRouter, which answers `[y, x]`
out of a thousand. The same buttons then landed 8 to 10 points off on average and 26 at worst, 1.5 to
3 s after the call, while the voice was already answering. A target that is not found is announced
to the model as a note. With no locator `point_at` is not offered.

- The target is the thing's exact visible text and kind. A description with a position in it sent
  the pointer astray (260 points on average), because the live model misreads a layout at this size.
- `gemini-3.8-flash` and `gemini-3.5-flash-lite` were as accurate and slower (2.0 to 4.8 s).
- A newer `point_at` cancels one still looking.

## Pronunciation

The first instructions said only "answer in the language the user speaks", and the owner heard a
heavy accent in Russian. They now name a default language (the stand takes the Mac's own, or
`--language`) and ask for native pronunciation in it, as OpenAI's prompting guide does for accents;
the same code is the transcript's language hint.

Measured on 2026-11-20 by recording replies to one spoken Russian question (`--record`) and asking
`google/gemini-3.8-flash` on OpenRouter to score how native each sounds, 1 to 10. The judge gives a
native recording 10 and scores the same reply several points apart on a second pass, so only the
averages mean anything: four replies each, judged three times.

| Voice | First instructions | With the language and pronunciation sections |
| --- | ---: | ---: |
| `marin` | 6.4 | 6.8 |
| `cedar` | 5.0 | 7.2 |

- The other eight built-in voices scored 3 to 6 on one reply each with the new sections.
- Calling the assistant a native Muscovite, or writing the pronunciation section in Russian, scored
  no better than the plain wording (6.8 to 8.3 on four replies judged once).
- The accent changes from one session to the next under the same instructions: about half of the
  replies are still heard as accented. Instructions soften it and do not remove it.
- `gpt-realtime-1.5` refuses this wire's opening ("Unsupported option for this model"); two replies
  each from `gpt-realtime-2` and the mini model were too few to tell them apart.

## Echo

`LiveVoiceAudio.Echo` is what keeps the model from hearing itself and taking that for the user cutting
in. `.cancelled` asks macOS for voice processing; if that unit will not start, the session falls back
to `.muted`, where the microphone is deaf while a reply plays and 250 ms after, so the user cannot cut
in by voice. `.open` does nothing and is for headphones.

On the development Mac (USB microphone, Scarlett Solo output, macOS 27) voice processing failed to
initialize with every device pair tried, built-in ones included (`kAudioUnitErr_FailedInitialization`
from the output node), from a command-line process. Whether it starts inside the app bundle is not
known yet.

## Not verified

Run for real on 2026-11-20 against OpenAI: typed and recorded questions, the screen in both modes,
pointing, `show_text`, a `start_task` result announced after its reply, and the owner talking to it
on headphones (0.6 to 1.0 s to the first sound). Open:

- everything Gemini Live: no Google key was available, and OpenRouter cannot carry it. That
  includes its `x-goog-api-key` header on the WebSocket (the official SDK sends it; the guide shows
  the key in the URL) and its roughly ten-minute connection, which needs session resumption;
- cutting in by voice and the truncation it sends, and whether the 350 ms pause cuts into slow
  speech;
- a pronunciation the owner accepts: the scores above are a model's, not an ear's, and Gemini Live's
  voice in Russian has not been heard at all;
- voice processing inside the app bundle;
- a `start_task` result arriving while a reply is still being spoken;
- a 60-minute OpenAI session ending, and reconnecting after a dropped socket.

## Before it ships

A switch that is consent, off by default and in no backup; a shortcut and a launcher row; the
dictation capsule as the indicator; the chosen agent's instructions and `memory.md` as `persona` and
`memory`; `start_task` over `AgentBackgroundCoordinator.start`; MCP through `LiveVoiceToolList`; the
conversation saved as that agent's chat; session-wide consent for the screen in place of
`screen_context`'s dialog per read; `Theme` colours for the pointer; the keys from the chosen
connections' Keychain items; and the locator through the reader's own connection and its consent.

## Testing

`live-voice-test` covers the wires, the geometry, the prompt and the tools; `live-voice-session-test`
runs a whole session against a scripted WebSocket server on this Mac. `Tests/live-voice-live.swift`
is the stand; `run-tests.sh` lists it as `index` only, so editors resolve it and nothing runs it.
