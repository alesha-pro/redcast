# Extension AI

Raycast extensions call `AI.ask`, `useAI` from `@raycast/utils`, and `environment.canAccess(AI)` to
reach Raycast's models. This fork answers them with the model you chose for extensions, through the
same provider layer as AI Chat (`AIProviderFactory`), once you allow each extension. The feature lives
in `Features/ExtensionAI/` and `Scripts/raycast-runtime/src/api/ai.js`; upstream code only routes `ai`
host calls to it.

## Invariants

- **Off until asked, three times over.** Settings → Extensions → AI → **Allow extensions to use AI**
  (`extensionsAIEnabled`, off by default), AI itself (`AppSettings.aiEnabled`), and each extension's
  own answer to a one-time dialog on its first `AI.ask`. Only a chosen Allow or Don't Allow is kept:
  a dialog dismissed, or one that could not be shown, records nothing. The switch, the model and the
  answers never ride a backup and have no `settings.json` key.
- **One route answers every model.** The requested `AI.Model` value, a `{ id }` model and `creativity`
  are ignored. The answer comes from the model chosen for extensions, or from AI Chat's default when
  that is "Same as AI Chat". A pick whose API connection was deleted counts as unset; a route merely
  switched off is reported by the factory, never moved to another one.
- **Only a command the user opened may ask.** Each host context reports `isOpenedByUser`, and the
  bridge stamps every `ai.*` call and every launch with it. A background refresh is not opened by the
  user, and neither is anything it launches, through `launchCommand` (`UserInitiated` included) or a
  `raycast://` link it opens: the session keeps that origin, so `canAccess(AI)` is false and `AI.ask`
  is refused before any dialog. The menu-bar lane has no AI host at all (`scoped(to:)` does not copy
  it), and a launch onto it from a run nobody opened arrives as `.background`, so it cannot pass
  the user's origin on either.
- **Pulled, never pushed.** JS keeps one `ai.read` outstanding per answer, and every delta since the
  last read arrives as one chunk. There is no timer, observer or push channel.
- **Every answer has an end.** Leaving the command ends its answers (`sessionEnded`), an abort ends one
  (`ai.cancel`), and a switch turned off ends them at their next read. The route's `onTermination`
  cancels its request or process.
- **Nothing is kept.** Prompts and answers are never logged, stored or shown in chat history. The
  request carries the prompt alone: no instructions, system prompt, tools or web search.
- **Raycast's rate limit applies per extension**, in memory: 10 requests a minute and 100 an hour,
  counted after consent and routing, so a refused call costs nothing.
- **The upstream touch is a seam.** `ExtensionHostBridge` routes `ai` to `ExtensionAIHost`,
  `ExtensionLaunchContext` carries one `aiAccess` flag, and a launch carries `openedByUser`;
  everything else is in the fork's folder.

## The request

