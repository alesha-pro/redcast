# Extension AI

Raycast extensions call `AI.ask`, `useAI` from `@raycast/utils`, and `environment.canAccess(AI)` to
reach Raycast's models. This fork answers them with the model you chose for extensions, through the
same provider layer as AI Chat (`AIProviderFactory`), once you allow each extension. The feature lives
in `Features/ExtensionAI/` and `Scripts/raycast-runtime/src/api/ai.js`; upstream code only routes `ai`
host calls to it.

## Invariants

- **Off until asked, three times over.** Settings → Extensions → AI → **Allow extensions to use AI**
  (`extensionsAIEnabled`, off by default), AI itself (`AppSettings.aiEnabled`), and each extension's
  own answer to a one-time dialog on its first `AI.ask`. The switch, the model and the answers never
  ride a backup and have no `settings.json` key.
- **One route answers every model.** The requested `AI.Model` value, a `{ id }` model and `creativity`
  are ignored. The answer comes from the model chosen for extensions, or from AI Chat's default when
  that is "Same as AI Chat". A pick whose API connection was deleted counts as unset; a route merely
  switched off is reported by the factory, never moved to another one.
- **Only a command the user opened may ask.** Background refreshes are refused by the policy, and
  menu-bar commands have no AI host at all (`scoped(to:)` does not copy it). `canAccess(AI)` reports
  false in both.
- **Pulled, never pushed.** JS keeps one `ai.read` outstanding per answer, and every delta since the
  last read arrives as one chunk. There is no timer, observer or push channel.
- **Every answer has an end.** Leaving the command ends its answers (`sessionEnded`), an abort ends one
  (`ai.cancel`), and a switch turned off ends them at their next read. The route's `onTermination`
  cancels its request or process.
- **Nothing is kept.** Prompts and answers are never logged, stored or shown in chat history. The
  request carries the prompt alone: no instructions, system prompt, tools or web search.
- **Raycast's rate limit applies per extension**, in memory: 10 requests a minute and 100 an hour,
  counted after consent and routing, so a refused call costs nothing.
- **The upstream touch is a seam.** `ExtensionHostBridge` routes `ai` to `ExtensionAIHost` and
  `ExtensionLaunchContext` carries one `aiAccess` flag; everything else is in the fork's folder.

## The request

```
JS  AI.ask ──ai.start{prompt}──▶ ExtensionAICoordinator: prompt → gates → model → consent → route → rate
                                     └─▶ ExtensionAIBridge.start(request, provider, owner) → id
JS  ◀──── id
JS  loop: ai.read(id) ──▶ waits for ≥1 text delta, or the end ──▶ all unread text | null
JS  emit("data", chunk), accumulate; null → resolve(text)
JS  signal "abort" ──ai.cancel(id)──▶ the bridge cancels its task, the route cancels its IO
bridge.sessionEnded() ──▶ cancelAll(owner)   (leaving the command, shutdown, extensions off)
```

- `AI.ask` returns the async function's own `Promise`, with `on`, `once`, `off`, `addListener` and
  `removeListener` attached; each returns that promise, so `await AI.ask(p).on("data", f)` works.
  Chunks are emitted from a settle, always after the caller's synchronous `.on`.
- An abort rejects with `signal.reason`: `AbortError`, which `usePromise` ignores, or `TimeoutError`
  for `AbortSignal.timeout`. A chunk that lands after the abort is dropped, and a "data" listener that
  throws rejects the answer and cancels it.
- Only `AIStreamEvent.text` is forwarded. Reasoning, thinking, search and usage events are dropped. A
  provider error after some text delivers the text first; the next read throws its message.
- The first `ai.start` of an extension without an answer shows Tinycast's dialog — "Allow “Color
  Picker” to use AI?", naming the model — after activating the app. Concurrent asks from one extension
  share it. Escape counts as Don't Allow. A command left while it was up starts nothing.
- `environment.canAccess(AI)` is injected per launch: true when the launch is not a background one,
  the gates do not refuse (an unanswered extension still counts, since it will be asked), and a model
  resolves. An answer given mid-run reaches the next launch.

## Errors

The message is what the extension's `Error.message` reads.

| Case | Message |
| --- | --- |
| switch off | Extensions can't use AI. Turn it on in Settings → Extensions. |
| AI off | AI is off. Turn it on in Settings → AI to let extensions use it. |
| background refresh | Extensions can't use AI during a background refresh. |
| answered Don't Allow | This extension isn't allowed to use AI. You can change this in Settings → Extensions. |
| no model | Choose a model for extensions in Settings → Extensions. |
| blank prompt | The prompt is empty. |
| over 256 KB of UTF-8 | The prompt is too long: … KB, where the limit is 256 KB. |
| rate limit | This extension reached its AI limit of 10 requests a minute and 100 an hour. Try again in … s. |
| menu-bar command | AI in menu-bar commands is not supported in Tinycast extensions. |

A route that is off, a missing key and a failed request pass through as `AIProviderError` messages,
already redacted by the route.

## What maps to what

