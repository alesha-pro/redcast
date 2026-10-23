# Extension AI

Raycast extensions call `AI.ask`, `useAI` from `@raycast/utils`, `AI.experimental_decide` and
`environment.canAccess(AI)` to reach Raycast's models. This fork answers them with the model you chose
for extensions, through the same provider layer as AI Chat (`AIProviderFactory`), once you allow each
extension. The feature lives in `Features/ExtensionAI/` and `Scripts/raycast-runtime/src/api/ai.js`;
upstream code only routes `ai` host calls to it and carries a temperature.

## Invariants

- **Off until asked, three times over.** Settings → Extensions → AI → **Allow extensions to use AI**
  (`extensionsAIEnabled`, off by default), AI itself (`AppSettings.aiEnabled`), and each extension's
  own answer to a one-time dialog on its first `AI.ask`. Only a chosen Allow or Don't Allow is kept:
  a dialog dismissed, or one that could not be shown, records nothing. The switches, the model and the
  answers never ride a backup and have no `settings.json` key.
- **The extension model answers unless you let an extension name another.** With **Use the model an
  extension asks for** (`extensionsAIHonorsModels`) off, as it starts, every `AI.Model` value is
  answered by the model chosen for extensions, or by AI Chat's default when that is "Same as AI
  Chat". On, a name whose vendor differs from that model's goes to the vendor's closest model among
  the enabled API connections and the models their pickers show. A name's vendor is its first word,
  so a host serving other vendors' models (`Groq_…`, `Vercel_…`, `gateway-…`) names none, whatever
  model it carries. The extension model is never swapped for another of its own vendor, and a CLI
  route is never chosen. No match, or a route that can't be built, answers with the extension model,
  silently. A `{ id }` model, the extension's own provider, is never surfaced. A pick whose API
  connection was deleted counts as unset; a route merely switched off is reported by the factory,
  never moved to another one.
- **Creativity is a temperature only when the extension asks.** No `creativity`, no temperature: every
  route keeps its default, and a Gemini model always does. A route that refuses one before any text
  arrives is asked once more without it.
- **Only what the user did may ask.** Each host context reports `isActingForUser`, and the bridge
  stamps every `ai.*` call with it. A command the user opened acts for them throughout. A background
  refresh does not, and neither does anything it launches, through `launchCommand` (`UserInitiated`
  included) or a `raycast://` link it opens: the session keeps that origin, so `canAccess(AI)` is false
  and `AI.ask` is refused before any dialog. A menu-bar command acts for the user only while one of its
  items' actions runs: the click is the gesture. Its render never does, even in a menu the user
  opened, because a refresh runs the same render.
- **Pulled, never pushed.** JS keeps one `ai.read` outstanding per answer, and every delta since the
  last read arrives as one chunk. There is no timer, observer or push channel.
- **Every answer has an end.** Leaving the command or the menu ends its answers (`sessionEnded`), an
  abort ends one (`ai.cancel`), and a switch turned off ends them at their next read. Reads check the
  switches, AI and the extension's answer again, not the origin: an answer an item's action started
  may finish after the action, within the menu-bar lane's 60-second deadline. The route's
  `onTermination` cancels its request or process.
- **Nothing is kept.** Prompts and answers are never logged, stored or shown in chat history. The
  request carries the prompt alone: no instructions, system prompt, tools or web search. Only the
  tokens and cost a reply reported reach the usage log, with no extension name (see
  [usage-dashboard.md](usage-dashboard.md)).
- **Raycast's rate limit applies per extension**, in memory: 10 requests a minute and 100 an hour,
  counted after consent and routing, so a refused call costs nothing.
- **The upstream touch is a seam.** `ExtensionHostBridge` routes `ai` to `ExtensionAIHost` with the
  context's `isActingForUser`, the menu-bar lane reports its actions in flight and its launch's
  `aiAccess`, and `AIRequest` carries a `temperature` that two request bodies and Apple Intelligence
  read; everything else is in the fork's folder.

## The request

```
JS  AI.ask ──ai.start{prompt, model?, creativity?}──▶ ExtensionAIGate:
        prompt → gates → model → consent → route (a named vendor?) → rate
        └─▶ ExtensionAIBridge.start(request + temperature, provider, owner) → id
JS  ◀──── id
JS  loop: ai.read(id) ──▶ waits for ≥1 text delta, or the end ──▶ all unread text | null
JS  emit("data", chunk), accumulate; null → resolve(text)
JS  signal "abort" ──ai.cancel(id)──▶ the bridge cancels its task, the route cancels its IO
bridge.sessionEnded() ──▶ cancelAll(owner)   (leaving the command, shutdown, extensions off)
```

