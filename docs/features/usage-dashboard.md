# AI usage

Settings → AI → **Usage** sums the tokens and cost each reply reported — per model, or per ACP
agent, for a day, a week or a month — from the chat history kept on this Mac and from a small log of
the replies no chat keeps (Quick Actions, Ask by Voice and cloud dictation, extension AI, chat
titles). A strip of bars shows the period's tokens per hour of a day or per day of a week or month.
On a press of **Check Balance** it asks OpenRouter what a key has spent, and with an optional
management key what the account has left. It is the fork's (roadmap item 14 in
[FORK.md](../../FORK.md)), kept to `Features/UsageDashboard/` plus one line each in
`AISettingsView`, `SettingsAnchor` and `SettingsSearchCatalog`, the `databaseURL` that
`ChatHistoryStore` exposes, the two accuracy fixes below, and the `Fork:`-marked lines listed under
[Upstream touches](#upstream-touches).

## Invariants

- **Read-only, off-main, one statement per period shown.** `UsageQuery` opens `ai-chats.sqlite3`
  with `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX`, sets `PRAGMA query_only = 1` and a one-second
  busy timeout, runs one aggregate and closes, all inside a `@concurrent` function. No schema change,
  no index, no write; WAL lets it read beside `ChatHistoryStore`'s writer connection. It checks the
  file exists and never passes `SQLITE_OPEN_CREATE`, so a Mac that never chatted gets an empty
  report and no file.
- **Only while the section is shown, and only with AI on.** The load is a `.task(id:)` on the
  section's first row, keyed on the period and `aiEnabled`: a new period cancels the previous load,
  AI off (when history is closed) runs nothing, and nothing outlives the section. There is no timer,
  observer or cache; showing the section again reads again.
- **Attribution is per conversation, ACP binding first.** A chat bound to an ACP agent
  (`agent-chats.json`, an agent with a `runtime`) is the agent's, since its CLI ran it whatever the
  model picker held. Otherwise `conversation_details.model` is decoded as `AIModelSelection` and keyed
  by source and model id, so neither effort nor JSON key order (Swift does not sort keys) splits one
  model into two lines. A missing or unreadable model is **Unknown model**.
- **Costs are what each route reported, never estimates.** A line's cost is the sum of what its
  replies cost. No price table exists: OpenRouter's figure is what it billed, Claude Code's and
  OpenCode's are their own estimates. A reply with no cost stays unpriced and is told apart from one
  that cost 0; the summary says "Cost reported for 12 of 30 replies" when only some were priced.
- **An ACP reply costs what its session's total rose.** ACP reports cost as the session's running
  total (`usage_update.cost`), and each ACP reply stores it as it came. So in a chat bound to an ACP
  agent a reply counts its `cost_usd` minus the last priced reply's before it in that chat — taken
  from before the period too, so a day or week never inherits earlier spend — and counts whole when
  the total drops, which is the agent counting afresh (Claude Code does after a relaunch, and a new
  agent always does). Every other reply counts its `cost_usd` as stored. The same statement does
  both, with a `LAG` window over the bound chats alone.
- **A balance is fetched on a press, on a session made for it.** **Check Balance** reads the
  connection's key from Keychain off-main, checks the base URL with `AIEndpointPolicy`, and sends
  `GET /key` — then `GET /credits` with a stored management key, or with the chat key only when it
  says it is one — on a per-call `.ephemeral` session with no URL cache and no cookie storage,
  invalidated once the check ends.
  The answer lives in the row's `@State` and goes with it: never persisted, polled or refreshed.
- **Replies no chat keeps are logged, and only their numbers.** `UsageRecordingProvider` wraps the
  provider at the four places such a reply is asked for — `AppCore.quickActionProvider`,
  `VoiceAIRoute.provider` (Ask by Voice and cloud dictation), Extension AI's `makeProvider` and
  `AIChatCoordinator`'s title request — and nowhere a chat's reply is, since history already counts
  those. It passes every event through untouched and, once the stream ends (finished, failed or
  stopped after usage arrived), appends one line: the date, the origin, the route
  (`AIModelSource.storageKey`), the model and the reported tokens and cost. No prompt, answer, app or
  extension name is written. Apple Intelligence is never wrapped: it reports nothing, and
  `QuickActionRunner` caps its output by testing the provider's type.
- **The log is append-only, written off-main and bounded by age.** `ai-usage.tsv` in Application
  Support, one tab-separated line per reply, the date first. The append runs on the stream's own
  detached task under one `Mutex`; it ends a line a crash cut short before writing, then reads the
  file's first 32 bytes, and only when that oldest line is more than 430 days old rewrites the file
  atomically without the lines older than 400 days (and any it cannot read). So it holds 400–430
  days and is rewritten about once a month, never on a timer. A failed write never touches the reply.
- **The log stays readable both ways.** A reader ignores fields past the ninth and reads missing
  trailing ones as unreported, so a later build can add columns; an origin it does not know is
  kept as none, and a route it cannot parse is **Unknown model**.
- **The trend is the same statement, sliced in Swift.** The aggregate groups by conversation and
  slice — the last slice start at or before `sent_at`, the starts bound as one JSON array — and
  `UsagePeriod.slices` computes those starts with the injected `Calendar`, so a 23- or 25-hour day
  and a local midnight are Foundation's. Day has a bar per hour, Week and Month one per day. Log
  entries land in their slice in Swift. A bar is the slice's tokens (every route reports tokens, not
  every route a cost); its tooltip names the slice with its tokens and cost. Plain
  `RoundedRectangle`s, no chart framework, nothing kept once the section goes.