| Raycast | Tinycast |
| --- | --- |
| `AI.ask(prompt, { model, creativity, signal })` | the extension model answers; `model` and `creativity` are ignored; `signal` cancels |
| `useAI` | works unchanged on top of `AI.ask` |
| `environment.canAccess(AI)` | the `aiAccess` launch flag |
| `AI.Model` | a Proxy: any capitalised name reads back as itself; `Object.entries` lists one `Tinycast` entry |
| `AI.refreshModels()` | resolves and does nothing: extension model providers are not surfaced |
| `AI.experimental_decide` | rejects as not supported: no route returns calibrated probabilities |
| Raycast's per-extension limit | `ExtensionAIRateLimit`, in memory |
| the "get access" prompt | the per-extension dialog, remembered and editable in Settings |

## Layout

| File | Holds |
| --- | --- |
| `Model/ExtensionAIPolicy.swift` | `ExtensionAIAccess` and the pure decisions: gate order, prompt bounds, the request, a dangling pick |
| `Model/ExtensionAIRefusal.swift` | The refusals and their messages |
| `Model/ExtensionAIRateLimit.swift` | The sliding per-extension window |
| `Service/ExtensionAIHost.swift` | The protocol `ExtensionHostBridge` calls |
| `Service/ExtensionAIBridge.swift` | Answers in flight: coalescing, one reader, owners, cancellation |
| `Settings/ExtensionAISettingsStore.swift` | The switch, the model and the answers in `UserDefaults` |
| `Settings/ExtensionAISettingsSection.swift` | Settings → Extensions → AI |
| `UI/ExtensionAICoordinator.swift` | The host: gates, consent dialog, routing, rate limit |
| `Scripts/raycast-runtime/src/api/ai.js` | The `AI` namespace: `ask`, the pull loop, `Model`, `refreshModels` |

Upstream lines: `ExtensionHostBridge` (the `ai` property, one `case`, `askAI`, one line in
`sessionEnded`), `ExtensionManager` (`ai`, and `aiAccess` in `makeLaunchContext`),
`ExtensionLaunchContext.aiAccess`, `AppCore` (the coordinator and two wiring lines), three
`AppSettingsKey` cases with their backup exclusions, the anchor, the search entry, the section in
`ExtensionsSettingsView`, and `system.js`'s `registerAccess`.

## Weight

No task, timer, observer, file or process exists until an extension calls `AI.ask`. The coordinator
is three stored references; its settings store is created on first use. An answer in flight is one
`Task`, the route's own stream and the unread text, all released on finish, cancel or session end.
The rate limiter holds at most 100 dates per extension that asked. The runtime grew by under 1 KB.
CLI routes spawn a process per answer only when you pick a CLI model, as Quick Actions do.

## Manual sweep

Install from the store and turn on Settings → Extensions → AI.

1. **Color Picker → Generate Colors** (`useAI`, `stream: false`, expects a bare JSON array). The first
   run shows the dialog naming the model; after Allow a grid of colours appears. Repeat with an API
   model and with Apple Intelligence.
2. **Lorem Ipsum → AI Generate** (no-view, gated on `canAccess(AI)`). With the switch off its "no
   access" path runs and no dialog appears; with it on the dialog appears and the text is copied.
3. **Linear → Create Sub-Issues**, or any streaming `useAI` Detail: the markdown grows in place.
   Escape mid-answer leaves at once and the route's request stops (Activity Monitor or a proxy; a CLI
   route's process exits).
4. Don't Allow, then rerun: the extension sees `canAccess(AI) === false` or the "not allowed" error.
   Flip it in Settings and rerun: it works without a dialog. Ask Again brings the dialog back.
5. Eleven quick reruns: the failure toast names the wait.
6. Turn AI off in Settings → AI mid-answer: the answer ends with the AI-off message.
7. A menu-bar command calling `AI.ask` fails with the menu-bar message. A background-refresh no-view
   command fails silently, as `usePromise` and toasts are quiet in the background.
8. Uninstall an allowed extension and reinstall it: it asks again.
9. Export a settings backup: none of `extensionsAIEnabled`, `extensionsAIModel`, `extensionsAIGrants`
   appear. `settings.json` has no `extensions.ai*` key.
10. Delete the API connection the extension model used, then open Settings → Extensions: the picker
    falls back to "Same as AI Chat".

## Harnesses

- `ext-ai-test`: every gate row and its precedence, prompt bounds in UTF-8 bytes, the request's
  shape, dangling picks, refusal messages, the rate limit's windows, and the bridge against a scripted
  provider (coalescing, waiting reads, dropped events, text before an error, cancel, owners, a
  cancelled reader), plus the store's round trip.
- `ext-test`: `AI.ask` streaming under JavaScriptCore, and `canAccess(AI)` from the launch context.
- `node Scripts/raycast-runtime/ai-fixtures.mjs` (also run by `fixtures.mjs`): `canAccess`, streaming,
  late listeners, failures, refusals, abort, timeout, a throwing listener, `useAI`'s abort-then-ask
  pattern, `AI.Model`, `refreshModels` and `experimental_decide`.
- `node Scripts/raycast-runtime/test.mjs <extension> <command>` with `TEST_AI=1` lets a real
  extension see `canAccess(AI)`; the stub answers each `AI.ask` with `TEST_AI_REPLY` or a fixed line.
