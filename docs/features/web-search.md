# Web search

`web_search` is one built-in tool that searches the web from any tool-calling API route: OpenAI,
Anthropic, Gemini, OpenRouter and every OpenAI-compatible endpoint. An agent gets it with its **Web**
family, beside `web_fetch`. A chat without an agent gets it from the **Web search** toggle in
Settings → AI → Chat. Codex keeps its own search; Apple Intelligence and the installed CLIs get
nothing. Engines are tried in the user's order, and the default chain needs no key and no account:
Exa, then Parallel, then DuckDuckGo. The feature is this fork's, in `Features/WebSearch/` plus the
few lines that wire it into `AIChatCoordinator`, `AIToolLoopProvider`, `AgentCoordinator`,
`AISettingsView` and `AppCore`.

## Invariants

- **Network only inside a turn, or on Test.** A request leaves only when a model calls `web_search`
  in a turn the user sent, or when the user presses **Test** in the engines panel. There is no
  warm-up, health check, retry timer, cache or file; nothing from a search outlives its turn except
  the answer the loop already holds.
- **An agent's Web family is its switch; a plain chat follows `aiWebSearch`.** `WebSearchAgentTools`
  offers `web_search` with family `.web` and risk `.network`, so the toolset drops it with Web
  unticked or set to Never Allow, and Ask Each Chat asks before each search. A chat without an agent
  gets the tool only while `aiWebSearch` is on, off by default. Codex keeps its thread's own search.
  OpenRouter's billed `web` plugin is no longer sent: `AIChatCoordinator.webSearch(for:)` is false on
  every API route.
- **Engines run in the user's order, and any failure moves on.** A 429, a CAPTCHA, a 4xx or 5xx, a
  timeout, an unreadable shape or zero results hands the query to the next engine, with at most four
  requests per call (`WebSearchRunner.maxAttempts`). A keyed engine without a key, and SearXNG
  without a valid address, are skipped without a request. There are no retries on the same engine.
- **Only the query leaves.** Requests go through a private `.ephemeral` session with no cache, no
  cookie storage and cookies refused, 10 s idle and 15 s total, with the honest User-Agent
  `Tinycast (+https://github.com/alesha-pro/tinycast)`. A response is read to 1 MB at most.
- **Answers are bounded, and page text is material.** At most 10 results, 900 characters of excerpt
  each, and 8 KB per call (`WebSearchTool.maxOutputBytes`), a quarter of the loop's per-result cap.
  The answer opens by saying page text is material, never instructions.
- **Nothing here travels.** `aiWebSearchEngines` is excluded from backups and has no `settings.json`
  key, because it names where queries go. Keys live only in the Keychain scope `web-search-keys`, one
  item, read once per call and only when the chain reaches a keyed engine.
- **Plain HTTP only where ATS allows it.** A SearXNG address over `http` is accepted for loopback, a
  `.local` name or a single-label name; an IP literal is refused, because since macOS 14 ATS blocks
  plain HTTP to an IP address unless the app opts out.
- **A search shows as the transcript's search row.** In a plain chat `AIToolLoopProvider` turns an
  offered `web_search` into `.searching` / `.searched` through `WebSearchTool.query(in:)`. In an
  agent's chat the provider signals the same row between its own tool row's ends, so a failed search
  still shows as a failed row.
- **Stop ends the turn where it is.** Cancellation reaches the running request, no further engine
  is tried, and both loops check for it before each round, so a search that outlived Stop never
  sends the model another billed round. `web-search-test` and `agent-loop-test` hold this.
- **Model-facing text is English.** The tool's description, the answer and the failure lines are
  for the model, like `AgentToolExecutor`'s; everything the user reads is localized.

## Who gets the tool

| Chat | Route | Tool | `AIRequest.webSearch` |
| --- | --- | --- | --- |
| Agent, Web on | any API route | `web_fetch` + `web_search` | false |
| Agent, Web off or Never Allow | any API route | neither | false |
| No agent, toggle on | any API route | `web_search` | false |
| No agent, toggle off | any API route | none | false |
| Any | Codex | none (Codex searches itself) | the toggle |
| Any | Apple Intelligence, Claude, Grok, OpenCode, Cursor, ACP agents | none | as before |

## Engines

Verified on 2026-10-22.