- `AI.ask` returns the async function's own `Promise`, with `on`, `once`, `off`, `addListener` and
  `removeListener` attached; each returns that promise, so `await AI.ask(p).on("data", f)` works.
  Chunks are emitted from a settle, always after the caller's synchronous `.on`.
- A string `model` and a string or number `creativity` cross with the prompt; anything else does not.
  `AI.Model` is a Proxy that reads any capitalised name back as itself, so the gate reads the vendor
  from the first word of the key (`Anthropic_Claude_Haiku_4.5`) or of a value an extension wrote out
  (`anthropic-claude-4-5-haiku`), through `AIBrand`, without a table in the runtime.
- An abort rejects with `signal.reason`: `AbortError`, which `usePromise` ignores, or `TimeoutError`
  for `AbortSignal.timeout`. A chunk that lands after the abort is dropped, and a "data" listener that
  throws rejects the answer and cancels it.
- Only `AIStreamEvent.text` is forwarded. Reasoning, thinking, search and usage events are dropped. A
  provider error after some text delivers the text first; the next read throws its message.
- The first `ai.start` of an extension without an answer shows Tinycast's dialog — "Allow “Color
  Picker” to use AI?", naming the model, and with the model switch on also the closest model among
  your API connections — after activating the app: **Allow**, **Don't Allow** and **Not Now**.
  Concurrent asks from one extension share it. Only the first two are kept; Escape, a click elsewhere
  and Not Now refuse this ask once, and the next one asks again. While another Tinycast dialog is up
  nothing is shown and the ask is refused the same way, since a second dialog would resolve unseen. A
  command left while it was up starts nothing.
- `environment.canAccess(AI)` is injected per launch: true when the user opened the command or the
  menu, the gates do not refuse (an unanswered extension still counts, since it will be asked), and a
  model resolves. A menu-bar refresh reports false. An answer given mid-run reaches the next launch.

### Which model answers

With the model switch on, `ExtensionAIModelRoute` maps a name to a pick:

1. The brand of the name's first word (up to `_`, `-` or `/`), `AIBrand.resolve(model:)`:
   `Anthropic_…`/`anthropic-…` is Claude, `OpenAI_…` is OpenAI, `Google_…` is Gemini, `xAI_…` is X,
   and so on through Mistral and Perplexity, or an old family name such as `DeepSeek_R1` or
   `Llama3.1_70B`. That word is Raycast's host, so `Perplexity_Llama3_Sonar_Large` is Perplexity's.
   The hosts serving other vendors' models (`Groq_`/`groq-`, `Vercel_`/`gateway-`, `Baseten_`,
   `Together_AI_`/`together-`), `tinycast` and anything else without a brand stop here: an
   open-weight model on a cheap host never becomes its vendor's own, pricier API.
2. If the extension model already is that brand — an API pick, Claude's or Codex's CLI, a router's
   model — it answers.
3. Otherwise, among the enabled API connections and their shown models of that brand: a vendor's own
   preset (OpenAI, Anthropic, Gemini) before a router or an OpenAI-compatible gateway; then the most
   shared name tokens (runs of letters or digits; a word counts twice a digit); then the fewest extra
   tokens; then the first listed. The effort is the route's default.
4. A pick whose route can't be built (no key, a bad URL) falls back to the extension model.

### Creativity

| `creativity` | temperature |
| --- | --- |
| `"none"` | 0 |
| `"low"` | 0.4 |
| `"medium"` | 0.7 |
| `"high"` | 1 |
| `"maximum"` | 1.5 |
| a number | clamped to 0–2 |
| absent or anything else | none sent |

The scale is OpenAI's, which OpenAI-compatible routes and OpenRouter take as is. Anthropic and Apple
Intelligence hold it to 1, the top of their range. A Gemini model, on its own connection or through a
router, is sent none: Gemini 3 loops below its default (the same reason Voice AI never sends one).
Claude's, Codex's and the other CLIs take no temperature. OpenAI's reasoning models accept only their
default, so a failure that names `temperature` before any text is asked again once without it; a 400
costs nothing.