- **A management key goes only to OpenRouter's `/credits`, only on Check Balance.** It is stored per
  OpenRouter connection in its own Keychain scope (`openrouter-management-keys`, account = the
  connection's id), set and removed in a small panel from the balance row that checks for it with
  `hasSecret` and never reads it back, and removed with its connection. Check Balance reads it
  off-main with the chat key and sends it to the fixed `https://openrouter.ai/api/v1/credits` —
  never to the connection's base URL, so a proxy never sees an account key. Without one, the chat
  key is asked for credits only when `/key` says it is a management key.
- **No settings surface, and nothing in a backup.** No `AppSettings` key, no `SettingsFileKey`,
  nothing in `SettingsBackupCoverage`: the period is view state and a balance is transient. The
  usage log is AI usage data like chat history, so no backup category carries it; the management key
  is Keychain material, which never travels. The section dims with the rest of the AI pane while AI
  is off.

## Accuracy fixes it relies on

- **A tool-loop reply costs its whole turn.** `AIToolLoopProvider` and the agents' own
  `AgentLoopProvider` stream each round from a fresh decoder, and a reply keeps the last `.usage` it
  saw. Both loops now add each round's cost to the ones before, so the reply (and `ContextCard`'s
  Cost) carries the turn's spend. Tokens stay the last round's, because the context gauge reads them
  as what the window holds.
- **OpenAI is asked for usage.** OpenAI streams usage only with `stream_options.include_usage`, so
  `AIRequestBody` sends it to OpenAI's own endpoint alone — a base URL on `api.openai.com`, whatever
  the preset. An OpenAI preset pointed at a gateway (Azure, LiteLLM, vLLM…) is not asked, since some
  OpenAI-compatible servers refuse unknown fields with a 400, and OpenRouter reports usage unasked.

## Known limits

- **The model is the conversation's last.** A chat that switched model mid-way is counted under the
  one it ended on; a per-message model would need a column in upstream's schema.
- **Tool turns count the last round's tokens** (their cost is the whole turn's, above).
- **A chat's ACP binding is read as it is now.** Upstream's schema has no per-reply route, so a chat
  moved onto or off an ACP agent mid-way, or whose agent was deleted (which unbinds its chats), has
  every reply read by its present binding: earlier running totals summed as they stand, or earlier
  per-reply costs read as a running total.