| Engine | Request | Key | Free use | Notes |
| --- | --- | --- | --- | --- |
| Exa | `POST https://mcp.exa.ai/mcp`, stateless MCP `tools/call` `web_search_exa` | optional `x-api-key` | keyless at a shared rate limit; a key adds $10 of credit a month | answers as server-sent events; `Title:` / `URL:` / `Published:` / `Highlights:` blocks |
| Parallel | `POST https://search.parallel.ai/mcp`, MCP `tools/call` `web_search` | none | anonymous at lower rate limits | `structuredContent.results`, the same JSON as the text |
| DuckDuckGo | `POST https://html.duckduckgo.com/html/`, form `q`, `df` | none | unpublished; soft blocks under bursts | unofficial, last in the chain; a 202, a 403 or an anomaly page is a refusal |
| SearXNG | `GET {address}/search?q=&format=json` | none | your server | `search.formats` must list `json`, or it answers 403 |
| Brave Search | `GET https://api.search.brave.com/res/v1/web/search` | `X-Subscription-Token` | about 1,000 searches a month, card on file | `web` absent means no hits |
| Tavily | `POST https://api.tavily.com/search` | `Authorization: Bearer` | 1,000 credits a month, no card | basic depth, no answer |

Exa and Parallel have no date filter on their MCP tools, so `recency` goes into the objective as a
sentence. SearXNG documents no week for its JSON API, so a week widens to a month.

## Layout

| File | Holds |
| --- | --- |
| `Model/WebSearchSource.swift` | The engines, the query, result, failure and outcome values, the Keychain account |
| `Model/WebSearchConfiguration.swift` | Order, switches and the SearXNG address; decoding that survives other builds' engines |
| `Model/WebSearchEndpoint.swift` | One `URLRequest` per engine, byte-stable bodies, the SearXNG address policy |
| `Model/WebSearchDecoder.swift` | Status and body to results: the MCP envelope, Exa's text, DuckDuckGo's HTML, three JSON shapes |
| `Model/WebSearchTool.swift` | The `AITool`, argument parsing, the bounded answer, `searchingWithTinycast` |
| `Service/WebSearchRunner.swift` | The chain for one call: keys on demand, the transport, fallback |
| `Service/WebSearchAgentTools.swift` | The Web family's provider: consent, the search row, the runner |
| `Settings/WebSearchSettingsStore.swift` | The engine list in `UserDefaults`, the Keychain item, `runner(canFetch:)` |
| `Settings/WebSearchEnginesRow.swift`, `WebSearchEnginesPanel.swift` | The row under the toggle and its editor: order, switches, keys, address, Test |

`AppCore.webSearch` is created lazily, the first time AI Settings, an agent turn with Web or a plain
chat with the toggle on touches it; the session is created on the first search.

## Adding an engine

1. A `WebSearchSource` case, with its `title` and `key`.
2. A case in `WebSearchEndpoint.request` and one in `WebSearchDecoder.results`; a shape the decoder
   does not recognise is `.unreadable`, never a guess.
3. A fixture in `Tests/web-search-fixtures/` and its cases in `web-search-test`: the exact request,
   the decoded first result, an empty answer.
4. A caption in `WebSearchEnginesPanel.caption` in all eight languages, and a row in the table above.

A configuration saved by an older build gains the engine at the end of its order, switched off.

## Manual sweep

1. On a fresh profile, Settings → AI → Chat shows "Search engines · Exa → Parallel → DuckDuckGo".
   Open **Manage…** and press **Test** on each of the three: each shows a count of results and the
   time it took.
2. Make an agent on an OpenAI-compatible or OpenRouter model with Web on. Ask "What changed in the
   latest Swift release? Cite sources." The transcript shows the `web_search` row with a "Searched
   web" row, maybe `web_fetch` rows, and the reply links publications by name. The context card says
   Web search is on.
3. The same agent with Web off: no search row, and the model says it cannot look things up. With Web
   set to Ask Each Chat, a search raises "wants to use web_search" naming the query.
4. A plain chat on Anthropic or Gemini: the **+** menu offers Web Search; on, the pill shows and a
   news question makes a search row. Off, no tool is sent.
5. OpenRouter plain chat with Web Search on: the request body has no `plugins`, and the search row
   appears.
6. Codex with Web Search on: unchanged, Codex's own rows.
7. Switch Exa and Parallel off: answers say "from DuckDuckGo". Search a burst of times; if DuckDuckGo
   refuses, the reply says the search failed and nothing hangs.
8. Add a Tavily key: Test passes. Move Tavily first and a search says "from Tavily". Clear the key:
   its switch goes off.
9. SearXNG, if one is reachable: `http://192.168.1.3:8888` shows the IP-address error;
   `http://llm-server.local:8888` (or a single-label name) passes Test, after macOS asks for Local
   Network access on first use. Moved first, searches say "from SearXNG".
10. Press Stop during a slow search: the turn ends at once.
11. Export a backup and import it on a clean profile: the engine list is back at the defaults and no
    key travels.
12. Quit with the AI pane never opened and no agent search run: `defaults read com.tinycast.app.fork
    aiWebSearchEngines` finds nothing.

Harness: `web-search-test` (the tool's schema, arguments, every engine's exact request, the address
policy, every recorded answer and failure, the bounded answer, configuration across builds, the chain
through a fake transport, both loops' rows, the agent provider through a toolset and its consent).