### `AI.experimental_decide`

It runs in JS on the same `ai.start`/`ai.read` loop as `AI.ask`, so the switches, the dialog, the
origin, the rate limit and an abort apply unchanged. No route returns logprobs, so one prompt at
`creativity: 0` asks the model to state, as one JSON object, a probability for each `noul`, each
option of a `choice` and each level of a `score`; the questions and the state (a string as is,
anything else as JSON) go with it. The reply's first `{` to its last `}` is read back: a `noul` is
held to 0–1, a `choice` is normalised to its options with the likeliest as `choice` and its share as
`confidence`, and a `score` is normalised to its levels with the expected level as `score`, the
likeliest level's share as `confidence` and the criteria as `legend`. These are the model's own
estimates, not calibrated probabilities. Malformed questions reject before any host call.

## Errors

The message is what the extension's `Error.message` reads.

| Case | Message |
| --- | --- |
| switch off | Extensions can't use AI. Turn it on in Settings → Extensions. |
| AI off | AI is off. Turn it on in Settings → AI to let extensions use it. |
| a background refresh or launch, a command one launched, a menu's render | Extensions can use AI only in a command you open or from a menu-bar item you click. |
| answered Don't Allow | This extension isn't allowed to use AI. You can change this in Settings → Extensions. |
| dialog dismissed, or another dialog up | This extension can use AI once you allow it. It will ask again next time. |
| no model | Choose a model for extensions in Settings → Extensions. |
| blank prompt | The prompt is empty. |
| over 256 KB of UTF-8 | The prompt is too long: … KB, where the limit is 256 KB. |
| rate limit | This extension reached its AI limit of 10 requests a minute and 100 an hour. Try again in … s. |
| `experimental_decide` without questions, or one with no type or criteria | a `TypeError` naming the question (English, from the runtime) |
| a decision reply that isn't the JSON asked for, or lacks a question | The model's answer was not the JSON a decision needs. / … has no probabilities for "…". (English) |

A route that is off, a missing key and a failed request pass through as `AIProviderError` messages,
already redacted by the route.

## What maps to what

| Raycast | Tinycast |
| --- | --- |
| `AI.ask(prompt, { model, creativity, signal })` | the extension model answers, or a named vendor's closest model with the switch on; `creativity` is a temperature; `signal` cancels |
| `useAI` | works unchanged on top of `AI.ask` |
| `AI.experimental_decide` | one prompt at `creativity: 0`, the reply rebuilt into `noul`, `choice` and `score` answers |
| `environment.canAccess(AI)` | the `aiAccess` launch flag |
| `AI.Model` | a Proxy: any capitalised name reads back as itself; `Object.entries` lists one `Tinycast` entry |
| a `{ id }` model and `AI.refreshModels()` | the extension model; resolves and does nothing: extension model providers are not surfaced |
| Raycast's per-extension limit | `ExtensionAIRateLimit`, in memory |
| the "get access" prompt | the per-extension dialog, remembered and editable in Settings |

**Extension model providers** (`ai.modelProvider` in the manifest, `getModels`, `streamCompletion`) are
left out on purpose. Surfacing them means a JS-backed route in AI Chat's pickers that keeps an extension
runtime alive across chats, with the AI SDK's message, tool and stream parts — a second provider layer,
not a small step, and a resident runtime the rest of Tinycast avoids.

## Layout

| File | Holds |
| --- | --- |
| `Model/ExtensionAIPolicy.swift` | `ExtensionAIAccess` and the pure decisions: gate order, prompt bounds, the request, creativity as temperature and the retry without it, a dangling pick |
| `Model/ExtensionAIModelRoute.swift` | A named model's vendor and the closest model among the offered connections |
| `Model/ExtensionAIRefusal.swift` | The refusals and their messages |
| `Model/ExtensionAIRateLimit.swift` | The sliding per-extension window |
| `Service/ExtensionAIHost.swift` | The protocol `ExtensionHostBridge` calls |
| `Service/ExtensionAIGate.swift` | The host: gates, the shared question, routing a named model, rate limit; the dialog, AI's switch and the route factory are injected |
| `Service/ExtensionAIBridge.swift` | Answers in flight: coalescing, one reader, owners, cancellation, the retry without temperature |
| `Settings/ExtensionAISettingsStore.swift` | The two switches, the model and the answers in `UserDefaults` |
| `Settings/ExtensionAISettingsSection.swift` | Settings → Extensions → AI |
| `UI/ExtensionAICoordinator.swift` | The gate's wiring, the consent dialog and the Settings actions |
| `Scripts/raycast-runtime/src/api/ai.js` | The `AI` namespace: `ask`, the pull loop, `experimental_decide`, `Model`, `refreshModels` |

