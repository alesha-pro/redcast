# AI usage

Settings → AI → **Usage** sums the tokens and cost each AI Chat reply reported — per model, or per
ACP agent, for a day, a week or a month — from the chat history kept on this Mac, and on a press of
**Check Balance** asks OpenRouter what a key has spent. It is the fork's (roadmap item 14 in
[FORK.md](../../FORK.md)), kept to `Features/UsageDashboard/` plus one line each in
`AISettingsView`, `SettingsAnchor` and `SettingsSearchCatalog`, the `databaseURL` that
`ChatHistoryStore` exposes, and the two accuracy fixes below.

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
- **Costs are what each route reported, never estimates.** A line's cost is the sum of `cost_usd`
  over its replies. No price table exists: OpenRouter's figure is what it billed, Claude Code's and
  OpenCode's are their own estimates. A reply with no cost stays unpriced and is told apart from one
  that cost 0; the summary says "Cost reported for 12 of 30 replies" when only some were priced.
- **A balance is fetched on a press, on a session made for it.** **Check Balance** reads the
  connection's key from Keychain off-main, checks the base URL with `AIEndpointPolicy`, and sends
  `GET /key` — then `GET /credits` only when the key says it is a management key — on a per-call
  `.ephemeral` session with no URL cache and no cookie storage, invalidated once the check ends.
  The answer lives in the row's `@State` and goes with it: never persisted, polled or refreshed.
- **No settings surface.** No `AppSettings` key, no `SettingsFileKey`, nothing in
  `SettingsBackupCoverage`: the period is view state and a balance is transient. The section dims
  with the rest of the AI pane while AI is off.

## Accuracy fixes it relies on

- **A tool-loop reply costs its whole turn.** `AIToolLoopProvider` streams each round from a fresh
  decoder, and a reply keeps the last `.usage` it saw. The loop now adds each round's cost to the
  ones before, so the reply (and `ContextCard`'s Cost) carries the turn's spend. Tokens stay the last
  round's, because the context gauge reads them as what the window holds.
- **OpenAI is asked for usage.** OpenAI streams usage only with `stream_options.include_usage`, so
  `AIRequestBody` sends it to `.openAI` routes alone; some OpenAI-compatible servers refuse unknown
  fields with a 400, and OpenRouter reports usage unasked.

## Known limits

- **The model is the conversation's last.** A chat that switched model mid-way is counted under the
  one it ended on; a per-message model would need a column in upstream's schema.
- **Tool turns count the last round's tokens** (their cost is the whole turn's, above).
- **Quick Actions and chat titles record nothing**, since neither writes to chat history; the
  footer says Quick Actions are not counted.
- **Deleted and pruned chats take their usage with them** (`ON DELETE CASCADE`, retention), which is
  what "counted from the chats kept on this Mac" means.
- **OpenRouter BYOK** reports `cost` 0 with the real figure in
  `cost_details.upstream_inference_cost`, which is not parsed.
- **The account balance needs a management key.** `GET /credits` refuses the inference key chats
  use, so the row says so instead of showing credits.
- **Two clocks.** The section's periods follow this Mac's calendar and time zone; OpenRouter's spend
  is per UTC day, Monday-start UTC week and UTC month, and the row says "(UTC)".

## Layout

| File | Holds |
| --- | --- |
| `Model/UsagePeriod.swift` | Day, week and month intervals from an injected `Calendar`, stepping, titles |
| `Model/UsageReport.swift` | `UsageTotals`, `UsageRow`, `UsageSubject`, the merged and sorted `UsageReport`, `UsageFormat` |
| `Model/OpenRouterAccount.swift` | `/key` and `/credits` requests and decoding, what a status means, the binding limit |
| `Service/UsageQuery.swift` | The read-only aggregate, and the report built from it off-main |
| `Service/OpenRouterAccountClient.swift` | The Keychain read and the per-call fetch |
| `Settings/UsageSection.swift` | The section, a row per model or agent, a balance row per OpenRouter connection |

The aggregate scans `message_details` (replies with usage) first: `CROSS JOIN` pins that order, so
`messages` is searched by its primary key rather than scanned whole, and the result is one row per
conversation active in the period. Period bounds are computed in Swift with the injected `Calendar`,
so day, week and month boundaries and DST are Foundation's, not SQLite's `localtime`.

## Manual sweep

- AI off: the section is dimmed and shows no lines; no query runs.
- AI on, Month: models with their replies, tokens (input counts cached prompt tokens; hover shows
  the cached and thinking parts) and cost, dearest first; the summary totals them.
- Day and Week: ‹ and › step back and forward; › is disabled on the current period; titles read
  Today, Yesterday, This Week, This Month, then dates.
- A chat on OpenRouter adds its cost; a five-round agent turn on OpenRouter shows the turn's summed
  cost in the context card and here; an OpenAI API chat now records tokens.
- A chat run by an ACP agent is listed under the agent's name and runtime.
- Delete a chat: its usage leaves the section the next time it shows.
- Check Balance on an OpenRouter connection: UTC spend today, this week and this month, the key's
  limit or "No spending limit on this key", and the management-key caption. A wrong key reads
  "OpenRouter rejected the key."; with the network off, "OpenRouter didn't answer. Try again."
- Nothing refreshes by itself: watch with Little Snitch or `nettop` while the section is open.
- Settings search for "usage", "tokens", "cost" or "openrouter" lands on the section.

## Harness

`usage-dashboard-test` runs the query against a real `ChatHistoryStore` in a scratch folder: sums
per conversation, user messages and replies without usage left out, exact `[start, end)` edges,
cost NULL against 0, a missing database left uncreated, reads beside the open writer and after it
closes. It merges models whose stored JSON differs only in key order and effort, puts an ACP-bound
chat under its agent and a chat with no model under Unknown model, and checks the sort and the
totals. Periods use a Berlin Gregorian calendar with Monday weeks (a 23-hour DST day, a week across
the clock change, stepping back across a year); formats use `en_US`. OpenRouter's documented `/key`
and `/credits` bodies, an error body and status mapping are decoded without a network. It also
holds the two accuracy fixes: a two-round tool turn's cost is both rounds', and only `.openAI` is
sent `stream_options`.