```
JS  AI.ask ──ai.start{prompt}──▶ ExtensionAIGate: prompt → gates → model → consent → route → rate
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
  Picker” to use AI?", naming the model — after activating the app: **Allow**, **Don't Allow** and
  **Not Now**. Concurrent asks from one extension share it. Only the first two are kept; Escape, a
  click elsewhere and Not Now refuse this ask once, and the next one asks again. While another
  Tinycast dialog is up nothing is shown and the ask is refused the same way, since a second dialog
  would resolve unseen. A command left while it was up starts nothing.
- `environment.canAccess(AI)` is injected per launch: true when the user opened the command, the gates
  do not refuse (an unanswered extension still counts, since it will be asked), and a model resolves.
  An answer given mid-run reaches the next launch.

## Errors

The message is what the extension's `Error.message` reads.

| Case | Message |
| --- | --- |
| switch off | Extensions can't use AI. Turn it on in Settings → Extensions. |
| AI off | AI is off. Turn it on in Settings → AI to let extensions use it. |
| a background refresh, or a command one launched | Extensions can use AI only in a command you open. |
| answered Don't Allow | This extension isn't allowed to use AI. You can change this in Settings → Extensions. |
| dialog dismissed, or another dialog up | This extension can use AI once you allow it. It will ask again next time. |
| no model | Choose a model for extensions in Settings → Extensions. |
| blank prompt | The prompt is empty. |
| over 256 KB of UTF-8 | The prompt is too long: … KB, where the limit is 256 KB. |
| rate limit | This extension reached its AI limit of 10 requests a minute and 100 an hour. Try again in … s. |
| the menu-bar lane: a menu-bar command, or a no-view command launched with `LaunchType.Background` | AI in menu-bar commands and background launches is not supported in Tinycast extensions. |

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
| `Service/ExtensionAIGate.swift` | The host: gates, the shared question, routing, rate limit; the dialog, AI's switch and the route factory are injected |
| `Service/ExtensionAIBridge.swift` | Answers in flight: coalescing, one reader, owners, cancellation |
| `Settings/ExtensionAISettingsStore.swift` | The switch, the model and the answers in `UserDefaults` |
| `Settings/ExtensionAISettingsSection.swift` | Settings → Extensions → AI |
| `UI/ExtensionAICoordinator.swift` | The gate's wiring, the consent dialog and the Settings actions |
| `Scripts/raycast-runtime/src/api/ai.js` | The `AI` namespace: `ask`, the pull loop, `Model`, `refreshModels` |

Upstream lines: `ExtensionHostBridge` (the `ai` property, one `case`, `askAI`, one line in
`sessionEnded`, `isOpenedByUser` on `ExtensionHostContext` and `openedByUser` on its two `launch`
calls), `ExtensionManager` (`ai`, the running session's origin, `aiAccess` in `makeLaunchContext`, and
the menu-bar lane's `.background` for a launch nobody opened), `ExtensionMenuBarHost` and
`ExtensionCoordinator` (passing `openedByUser` on), `ExtensionLaunchContext.aiAccess`, `AppCore` (the
coordinator and two wiring lines), three `AppSettingsKey` cases with their backup exclusions, the
anchor, the search entry, the section in `ExtensionsSettingsView`, and `system.js`'s `registerAccess`.

## Weight

No task, timer, observer, file or process exists until an extension calls `AI.ask`. The coordinator
and its gate are a few references and closures; the settings store is created on first use. An answer in flight is one
`Task`, the route's own stream and the unread text, all released on finish, cancel or session end.
The rate limiter holds at most 100 dates per extension that asked. The runtime grew by under 1 KB.
CLI routes spawn a process per answer only when you pick a CLI model, as Quick Actions do.

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
7. A menu-bar command calling `AI.ask` fails with the menu-bar message. A background-refresh no-view
   command fails silently, as `usePromise` and toasts are quiet in the background. A menu-bar command
   whose refresh calls `launchCommand({ name, type: LaunchType.UserInitiated })` on a no-view command
   that asks AI: no dialog appears on any interval and the launched command gets the "only in a
   command you open" error; opening the same command from the launcher asks as usual.
8. Uninstall an allowed extension and reinstall it: it asks again.
9. Export a settings backup: none of `extensionsAIEnabled`, `extensionsAIModel`, `extensionsAIGrants`
   appear. `settings.json` has no `extensions.ai*` key.
10. Delete the API connection the extension model used, then open Settings → Extensions: the picker
    falls back to "Same as AI Chat".

## Harnesses

- `ext-ai-test`: every gate row and its precedence, prompt bounds in UTF-8 bytes, the request's
  shape, dangling picks, refusal messages, the rate limit's windows, and the bridge against a scripted
  provider (coalescing, waiting reads, dropped events, text before an error, cancel, owners, a
  cancelled reader), plus the store's round trip. The gate itself, with a scripted dialog: a run
  nobody opened is refused before any question; no model is reported before asking; concurrent asks
  share one question; a dismissed or busy dialog keeps nothing; Don't Allow is kept; the gates are
  checked again after the answer; a command left during the question starts nothing; a read checks
  the gates again; the switch ends every answer; a session's end ends only its own; the limit counts
  only routed asks; a dangling pick falls back to AI Chat's model.
- `ext-test`: `AI.ask` streaming under JavaScriptCore, `canAccess(AI)` from the launch context, and
  the real `ExtensionHostBridge` between them: it names itself as the owner, stamps `ai.*` calls and
  `launchCommand`/`raycast://` launches with the context's origin, so a menu-bar refresh's
  `UserInitiated` launch reaches the next command as not the user's, ends its answers when the session
  ends, and on a menu-bar bridge has no AI host.
- `node Scripts/raycast-runtime/ai-fixtures.mjs` (also run by `fixtures.mjs`): `canAccess`, streaming,
  late listeners, failures, refusals, abort, an abort while `ai.start` waits on the dialog, timeout, a
  throwing listener, `useAI`'s abort-then-ask pattern, `AI.Model`, `refreshModels` and
  `experimental_decide`.
- `node Scripts/raycast-runtime/test.mjs <extension> <command>` with `TEST_AI=1` lets a real
  extension see `canAccess(AI)`; the stub answers each `AI.ask` with `TEST_AI_REPLY` or a fixed line.