Upstream lines: `ExtensionHostBridge` (the `ai` property, one `case`, `askAI`, one line in
`sessionEnded`, `isOpenedByUser` and `isActingForUser` on `ExtensionHostContext` and `openedByUser` on
its two `launch` calls), `ExtensionManager` (`ai`, the running session's origin, `aiAccess` in
`makeLaunchContext`, the menu-bar lane's `.background` for a launch nobody opened, and its executions'
AI host, `setActing` and `aiAccess`), `ExtensionMenuBarManager` (`Execution.setActing` and `aiAccess`,
`pendingActions` reporting, the launch's `aiAccess`), `ExtensionMenuBarHost` (`isRunningAction`) and
`ExtensionCoordinator` (passing `openedByUser` on), `ExtensionLaunchContext.aiAccess`, `AIRequest`'s
`temperature`, `AIRequestBody` and `AppleIntelligenceProvider` (reading it), `AppCore` (the
coordinator and two wiring lines), four `AppSettingsKey` cases with their backup exclusions, the
anchor, two search entries, the section in `ExtensionsSettingsView`, and `system.js`'s
`registerAccess`.

## Weight

No task, timer, observer, file or process exists until an extension calls `AI.ask`. The coordinator
and its gate are a few references and closures; the settings store is created on first use. An answer
in flight is one `Task`, the route's own stream and the unread text, all released on finish, cancel or
session end; a refused temperature costs one more request, once. Routing a named model is a pure pass
over the connections already in memory, per ask. The menu-bar lane holds one flag and one closure per
running command, and a refresh never touches the AI settings. The rate limiter holds at most 100 dates
per extension that asked. The runtime grew by about 3 KB in all. CLI routes spawn a process per answer
only when you pick a CLI model, as Quick Actions do; a named model never reaches one.

## Manual sweep

Install from the store and turn on Settings → Extensions → AI.

1. **Color Picker → Generate Colors** (`useAI`, `stream: false`, expects a bare JSON array). The first
   run shows the dialog naming the model, with Allow, Don't Allow and Not Now; after Allow a grid of
   colours appears. Repeat with an API model and with Apple Intelligence.
2. **Lorem Ipsum → AI Generate** (no-view, gated on `canAccess(AI)`). With the switch off its "no
   access" path runs and no dialog appears; with it on the dialog appears and the text is copied.
3. **Linear → Create Sub-Issues**, or any streaming `useAI` Detail: the markdown grows in place.
   Escape mid-answer leaves at once and the route's request stops (Activity Monitor or a proxy; a CLI
   route's process exits).
4. Don't Allow, then rerun: the extension sees `canAccess(AI) === false` or the "not allowed" error.
   Flip it in Settings and rerun: it works without a dialog. Ask Again brings the dialog back.
   Escape, Not Now, or a click on another app: the "ask again next time" error, no entry appears
   in Settings, and the next run asks again. With another Tinycast dialog up (an extension's
   `confirmAlert`, say), an `AI.ask` fails the same way and no second dialog appears.
5. Eleven quick reruns: the failure toast names the wait.
6. Turn AI off in Settings → AI mid-answer: the answer ends with the AI-off message.
7. A background-refresh no-view command fails silently, as `usePromise` and toasts are quiet in the
   background. A menu-bar command whose refresh calls `launchCommand({ name, type:
   LaunchType.UserInitiated })` on a no-view command that asks AI: no dialog appears on any interval
   and the launched command gets the "command you open or menu-bar item you click" error; opening the
   same command from the launcher asks as usual.
8. A menu-bar command with an item whose action calls `AI.ask` (a local development extension is
   enough): the first click shows the dialog, and after Allow the action gets its answer. An `AI.ask`
   in the menu's render fails with the same error as item 7, whether the menu was opened or refreshed,
   and the item still works afterwards. An answer longer than a minute ends with the lane's timeout.
9. Uninstall an allowed extension and reinstall it: it asks again.
10. Export a settings backup: none of `extensionsAIEnabled`, `extensionsAIModel`, `extensionsAIGrants`,
    `extensionsAIHonorsModels` appear. `settings.json` has no `extensions.ai*` key.
11. Delete the API connection the extension model used, then open Settings → Extensions: the picker
    falls back to "Same as AI Chat".
12. With an OpenAI connection on a reasoning model (`gpt-5`, say) as the extension model, run an
    extension that passes `creativity: "low"`: it answers. A proxy shows a first request with
    `temperature` refused with 400 and a second without it. On an Anthropic model the one request
    carries the temperature, at most 1; on a Gemini model it carries none.
13. Turn on **Use the model an extension asks for** with an OpenAI extension model and an Anthropic
    connection. An extension asking `AI.Model["Anthropic_Claude_Haiku_4.5"]` is answered through the
    Anthropic connection (its usage page, or a proxy); the dialog for a new extension mentions the
    closest model among your API connections. Switch the Anthropic connection off: the OpenAI model
    answers, silently. With an Anthropic extension model the same ask stays on it. With an Anthropic
    extension model, `AI.Model["Groq_GPT-OSS_120b"]` and `AI.Model["Vercel_Gemma_4_31B"]` stay on it
    too, even with an OpenAI and a Gemini connection on.
14. A local development extension calling `AI.experimental_decide` with a `noul`, a `choice` and a
    `score` question gets typed answers whose probabilities sum to 1; on Apple Intelligence a reply
    that strays from JSON fails with "The model's answer was not the JSON a decision needs."

## Harnesses

- `ext-ai-test`: every gate row and its precedence, prompt bounds in UTF-8 bytes, the request's
  shape, creativity as temperature and the retry policy, a named model's vendor (its first word,
  none for Groq's, Vercel's, Baseten's or Together's names), tier and closest name against
  connections of every kind, dangling picks, refusal messages, the rate limit's windows, and the
  bridge against a scripted provider (coalescing, waiting reads, dropped events, text before an
  error, cancel, owners, a cancelled reader, one retry without temperature and none after text),
  plus the store's round trip. The gate itself, with a scripted dialog: a run nobody opened is
  refused before any question; no model is reported before asking; concurrent asks share one
  question; a dismissed or busy dialog keeps nothing; Don't Allow is kept; the gates are checked
  again after the answer; a command left during the question starts nothing; a read checks the gates
  again; the switch ends every answer; a session's end ends only its own; the limit counts only
  routed asks; a named model is used only with its switch, never past a hidden model or a
  switched-off connection, and falls back when its route can't be built; creativity reaches the
  route; a dangling pick falls back to AI Chat's model.
