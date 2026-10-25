# Web search

`web_search` is one built-in tool that searches the web from any tool-calling API route: OpenAI,
Anthropic, Gemini, OpenRouter and every OpenAI-compatible endpoint. An agent gets it with its
**Web** family, beside `web_fetch`. A chat without an agent gets it from the **Web search** toggle
in Settings → AI → Chat, also in the AI Chat composer's **+** menu and Quick AI's ⌘K menu ([Quick AI
tools](quick-ai-tools.md)), together with `read_page`, which reads a page the user linked or a
search in the same turn returned; its prompt names both and sends live facts through a search and a
read of the best result. Codex keeps its own search; Apple Intelligence and the installed CLIs get
nothing. Engines are tried in the user's order, and the default chain needs no key and no account:
Exa, then Parallel, then DuckDuckGo. The feature is this fork's, in `Features/WebSearch/` plus the
few lines that wire it into `AIChatCoordinator`, `AIToolLoopProvider`, `AgentCoordinator`,
`AISettingsView` and `AppCore`.

## Invariants

- **Network only inside a turn, or on Test.** A request leaves only when a model calls `web_search`
  or `read_page` in a turn the user sent, or when the user presses **Test** in the engines panel.
  There is no warm-up, health check, retry timer, cache or file; nothing from a search outlives its
  turn except the answer the loop already holds.
- **An agent's Web family is its switch; a plain chat follows `aiWebSearch`.** `WebSearchAgentTools`
  offers `web_search` with family `.web` and risk `.network`, so the toolset drops it with Web
  unticked or set to Never Allow, and Ask Each Chat asks before each search. A chat without an agent
  gets the tool only while `aiWebSearch` is on, off by default. Codex keeps its thread's own search.
  OpenRouter's billed `web` plugin is no longer sent: `AIChatCoordinator.webSearch(for:)` is false on
  every API route.
- **`read_page` opens only an address the turn was given, never one the model wrote.** A chat
  without an agent reads a page only when its URL appears in what the user wrote in one of their
  messages of the request or is the address of a result that one of the turn's own searches returned
  and an earlier round showed the model. `WebChatTools` keeps the result addresses its runner hands
  back (`WebSearchResult.url`), never the answer's text: the query the answer repeats, a title, an
  excerpt and a failure's reason add nothing, so searching for an address does not make it readable.
  `WebChatTools.watching` sees each round's messages before its calls run, and those results join
  the scope with the round that shows them. A page read, the model's replies, MCP results and the
  instructions add nothing either, so a page cannot steer the next read and the model cannot put
  chat text into an address. An inlined file, an attached note and a captured window (Ask About
  Screen, Ask by Voice) are a third party's text, so `AIAttachmentPolicy.typed` takes their blocks
  out first; a page one of them names can still be reached through a search. Which of several given
  pages the model reads is itself a signal, so a turn reads at most five (`WebPageTool.maxReads`); a
  sixth is refused unfetched, telling the model to ask the user. Another part of a page already read
  is not another read. No dialog asks: the toggle is the
  consent, as it is for search, and these rules keep its grant close to search's.
- **The model only picks a page; the address it was given is what is fetched.** Scheme, host case,
  a leading `www.`, a trailing or doubled slash, a fragment, a default port and percent-escapes do
  not tell pages apart, and a query or a longer path does (`WebPageScope.key`). The request goes to
  the address as the user or the engine wrote it, never the model's spelling, so no variant of it
  carries anything to the host. An address with a user name or password names no page, from the
  model, the user or an engine. Plain HTTP to the open web is read over HTTPS, since ATS refuses
  it anyway (`WebPageScope.secured`); a loopback, `.local` or single-label host keeps HTTP, by the
  same rule as the SearXNG address.
