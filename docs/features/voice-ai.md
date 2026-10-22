# Voice AI

**Cloud transcription** is a second engine for the Dictation shortcut: whatever the shortcut is (hold
Fn, toggle, a double tap), the finished recording goes to a Gemini Flash model through the user's own
OpenRouter or Gemini connection, and the cleaned transcript is typed at the cursor through
`TextInjector`, exactly where the on-device model's would be. It is the fork's take on Wispr Flow;
upstream declined voice control (#1550), so it lives in `Features/VoiceAI/` plus a few lines in
`AIRequest`, `AIRequestBody`, `DictationCoordinator` and `AppCore`.

## Invariants

- **Off by default, and the switch is consent.** `VoiceAISettings.cloudDictation` starts false;
  turning it on asks first through `DialogController`, naming the connection and the model that will
  hear the audio. The flag grants a capability, so neither it nor any other Voice AI key travels in a
  backup or has a settings-file key.
- **Network only after a recording ends.** One POST per finished recording; the model list is fetched
  only when **Choose…** is clicked. No timer, observer, session or process exists while idle:
  `VoiceAISettings` and `VoiceCloudTranscriber` are lazy references and hold no other state.
- **Audio stays in memory and is never stored.** The recording becomes a WAV `Data` in memory and is
  sent once on `HTTPAIProvider`'s private `.ephemeral` session with `urlCache = nil`. It is never
  written to disk, logged or put in chat history.
- **Silence never leaves the Mac.** `VoiceAudio.speechRange` trims silence at both ends with 300 ms of
  padding and returns nil for a recording without 200 ms of speech; nil means "No speech was
  recorded" and no request. A `[[NO_SPEECH]]` reply covers what slips through.
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
| `Model/VoicePrompt.swift` | The dictation instructions and request, the vocabulary line |
| `Model/VoiceReply.swift` | `VoiceTranscript.cleaned`: sentinel, wrapping quotes and fences |
| `Model/VoiceRoutePolicy.swift` | Defaults, eligible connections, selection repair, effort choice |
| `Model/VoiceAIFailure.swift` | The feature's own errors |
| `Service/VoiceAIRoute.swift` | A selection to an `HTTPAIProvider`: Keychain key and headers, endpoint policy |
| `Service/VoiceMediaEncoder.swift` | The gate and the encoder, off the main actor |
| `Service/VoiceCloudTranscriber.swift` | The engine `DictationCoordinator` calls, and the consent dialog |
| `Settings/VoiceAISettings.swift` | The fork's own `@Observable` store over `AppSettingsKey` keys |
| `Settings/VoiceModelRow.swift` | Connection and model, the catalog loaded on a click |
| `Settings/VoiceCloudDictationSection.swift` | The Dictation pane's Cloud transcription section |

`AIMessage.audio` carries the recording; `AIRequestBody` writes it as an `input_audio` part with raw
base64 and a `format`, on the OpenAI-compatible shape only ([AI](ai.md#web-search-and-attachments)).
`DictationCoordinator` takes two closures with defaults, `cloudIsOn` and `cloudTranscribe`, and
replaces only its transcription call: capture, the capsule, ducking, Return and Escape, spacing and
capitalization, and the paste or copy destination stay Dictation's. The AI Chat composer mic goes
through the same coordinator, so it uses the same engine.

## Routes and models

`VoiceRoutePolicy.resolve` keeps a stored choice while its connection exists, hears audio and is
enabled. Otherwise it takes the first enabled OpenRouter connection, then Gemini, with the preset, and
last any other OpenAI-compatible connection with the first model it lists. With none, the switch is
disabled and says to add a connection.

| Use | OpenRouter | Gemini | Effort |
| --- | --- | --- | --- |
| Dictation | `google/gemini-3.1-flash-lite` | `gemini-3.1-flash-lite` | `minimal` |

The presets come from OpenRouter's live catalog on 2026-10-22; `~google/gemini-flash-latest` is never a
default because it changes model silently. **Choose…** lists the connection's models that take audio
(OpenRouter's catalog says which; one that doesn't say keeps every model) and saves the cheapest
effort it lists. A typed model id keeps the preset's effort only when it is the preset's own model.
`VoiceAIRoute` mirrors `AIProviderFactory`'s API case but skips its effort filter, since a voice model
need not be in the connection's own model list.

## Prompts

Prompts are never localized. Dictation sends its rules as the system message and one user message: the
text part "Transcribe the recording." and then the audio. The rules ask for what was said and never an
answer, even to a dictated question; each word in the language and script it was spoken in, with no
transliteration, for mixed Russian and English; usual spellings for products, code and acronyms;
punctuation and paragraphs. **Clean up speech** (on by default) drops fillers, stutters and accidental
repeats and keeps only a self-correction; off keeps every word. The Dictation language, when one is
set, becomes "The speaker usually speaks …". **Words to spell exactly** become one line of at most 500
characters. The reply is the transcript only, or `[[NO_SPEECH]]`; `VoiceTranscript.cleaned` strips one
pair of wrapping quotes and a code fence.

## Costs

The encoding sets only the upload size: Gemini bills 32 tokens per second of audio whatever the
format. Twenty seconds of dictation on `gemini-3.1-flash-lite` at `minimal` is about $0.0005 at the
standard tier (640 audio tokens, about 350 prompt and 80 output tokens). The flex and priority tiers
are never requested.

Memory is transient: 15 s of speech is 480 KB of WAV, about 640 KB as base64 in the body. The worst
case, the five-minute cap, is a 9.6 MB WAV, 12.8 MB of base64 and a 12.8 MB body, under Google's 20 MB
inline limit, all freed when the request ends.

## Manual sweep

- **Setup.** With the switch off, the Dictation pane shows only the toggle under Cloud transcription.
  With no OpenRouter, Gemini or OpenAI-compatible connection, it is disabled with a caption. Add one,
  turn it on: the dialog names the connection and the model.
- **Hold Fn.** In TextEdit say "Привет, это тест OpenRouter и Kubernetes, ну, как бы, в пятницу, нет, в
  субботу": clean Cyrillic and Latin text, no fillers, "в субботу".
- **Cleanup off and vocabulary.** Turn Clean up speech off: the fillers stay. Add "Tinycast" to Words
  to spell exactly and say it: it is spelled right.
- **A dictated question.** Dictate "Какая сегодня погода?": it is transcribed, not answered.
- **Silence and cancelling.** Hold for 2 s in silence: "No speech was recorded", and a proxy shows no
  request. Escape while the capsule processes: nothing is typed. Wi-Fi off: the network error is a HUD.
- **The composer mic** in AI Chat uses the cloud engine; switching cloud off returns it to the
  on-device model.
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
  `prompt_tokens_details.audio_tokens`. Compare `gemini-3.5-flash-lite/minimal` the same way, and tune
  `VoiceAudio`'s gate constants with the built-in microphone and a headset.
- Harness: `voice-ai-test` (WAV header and samples, the gate, prompts, the `input_audio` body, transcript
  cleanup, route resolution).