- **A fresh ACP count is seen only as a drop.** When the first total after a reset is already above
  the one before it, only the difference counts, so up to that earlier total goes uncounted.
- **Deleted and pruned chats take their usage with them** (`ON DELETE CASCADE`, retention), which is
  what "counted from the chats kept on this Mac" means. The log keeps its replies for 400 days
  whatever happens to chats, and has no Clear button.
- **Claude's own session titles** (`installedAI.claudeTitle`) report no usage and are not logged.
- **OpenRouter BYOK** reports `cost` 0 with the real figure in
  `cost_details.upstream_inference_cost`, which is not parsed.
- **The account balance needs a management key.** `GET /credits` refuses the inference key chats
  use, so without a management key the row says so instead of showing credits.
- **Two clocks.** The section's periods follow this Mac's calendar and time zone; OpenRouter's spend
  is per UTC day, Monday-start UTC week and UTC month, and the row says "(UTC)".

## Layout

| File | Holds |
| --- | --- |
| `Model/UsagePeriod.swift` | Day, week and month intervals from an injected `Calendar`, stepping, titles, the trend's slices |
| `Model/UsageReport.swift` | `UsageTotals`, `UsageRow`, `UsageSubject`, the merged and sorted `UsageReport` with its slices, `UsageFormat` |
| `Model/UsageLedgerEntry.swift` | One logged reply, its line format both ways, and reading and trimming a log's bytes |
| `Model/OpenRouterAccount.swift` | `/key` and `/credits` requests and decoding, the management key's fixed request, what a status means |
| `Service/UsageQuery.swift` | The read-only aggregate by conversation and slice, ACP running totals turned into rises, and the report built with the log off-main |
| `Service/UsageLedger.swift` | `ai-usage.tsv`: the locked append, the age trim and the read |
| `Service/UsageRecordingProvider.swift` | The pass-through provider that logs a reply's usage when its stream ends |
| `Service/OpenRouterAccountClient.swift` | The Keychain reads and the per-call fetch |
| `Settings/UsageSection.swift` | The section, the trend strip, a row per model or agent, a balance row per OpenRouter connection and its management-key panel |

The aggregate scans `message_details` (replies with usage) first: `CROSS JOIN` pins that order, so
`messages` is searched by its primary key rather than scanned whole, and the result is one row per
conversation and slice active in the period — at most a few dozen slices each. The slice is a
subquery over the bound starts (`json_each(?4)`, at most 32 of them) per reply in the period. The
ACP chats' running totals come from a `running` CTE that looks those chats up through
`messages_by_conversation`, their ids bound as one JSON array (`json_each`), so a Mac with no ACP
agent pays nothing for it. Period bounds and slice starts are computed in Swift with the injected
`Calendar`, so day, week and month boundaries and DST are Foundation's, not SQLite's `localtime`.
The log is read in the same off-main call, memory-mapped, and only the lines whose leading date
falls in the period are decoded.

## Upstream touches

Each marked with a one-line `Fork:` comment: the log's wrap in `AppCore.quickActionProvider` and in
`AIChatCoordinator`'s title request; the `openRouterManagementKeys` scope in `KeychainSecretStore`;
its removal in `AIProvidersPanel.removeConnection`; the `usageTrendHeight` token in `Theme`; and the
section's search keywords in `SettingsSearchCatalog`.

## Manual sweep

- AI off: the section is dimmed and shows no lines; no query runs.
- AI on, Month: models with their replies, tokens (input counts cached prompt tokens; hover shows
  the cached and thinking parts) and cost, dearest first; the summary totals them.
- Day and Week: ‹ and › step back and forward; › is disabled on the current period; titles read
  Today, Yesterday, This Week, This Month, then dates.
- A chat on OpenRouter adds its cost; a five-round agent turn on OpenRouter shows the turn's summed
  cost in the context card and here; an OpenAI API chat now records tokens.