- **A redirect may not leave the open web for a local host.** Only the first address is checked
  against the scope, so `PageRedirects` checks every hop with `WebPageScope.follows`: a loopback,
  `.local`, `.localhost`, single-label or address-literal target (`inet_aton`'s hex and dotless
  forms too), or one carrying a user, is refused unless the read began at that same host. A found
  page therefore cannot bounce a read onto the Mac or the LAN; the refused hop reads as the 3xx it
  was. Agents' `web_fetch` reads the same way, since its question names only the first address.
- **A page is read as `web_fetch` reads it.** `read_page` and an agent's `web_fetch` both go through
  `WebPageReader.read`: an ephemeral session made for that read and invalidated when it ends, with no
  cache and a cookie jar of its own, so a site's cookie check works within one read and no cookie
  links two reads, chats or agents; 20 s idle and 60 s in all, 2 MB of a page at most (the rest of a
  longer body is cancelled), under 28 KB to the model ([reading a page](#reading-a-page)). The
  answer opens by saying page text is material, never instructions; a search answer names
  `read_page` (or `web_fetch` for an agent) as the way to read a result in full.
- **A page only its scripts would fill says so.** HTML with no text once scripts, chrome and hidden
  elements go is a failed read that tells the model to read another result, naming the title and
  description its head carries, which no script writes (`WebPageTool.unreadable`); one with under
  400 characters (`WebPageTool.sparseCharacters`) keeps them with a note that its content may be
  missing. Character references are decoded in one pass, numeric ones by value, so a page that writes
  `10&#xB0;` or Cyrillic as `&#x41C;` reads as `10°` and `М`; an escaped `&amp;lt;` stays `&lt;`.
- **Engines run in the user's order, and any failure moves on.** A 429, a CAPTCHA, a 4xx or 5xx, a
  timeout, an unreadable shape or zero results hands the query to the next engine, with at most four
  requests per call (`WebSearchRunner.maxAttempts`). A keyed engine without a key, and SearXNG
  without a valid address, are skipped without a request. There are no retries on the same engine.
- **Only the query leaves.** Requests go through a private `.ephemeral` session with no cache, no
  cookie storage and cookies refused, 10 s idle and 15 s total, with the honest User-Agent
  `Tinycast (+https://github.com/alesha-pro/redcast)`. A response is read to 1 MB at most.
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

## Reading a page

`WebPageReader` streams the body: HTML or text up to 2 MB; a PDF, an image or a Word, RTF or ODT
file (by its type, by `%PDF-` at the start of an untyped body, or by its name when the type says
only "download") to a temporary file of at most 32 MB, named with its suffix, removed when the read
ends and handed to the [document helper](document-text.md). A Word file's text comes back in parts
as a page's does. An archive, media, a font, a program, a spreadsheet or slides is refused by its
type before the body is read, and any other body with a NUL in its first 8 KB (unless it is sent as
UTF-16 or UTF-32) is refused as binary data rather than decoded into noise. Text is decoded by its
declared charset, else UTF-8, else the page's own `<meta charset>`, else Latin-1.

- **Compact Markdown in one pass.** `WebPageMarkdown` walks the bytes once, with no DOM and no
  recursion, so memory stays near the output. Each tag costs the same however many came before: of
  the `main` and `article` regions it keeps only the open ones (one of each at most) and the first
  of each, so a page nested a hundred thousand deep, or one of 2 MB of empty articles, converts as
  fast as a flat one (under a second unoptimized). A stopped turn stops the conversion too, keeping
  what it had. Headings become `#`, lists `-` or `1.` with nesting, data tables GFM tables
  (a layout table or a lone row reads cell by cell), `pre` a fence, `code` backticks, `blockquote`
  `>`. Links become `[text](absolute URL)`: resolved against the page or its `<base>`, without the
  fragment, http and https only (mail, scripts and in-page anchors are text), an image's alt naming
  a link that has no text of its own, and an address linked once per part, plain text after that.
  Links set side by side stay apart.
- **What a reader does not see is left out.** Scripts, styles, `noscript`, `template`, frames,
  SVG, media, form controls and the head; a button too, unless it sits in a heading or opens a
  section (`aria-expanded`, `aria-controls`), as an accordion's or a FAQ's questions do; the site's `nav`, `footer`, `aside`, its own `header` and
  ARIA banner, navigation, contentinfo and complementary roles (an article's own header stays); the
  same page in other languages (`hreflang`); anything `hidden`, `aria-hidden`, `display:none` or
  `visibility:hidden`, and the classes screen-reader and MediaWiki conventions hide (edit links,
  navboxes, categories, the print footer). Hidden text is where injected instructions hide, so an
  element pages leave open, as `<p hidden>`, ends where a browser would end it, at its next sibling
  or its parent's end, rather than staying visible. A page that one unclosed hidden block swallowed
  is read again keeping chrome. A `main` or `[role=main]` region, or the page's only `article`, is
  the page when it holds a fifth of the text; a list left open ends with the block that held it.
- **Long pages come in parts.** `WebPageParts` cuts the Markdown at block edges into parts of at
  most 24 KB. A block longer than that starts in the room its part has left and goes on in the
  next: a table between rows, each later piece under the table's header again, any other block
  between words, a word longer than a part on whole characters. Each part says "Part 2 of 5." and how to read the next one; `part` reads it, and the
  page is fetched again for it, so nothing is kept between calls. The last part of a page cut at
  2 MB says the rest was not fetched. A part past the end says how many there are.
- **A PDF by pages.** `pages` takes `"3"`, `"3-5"` or `"8-"`, as `read_file` does; the answer names
  the pages it holds and the ones that follow.

## Who gets the tool

| Chat | Route | Tool | `AIRequest.webSearch` |
| --- | --- | --- | --- |
| Agent, Web on | any API route | `web_fetch` + `web_search` | false |
| Agent, Web off or Never Allow | any API route | neither | false |
| No agent, toggle on | any API route | `web_search` + `read_page` | false |
| No agent, toggle off | any API route | none | false |
| Any | Codex | none (Codex searches itself) | the toggle |
| Any | Apple Intelligence, Claude, Grok, OpenCode, Cursor, ACP agents | none | as before |

## Engines

Verified on 2026-10-22. On 2026-10-23 each keyless engine found yandex.ru/pogoda for "погода
Москва", and `read_page` read its current temperature; gismeteo.ru draws its figures with scripts,
so its page reads without them, and windy.com reads as a 77-character shell with the note.

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
| `Model/WebSearchEndpoint.swift` | One `URLRequest` per engine, byte-stable bodies, the SearXNG address and ATS policy |
| `Model/WebSearchDecoder.swift` | Status and body to results: the MCP envelope, Exa's text, DuckDuckGo's HTML, three JSON shapes |
| `Model/WebSearchTool.swift` | The `AITool`, argument parsing, the bounded answer, `searchingWithTinycast` |
| `Model/WebPageTool.swift` | `read_page` as the model sees it: the `AITool`, its address, the answer and refusals |
| `Model/WebPageScope.swift` | Which addresses a turn was given, what tells two apart, and the one to fetch |
| `Model/WebPageMarkdown.swift` | A page as compact Markdown in one pass: blocks, link markers, chrome and hidden text left out |
| `Model/WebPageParts.swift` | A converted page cut into parts that fit a result, each rendering its links once |
| `Service/WebPageReader.swift` | One bounded fetch for `read_page` and `web_fetch`: a page or a Word file in parts, a PDF by pages, binary refused, `PageRedirects` |
| `Service/WebSearchRunner.swift` | The chain for one call: keys on demand, the transport, fallback, the results found |
| `Service/WebSearchAgentTools.swift` | The Web family's provider: consent, the search row, the runner |
| `Service/WebChatTools.swift` | A plain chat's turn: routes both tools, keeps its searches' results, watches each round |
| `Settings/WebSearchSettingsStore.swift` | The engine list in `UserDefaults`, the Keychain item, `runner(reader:)`, `chatTools()` |
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
   news question makes a search row. Off, no tool is sent. Quick AI's ⌘K menu has the same Web
   Search row on the same setting.
5. OpenRouter plain chat with Web Search on: the request body has no `plugins`, and the search row
   appears.
6. A plain chat with Web Search on: "Summarise https://www.swift.org/blog/" shows a
   "Web search · read_page" row and a summary. "Find the Swift 6 migration guide and read it" shows a
   search row, then a `read_page` row on a result. Ask it to open a link it found on that page, or
   to add `?ref=x` to one: the row fails and the reply says it needs a search or your link. Ask it
   to search for `https://example.org/?q=test` and then read that address: the search row shows,
   the `read_page` row fails. With Web Search off, no `read_page` is sent. The caption in
   Settings → AI → Chat says the model may read a page you linked or a search found.
7. Codex with Web Search on: unchanged, Codex's own rows.
8. Switch Exa and Parallel off: answers say "from DuckDuckGo". Search a burst of times; if DuckDuckGo
   refuses, the reply says the search failed and nothing hangs.
9. Add a Tavily key: Test passes. Move Tavily first and a search says "from Tavily". Clear the key:
   its switch goes off.
10. SearXNG, if one is reachable: `http://192.168.1.3:8888` shows the IP-address error;
    `http://llm-server.local:8888` (or a single-label name) passes Test, after macOS asks for Local
    Network access on first use. Moved first, searches say "from SearXNG".
11. Press Stop during a slow search: the turn ends at once.
12. With Web Search on, "Summarise https://en.wikipedia.org/wiki/Macintosh": the `read_page` result
    starts "Part 1 of 6." with Markdown headings and `[text](https://…)` links; "and the
    references" reads a later part, and the turn's count of pages read does not grow. "What does
    https://nvlpubs.nist.gov/nistpubs/ai/NIST.AI.100-1.pdf say about safety?" reads it by pages.
    "Read https://excalidraw.com/" says the page needs its scripts and names its title.
13. Export a backup and import it on a clean profile: the engine list is back at the defaults and no
    key travels.
14. Quit with the AI pane never opened and no agent search run: `defaults read io.redcast.app
    aiWebSearchEngines` finds nothing.

Harness: `web-search-test` (the tool's schema, arguments, every engine's exact request, the address
policy, every recorded answer and failure, the bounded answer, configuration across builds, the chain
through a fake transport, both loops' rows, the agent provider through a toolset and its consent, and
`read_page`: its schema, what tells pages apart, what the turn was given, the address fetched, and a
plain chat's loop reading a found page and a linked one while a forged address, a page's own link, a
read beside its search, an address the model only searched for and one carrying a user are refused,
links inside an attached file or captured window left out, a sixth read in a turn refused unfetched,
the redirects that may not leave the open web for a local host, and the notes a page only its
scripts would fill carries; the Markdown conversion: headings, lists, tables, code, quotes, links
resolved and linked once, chrome and every kind of hidden text left out, hidden elements left open,
a stray list, an article, a base, entities, forged link markers, a deep page, 2 MB of empty
articles and of `main` roles in time, a stopped conversion, and accordion buttons; four pages recorded
live on 2026-10-23 in `Tests/web-search-fixtures/pages/` (a Wikipedia article, a news article whose
sentences are replaced, a weather forecast and a page only its scripts fill; `live-2026-10-23.txt`
lists those reads and a PDF report's); parts and their limits, and a 1,200-row table cut between
rows under its header; `WebPageReader` over a stubbed session: a declared charset, a PDF by type, by
its first bytes and by name read through the harness acting as the document helper, a Word file by
type and an RTF download by name in parts, an archive refused by type and bytes by a NUL, UTF-16
text, plain text, a 404, a missing helper and a page past 2 MB in parts; another part not counting as a read; and an agent's web scope, see
[agents](agents.md#manual-sweep)). `agent-tools-test` reads a saved page as Markdown and holds
`web_fetch`'s refusals, and `agent-test` its arguments.