- `ai-provider-test`: the temperature in OpenAI-shaped bodies as given, Anthropic's held to 1, none
  when not asked, and a continued turn keeping it.
- `ext-test`: `AI.ask` streaming under JavaScriptCore, `canAccess(AI)` from the launch context, and
  the real `ExtensionHostBridge` between them: it names itself as the owner, stamps `ai.*` calls and
  `launchCommand`/`raycast://` launches with the context's origin, so a menu-bar refresh's
  `UserInitiated` launch reaches the next command as not the user's, and ends its answers when the
  session ends. Through the real `ExtensionMenuBarManager`: a menu the user opened reports
  `canAccess(AI)` but its render is refused, a click's action asks for the user and gets its answer,
  the gesture ends with the action, closing the menu ends its answers, and a refresh reports no access.
- `node Scripts/raycast-runtime/ai-fixtures.mjs` (also run by `fixtures.mjs`): `canAccess`, streaming,
  late listeners, failures, refusals, abort, an abort while `ai.start` waits on the dialog, timeout, a
  throwing listener, the named model and creativity that cross (and the `{ id }` and junk that don't),
  `AI.Model`, `refreshModels`, `experimental_decide` (a fenced reply into all three answer types, one
  ask at creativity 0 with the questions and state, a bare `noul` clamped, malformed replies, malformed
  questions and an aborted signal before any host call) and `useAI`'s abort-then-ask pattern.
- `node Scripts/raycast-runtime/test.mjs <extension> <command>` with `TEST_AI=1` lets a real
  extension see `canAccess(AI)`; the stub answers each `AI.ask` with `TEST_AI_REPLY` or a fixed line.