- A chat run by an ACP agent is listed under the agent's name and runtime. After three turns with
  Claude Code, its line's cost is the session's total (the context card's Cost on the last reply),
  not the sum of the three totals; on Day, yesterday's turns in the same chat are not added again.
- Delete a chat: its usage leaves the section the next time it shows.
- Check Balance on an OpenRouter connection: UTC spend today, this week and this month, the key's
  limit or "No spending limit on this key", and the management-key caption. A wrong key reads
  "OpenRouter rejected the key."; with the network off, "OpenRouter didn't answer. Try again."
- Nothing refreshes by itself: watch with Little Snitch or `nettop` while the section is open.
- Settings search for "usage", "tokens", "cost", "openrouter" or "management key" lands on the
  section.
- Run a Quick Action on an OpenRouter model, then show the section: its model's line gains a reply
  and its cost, and `ai-usage.tsv` in `~/Library/Application Support/<bundle id>/` has one line with
  no text of the selection or the answer. Do the same with Ask by Voice, a cloud dictation, an
  extension's `AI.ask` and a new chat's title. A Quick Action on Apple Intelligence adds nothing.
- Stop a streaming Quick Action after its first words: no line, unless usage had already arrived.
- The trend: Day shows a bar per hour, Week seven and Month one per day; the current one is tinted
  and later ones are a hairline; hovering a bar names it with its tokens and cost. A 25-hour day
  (the last Sunday of October in Europe) shows 25 bars.
- Management Key… on an OpenRouter row: Save a management key, then Check Balance: the third line is
  the account's credits left. `nettop` shows the `/credits` call to `openrouter.ai` even when the
  connection's base URL is a proxy. A wrong management key reads "OpenRouter rejected the management
  key."; Remove brings back the management-key caption. Deleting the connection in Providers removes
  the key (Keychain Access shows no `openrouter-management-keys` item for it).

## Harness

`usage-dashboard-test` runs the query against a real `ChatHistoryStore` in a scratch folder: sums
per conversation, user messages and replies without usage left out, exact `[start, end)` edges,
cost NULL against 0, a missing database left uncreated, reads beside the open writer and after it
closes. It merges models whose stored JSON differs only in key order and effort, puts an ACP-bound
chat under its agent and a chat with no model under Unknown model, and checks the sort and the
totals. ACP running totals go through the same store: 0.1, 0.3 and 0.6 cost 0.6, a period counts
only the rise inside it, a drop starts counting afresh, an unpriced reply keeps the last total, and a
chat no ACP agent ran sums as stored. Periods use a Berlin Gregorian calendar with Monday weeks (a
23-hour DST day, a week across the clock change, stepping back across a year); formats use `en_US`.
OpenRouter's documented `/key` and `/credits` bodies, an error body and status mapping are decoded
without a network; the management key's request goes to the fixed `/credits` URL and a refusal names
it. It also holds the two accuracy fixes: a two-round tool turn's cost is both rounds', and only
OpenAI's own endpoint is sent `stream_options` — an OpenAI preset on a gateway and an unknown server
are not. `agent-loop-test` holds the agents' loop to the same sum.

The trend: hourly, daily and DST-day slices, the slice each reply lands in from the same statement,
an ACP rise counted in its own slice, and bars that add up to the total. The log: a line reads back
as written, a tab or newline in a model id cannot break it, a later build's fields and origin are
ignored, unreadable lines are none; a scratch file appends, reads only a period's lines, skips a
half-written last line and never lets it swallow the next one, is rewritten past 430 days without
what is older than 400 (not inside the slack), and drops an unreadable head; its entries join their
model's line and their slice, and count on a Mac with no chat history. The recorder passes a scripted
reply through unchanged and logs once with the last usage, logs nothing for a reply without usage,
logs a reply its reader stopped early or that failed after usage, and hands Apple Intelligence back
unwrapped.
