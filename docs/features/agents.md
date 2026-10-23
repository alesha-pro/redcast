# Agents

An **agent** lives in one folder. A chat given an agent works there: its turns read that folder's
`AGENTS.md`, the skills in `<folder>/.agents/skills` and `~/.agents/skills`, the agent's own notes and
instructions, and its built-in tools — files, terminal, web and memory — act there. Agents are this
fork's; upstream lists AI-assistant features under [not planned](../not-planned.md), so the feature
stays in `Features/Agents/` plus the few lines in `AIChatCoordinator`, `QuickAICoordinator`,
`AIChatDetailView`, `AISettingsView` and `AppCore` that wire it in. An agent can also work with no window, from `@handle`
in root search or on a schedule: see [background and scheduled agents](background-agents.md).

## Invariants

- **An agent runs either on the chat's model or as its own CLI.** `AgentProfile.runtime` nil is the
  built-in agent below; set, the agent is an [ACP](#acp-agents) process — Claude Code, Codex, Gemini
  CLI, OpenCode, Goose, Hermes or any command — and `AIChatCoordinator.provider(for:scopedTo:)` hands
  the chat to `ACPAgentProvider` before any model route is considered.
- **Agent chats run the fork's loop.** `AIChatCoordinator.toolAware` asks
  `AgentCoordinator.loop(over:mcpTools:in:)` first; for a chat whose agent runs on the chat's model it
  returns an `AgentLoopProvider` over an `AgentToolset`, and every other chat keeps upstream's
  `AIToolLoopProvider` untouched. So every route with tool calling — OpenAI, Anthropic, Gemini,
  OpenRouter and any OpenAI-compatible endpoint — runs the agent's tools. The toolset routes a call by
  name: an offered agent tool to its provider, an offered MCP tool to `MCPCoordinator.invoke`, and any
  other name gets "There is no tool called X", so an `@server`-scoped turn cannot reach another
  server. No built-in name contains `__`, so none can be read as an MCP server's tool. The loop
  mirrors upstream's round for round, and `agent-loop-test` runs both on the same scripts. Codex and
  Claude run their own loop and receive the agent's context but not yet its tools; Apple
  Intelligence and routes without tool calling are not agent routes.
- **A tool family is a provider.** An `AgentToolProvider` lists `AgentToolSpec`s — the tool, the
  `AgentToolKind` that switches it, its `AgentToolRisk` and whether it may share a round — and runs one
  call off-main; `AgentCoordinator.providers(for:)` is the registry, one line per family, built per
  turn so nothing stays resident. A provider that needs another feature's types lives in that
  feature's `Service/`, so the harnesses that compile `Agents/Service` never pull in app types; see
  [Adding a tool family](#adding-a-tool-family). The Web family's `web_search` is the second one,
  `WebSearchAgentTools`, so a chat with or without an agent searches through the same
  `WebSearchRunner` ([web search](web-search.md)).
- **The tools menu switches MCP, never the agent.** An agent's tools ride every turn of its chat;
  `ChatToolScope` still narrows MCP servers as before.
- **Consent is decided once, by risk.** A provider calls its context's `consent` before any effect
  beyond reading; the toolset binds it to the call's rule from `AgentConsentPolicy`. A rule of always
  answers at once, never refuses (and the tool is not even offered), and ask raises
  `AgentCoordinator.ask`, a `DialogController` choice of Allow, Allow for This Chat, or Don't Allow.
  By default only changes (`write_file`, `edit_file`, `notes_append`) and commands (`run_command`)
  ask, and `notes_append` asks whatever the rules say; reading files or the user's Notes, the agent's
  own notes and `web_fetch` do not. Allow for This Chat records an `AgentGrant` — one family's one
  risk, so a grant never spreads to another family — in memory, cleared when the chat's agent
  changes. A run with nobody to ask (`AgentRunMode.unattended`) refuses whatever would ask. A declined
  call returns a result telling the model to ask what the user wants instead. Stop voids an answer
  given after it and stops a running command, so neither a late Allow nor the command's next step
  acts once the turn is gone.
- **Each agent may set its own rules.** The editor's Permissions rows — Changes, Commands and Web,
  each shown while the agent can reach that risk — pick Ask Each Chat, Always Allow or Never Allow
  for it, stored as `AgentProfile.consent` in `agents.json` and only where they differ from the
  default, so an untouched agent stores none. Reading and the agent's own notes always run, and an
  addition to the user's Notes always asks, since note text can carry an injected prompt. Always
  Allow also covers runs nobody is watching. `agents.json` has no `SettingsFileKey` and is not in
  `SettingsBackupCoverage`, and it must stay out of both while it carries rules, so an import can
  never grant an agent a capability.
- **The prompt states the rules the toolset runs.** Its Access line reads changes and commands from
  `AgentConsentPolicy.rule(for:in:of:)`, the call `AgentToolset` filters with: approval is promised
  only under ask, Always Allow says nobody sees the change or command first, and Never Allow, an
  unticked family or read-only access says the agent cannot. A model never counts on a check the
  user switched off.
- **Paths are checked after links are followed.** `AgentPathPolicy` resolves `~` and relative paths
  against the folder and standardizes `..` away; the executor then resolves symlinks on both the path
  and the folder before asking. Reading reaches the folder and the granted skills' folders; writing
  reaches the folder (`workspaceWrite`) or anywhere (`fullAccess`); `readOnly` is offered no write
  tool and no terminal at all, and the executor refuses them again if called.
- **Context is read off-main and kept.** `AgentContextLoader` reads the instruction files, scans the
  skills and the notes on a detached task; `AgentCoordinator` caches the result per agent and
  refreshes it after each use, so a send never waits on the disk past an agent's very first turn.
- **Skills load on demand.** The prompt lists each skill's name and description only; `load_skill`
  returns the `SKILL.md` body and the skill's file list, the progressive disclosure Codex and Claude
  Code use. A project skill shadows a global one of the same name; a skill switched off in the editor
  is left out by name, so one added later is in until switched off.
- **What tools return is material, and bounded three times.** The agent's prompt says so. A
  provider cuts its own output first, under 28 KB, so the cut can say where to continue;
  `AgentTurnBudget` then holds each result to 32 KB, as upstream's loop does, and a turn's results to
  512 KB, four times upstream's; and a turn with unlimited rounds stops at the 1 MB history wall.
- **A long turn elides, it does not stop.** Once this turn's results in the resent history pass
  160 KB, `AgentTurnBudget.elide` replaces the oldest ones before the newest round with a stub that
  names the tool and the size and says to call it again, until they fit in 96 KB. Call ids and the
  pairing of calls and results are never touched, a stub is never stubbed again, and the gap between
  the two marks means the prefix changes rarely, so a provider's prompt cache keeps hitting. Elided
  bytes stop counting toward the history wall.
- **Claude is asked to cache; no other route is.** Anthropic and OpenRouter cache a Claude prompt only
  when the request asks, while OpenAI, Gemini, DeepSeek and the rest cache a repeated prefix by
  themselves and are sent as they always were. `AIRequestBody.cacheMarked`, one fork block in upstream's
  file, adds a top-level `cache_control` to a request for Anthropic's own API (`api.anthropic.com`) or
  for an OpenRouter `anthropic/` or `~anthropic/` model, which keeps one breakpoint on the newest block
  as the conversation grows. On Anthropic's own API it also marks the system prompt and the last tool,
  so a new chat with the same agent reads them from the cache: three breakpoints of the four allowed.
  An Anthropic preset pointed at another host is a gateway, which may refuse a field it does not know,
  so it is left alone. Every request on those routes asks, chats and Quick Actions included: a prompt
  under the model's minimum is simply not cached, a write costs a quarter more than plain input and a
  read a tenth, so a turn of two rounds or a reply within five minutes already pays for it.
- **A plan is shown, never kept.** `update_plan` belongs to no family and is the agent's own (risk
  own), so every agent on Tinycast's loop has it and it never asks. The model sends the whole checklist
  each time; `AgentPlanTools` shows it as a reasoning fold with the same lines `ACPEventMapper` draws for
  an ACP agent's plan (`AgentPlan.checklist`), and stores nothing.
- **A sub-agent only reads, on its parent's model, inside its parent's turn.** Sub-agents
  (`AgentToolKind.delegate`, off until ticked) offers `delegate`, which runs one nested
  `AgentLoopProvider` per call over the turn's own route. The child is the agent made read-only with
  Sub-agents removed, so it has no `delegate` of its own and stops at one level; its toolset offers only
  `AgentToolRisk.reads` (read, network, personal: no change, command, `memory_write` or plan), no MCP,
  and runs unattended, so anything whose rule would ask is refused and `screen_context`, which needs a
  turn the user sent, is not offered. It gets the agent's context prompt for that read-only profile
  and a sub-task briefing, never the parent's conversation. It stops after 12
  rounds; its answer is the text after its last call, cut to 16 KB. What it spent comes back as
  `AgentToolSignal.spent` and is billed into the parent's reply. Its own calls never show; the parent's
  row reads "delegate: <name>" through `AgentToolProvider.title(for:)`. One runs at a time, and Stop
  cancels the parent's task group, which ends the child's stream and its task.
- **A newer family never breaks the previous build.** `AgentProfile` writes `tools` with only the
  families the build before Screen and Sub-agents could decode, and those two under `addedTools`, a key
  that build ignores; reading merges both and drops a family name it does not know. A family added later
  joins `AgentToolKind.unknownToOlderBuilds`.
- **A long agent chat keeps notes on what no longer fits, made once and grown rarely.**
  `ChatSession.requestMessages` drops a chat's oldest turns past its text budget. For an agent chat on
  Tinycast's loop, `AgentLoopProvider` first reads the chat's history (`AgentCompaction.Source`, read on
  the main actor when the turn starts) and counts what was dropped. Nothing dropped: no file is read and
  no request is made. Dropped and already covered: the stored notes are reused, with no request.
  Dropped past them: one request to the chat's own model, with no tools, folds the notes so far and only
  the newly dropped messages into new notes (at most 64 KB read, newest first, 6 KB a message; 8 KB
  kept). The new notes reach past what was dropped, to the first question from which at most half of
  what the budget sent is left, so later turns reuse them for a while. They lead the first question
  sent, inside `<earlier_conversation>`, rather than as a message of their own, since some chat
  templates reject two questions in a row, and nothing they cover is sent again. Their cost is billed
  into the reply; tokens are left alone. A tool row, "Summary of earlier messages", opens while they are
  made and closes when done (failed when the request fails, and the turn then goes as it was built);
  reuse shows nothing. The notes are `AgentChatSummary` in `agent-summaries/<chat>.json`, with how many
  messages they cover and the id of the last, so notes on a history that changed underneath start over.
  They go when the chat is deleted (by its id one at a time; all at once or by retention through
  `AppCore.pruneAgentSummaries`, which keeps only the chats still listed), when the chat leaves its
  agent and when its agent is deleted. Plain chats and ACP chats never make any.
- **The binding is the fork's, not the chat history's.** Which chat has which agent is
  `agent-chats.json` beside `agents.json` in Application Support, so upstream's SQLite schema is
  untouched. Deleting an agent frees its chats, which stay as plain AI chats, and deletes its notes.

## ACP agents

An agent whose `runtime` is set runs over the [Agent Client Protocol](https://agentclientprotocol.com):
newline-delimited JSON-RPC 2.0 on the agent's stdio. `AgentRuntime.preset` gives the commands —
`npx -y @agentclientprotocol/claude-agent-acp`, `npx -y @agentclientprotocol/codex-acp`, `gemini
--acp`, `opencode acp`, `goose acp`, `hermes acp` — and the editor lets either half be rewritten.
They run on the user's own logins and subscriptions; Tinycast never sees a key.

- **One process per agent, one session per chat.** `AgentACPHost` launches the process in the agent's
  folder through `ExecutableLocator`, so `npx`, `node` and Homebrew tools resolve as in Terminal;
  `initialize` allows four minutes, because an adapter's first `npx` run downloads it. A chat's
  session id is kept in `agent-acp-sessions.json`; after a relaunch or an idle stop (two minutes)
  the next turn sends `session/load` when the agent supports it and drops the replay, since no turn is
  listening, and starts a fresh session when the agent has lost it. A session id is the agent's
  own, and two agents may both say `sess_1`, so turns, updates and permission requests are routed
  by agent and session together.
- **Its sessions show once in Agent Sessions.** A Claude or Codex session whose id is in
  `acpSessions` is listed only as its Tinycast chat (see [agent-sessions.md](agent-sessions.md)).
- **Nothing outlives the agent.** An ACP agent is a tree — `npx`, the adapter, the vendor CLI it
  spawns (Claude Code's is about 380 MB together) — and closing stdin lets the top go while a
  grandchild lingers, orphaned to launchd. `ProcessTree` reads the descendants by `proc_listchildpids`
  before a stop and after every turn, keyed by pid and start time so a reused pid is never
  signalled; a stop closes stdin, sends SIGTERM to every survivor a second later and SIGKILL two
  seconds after that, and an agent that exits on its own has its last-known tree reaped the same way.
  `Process.terminate` alone reaches only the child's process group, which a detached child has left.
  An idle agent is stopped after two minutes; `AgentACPHost.release` stops it as soon as a run that
  nobody is watching ends.
- **Context goes once, to a fresh session.** `AgentContext.briefing` — global and project
  instructions when switched on, skills by name and `SKILL.md` path, notes and the agent's own
  instructions — leads the first prompt of a new session, with the chat's earlier turns (newest
  first, 24 KB, a cut said) when the chat began before this session did. A reloaded session needs
  neither.
- **Tinycast offers no fs or terminal of its own.** `initialize` declares both off, so the agent uses
  its own tools and asks about them with `session/request_permission`; any `fs/*`, `terminal/*` or
  other request is answered with method-not-found. The permission dialog lists the agent's own
  options, allows first and the least committal refusal last, where the dialog keeps its cancel; the
  agent remembers an "always" itself. Stop sends `session/cancel` and answers every open permission
  request as cancelled. A dialog closed unanswered picks the agent's refuse-once option, or cancels
  when it offers none, so no "always" comes from a choice nobody made.
- **Updates map onto the transcript.** Message chunks are text, thought chunks reasoning, a plan a
  reasoning block when it changes, tool calls rows that close exactly once — a call still open when
  the turn ends is closed as failed — and one usage at the end from the prompt's result, with the
  window and cost from the last `usage_update` (ACP's cost is the session's running total, stored as
  it came). Attachments go as image blocks and embedded resources when the agent declared it takes
  them, else inlined. A `refusal` stop reason is an error.
- **Modes are the agent's.** The modes a session offers (Claude Code's plan, Codex's read-only…)
  replace the model and reasoning pickers in the composer. The choice is stored on the agent as
  `acpMode`, applied with `session/set_mode` to a live session and to each new one, and the menu
  follows `current_mode_update` when the agent moves itself.
- **The chat's MCP servers ride `session/new`.** Command servers always, HTTP ones when the agent
  declares `mcpCapabilities.http`, narrowed by the chat's tools menu like any other route.

## Layout

| File | Holds |
| --- | --- |
| `Model/AgentProfile.swift` | The profile: folder, access, tool families, permissions, skill sources, instructions sources, model |
| `Model/AgentStore.swift` | Agents and chat bindings as JSON; where the agent's notes and a chat's summary live |
| `Model/AgentSkill.swift` | `SKILL.md` front matter, the merged catalog, and `AgentContext.prompt` |
| `Model/AgentToolbox.swift` | `AgentPathPolicy`, the tool definitions per profile, and what each reaches (`spec(for:)`) |
| `Model/AgentTool.swift` | `AgentToolProvider`, `AgentToolSpec`, `AgentToolRisk`, `AgentTurn`, `AgentRunMode`, the call's context |
| `Model/AgentConsentPolicy.swift` | Rules (ask, always, never), an agent's own (`AgentConsentRules`), `AgentGrant`, the verdict per rule and mode |
| `Model/AgentToolset.swift` | One turn's offered tools in a stable order, and where each call goes |
| `Model/AgentTurnBudget.swift` | The per-result, per-turn and history limits; `AgentBatchPolicy` |
| `Model/AgentCompaction.swift` | Cross-turn notes: what was dropped, what they cover, when they grow, the request that makes them, `AgentChatSummary` |
| `Model/AgentPlan.swift` | `update_plan`'s definition and arguments, and the checklist ACP plans share |
| `Service/AgentContextLoader.swift` | Reads `AGENTS.md` (or a lone `CLAUDE.md`), `~/.agents/AGENTS.md`, skills, notes |
| `Service/AgentToolExecutor.swift` | `AgentBuiltInTools`, the first provider; the executor runs each call: ripgrep search, terminal with timeout, web fetch, HTML to text |
| `Service/AgentLoopProvider.swift` | The agent chats' tool loop: cross-turn notes, rounds, batches, budget, Stop |
| `Service/AgentPlanTools.swift` | `update_plan`: shows the checklist it is sent |
| `Service/AgentDelegateTools.swift` | `delegate`: one read-only sub-agent per call, its answer bounded and its cost billed |
| `UI/AgentCoordinator.swift` | Bindings, cached context, the turn's prompt, its loop and provider registry, consent |
| `Model/AgentRuntime.swift` | ACP presets and the command/arguments an agent runs |
| `Model/ACPProtocol.swift` | Framing, `session/update` decoding, permissions, prompt blocks, modes, `ACPEventMapper` |
| `Service/ACPConnection.swift` | One agent process: launch, `initialize`, requests, permission routing, exit |
| `Service/ProcessTree.swift` | Descendants by pid and start time, and their SIGTERM then SIGKILL |
| `Service/AgentACPHost.swift` | Processes per agent, sessions per chat, load/new, modes; `ACPAgentProvider` |
| `Settings/AgentsSettingsSection.swift`, `AgentEditorPanel.swift` | The AI pane's list, its schedules and the editor |

Background runs and schedules add their own files, listed in
[background-agents.md](background-agents.md#layout).

The composer's agent menu is `AIAgentPicker` in `AIChatDetailView.swift`, beside the model picker,
because the composer's label and menu styles are private to that file.

## Tools

| Tool | Family | Risk | Access | Default | Permissions row |
| --- | --- | --- | --- | --- | --- |
| `list_dir`, `read_file`, `search_files` | files | read | any | always | — |
| `write_file`, `edit_file` | files | change | workspace, full | ask | Changes |
| `run_command` | terminal | execute | workspace, full | ask | Commands |
| `web_fetch` | web | network | any | always | Web |
| `web_search` | web | network | any | always | Web |
| `memory_read` | memory | read | any | always | — |
| `memory_write` | memory | own | any | always | — |
| `load_skill` | — (when skills exist) | read | any | always | — |
| `update_plan` | — | own | any | always | — |
| `delegate` | sub-agents | read (each of its calls meets its own rule) | any | always | — |
| `screen_context` | screen (while Screen Awareness is on) | personal | any | always | — |
| `notes_search`, `notes_read` | notes | personal | any | always | — |
| `notes_append` | notes | change | workspace, full | ask | — (always asks) |

The notes family is off for every agent until ticked, and offered only while Notes is on; see
[notes and AI](notes-ai.md). Sub-agents is off until ticked too, and so is Screen, which is offered only
while [Screen Awareness](screen-awareness.md) is on, only on a turn the user sent from the chat (never a
background run or a sub-agent), and reads the window behind Tinycast as text.

`run_command` runs through `ShellCommandRunner.stream` with the login shell's environment in the
agent's folder, stopped after its timeout (120 s by default, 600 s at most); escape sequences are
stripped and only the output's tail is kept. `search_files` prefers ripgrep and falls back to
`grep -rnIE`, run without a shell so a pattern is never interpreted. `web_fetch` uses a private
`.ephemeral` session with no cache, reads at most 2 MB, and turns HTML into text. `web_search` runs
through [web search](web-search.md)'s engine chain, not the executor; it asks under the same Web rule
and shows a search row between its own row's opening and closing.

Neighbouring calls that may share a round run together, four at most (`AgentLoopProvider.width`),
which bounds memory to four 2 MB fetch buffers and processes to four ripgreps: reads, `web_fetch`,
`web_search` and `load_skill` (`AgentToolSpec.concurrent`). Every row of a batch opens first, each
closes as its call ends, and the model reads the results in the order it asked. A call whose rule
can ask, an MCP call (a second dialog would be refused while the first is up), `memory_write` (two
appends would race on `memory.md`) and any change or command run alone, in their place. Two
concurrent searches' rows complete together, since `AIChatState` closes every open search row on
`.searched`.

## Adding a tool family

Notes ([notes and AI](notes-ai.md)), web search, screen context, the plan and sub-agents each arrived
this way, as one provider. Nothing else changes: no router edit, no upstream line, no prompt edit.

1. Write a `struct` conforming to `AgentToolProvider`. `specs(for:)` lists everything it can offer
   now, with `family` set when a profile switch governs the tool, an honest `risk`, and `concurrent`
   only for a call with no effect and no dialog. `run(_:in:)` validates, calls `context.consent`
   before any effect beyond reading, and keeps its result under 28 KB. Names are `[a-z_]+`, never
   contain `__`, and are new — the first provider to claim a name keeps it.
2. Put it in `Features/Agents/Service/` when it needs only Foundation, and in the other feature's
   `Service/` when it needs that feature's types (`NotesStore`, `ScreenContextReader`, a search
   runner). Main-actor state reaches it as closures, or a `@MainActor` class reference, passed in by
   `providers(for:)`; `NoteAgentTools` in `NotesAI/Service/` is the example.
3. Add one line to `AgentCoordinator.providers(for:)`, gated there on host facts such as a feature's
   setting. That function is the registry, and it is built per turn.
4. A new family gets an `AgentToolKind` case — **not** added to `AgentToolKind.defaults`, so it is
   off for every agent until ticked — and a checkbox in `AgentEditorPanel.toolsField`. A tool no
   profile switch governs (a plan) uses `family: nil`.
5. In the harnesses: its specs (risk, family, concurrent); a refusing consent leaves no effect for
   each spec whose risk is not `read` or `own`; its names are disjoint from every other provider's;
   its cut stays under `AgentTurnBudget.resultBytes`.

## Manual sweep

- Settings → AI → Agents → Add Agent: pick a folder that has an `AGENTS.md` and `.agents/skills`;
  the editor lists the folder's and `~/.agents/skills`' skills, and switching one off keeps it out.
- In AI Chat pick the agent in the composer, on an OpenRouter or API model, and ask what the project
  is: the reply reflects `AGENTS.md`, and the transcript shows `list_dir`/`read_file` calls.
- Ask it to add a line to a file: the dialog shows the path and the change; Don't Allow leaves the
  file untouched and the model asks what to do instead; Allow for This Chat stops the next question.
- Ask it to run `ls ..`: the command dialog appears; ask it to read `../something`: refused.
- Ask a question a skill covers: the transcript shows `load_skill` before the work.
- Ask for a task of several steps: a reasoning fold opens with `Plan:` and ✓, → and · lines, and a later
  call shows the list again with steps ticked.
- Tick Sub-agents and ask the agent to have a sub-agent find where something is defined: one row reads
  "delegate: <name>", none of the sub-agent's own calls show, and the reply's cost is above what its own
  rounds cost. Ask for a sub-agent to change a file: it reports that it cannot. Stop while the sub-agent
  works: the turn ends at once. Untick it: the agent no longer offers to delegate.
- Tell it to remember something, start a new chat with the same agent, ask about it.
- A read-only agent is never offered the terminal or writes; a chat without an agent is unchanged.
- Ask it to run `sleep 30`, then Stop: `ps` shows no `sleep`. Ask for a change, Stop while the dialog
  is up, then click Allow: the file is untouched.
- Turn an MCP server on in an agent chat: the server's tool still asks per its trust and runs.
- In the editor set Changes to Always Allow: the agent writes without a dialog, and asked whether
  you review its edits, it says you do not. Set Commands to Never Allow: asked to run `ls`, it says it
  cannot rather than calling a tool. Set Web to Never Allow: the transcript shows no `web_fetch`, and
  asking it to fetch a page gets no tool row. Set Web to Ask Each Chat: a fetch raises "wants to use
  web_fetch". Reopen the editor: the choices stuck.
- Ask an agent with Web on about today's news: the transcript shows its `web_search` row and a
  "Searched web" row, then the answer cites sources. With Web off it says it cannot look things up.
- Tick Notes in the editor and run [notes and AI](notes-ai.md#manual-sweep)'s agent half.
- Tick Screen and run [Screen Awareness](screen-awareness.md#manual-sweep)'s agent step.
- In a long agent chat (or with a small model whose budget fills fast), keep going until the oldest
  turns no longer fit: one reply opens with a "Summary of earlier messages" row, the next few replies
  show none, and the agent still knows what was settled at the start. Its cost includes the summary.
  Delete the chat: `agent-summaries/` no longer holds its file.
- On an Anthropic connection to `api.anthropic.com`, and again on OpenRouter with an `anthropic/` model,
  ask an agent something that takes it two or three tool rounds: Settings → AI → Usage shows the
  model's input with a "cached" share. Ask again in a new chat within five minutes: the cached share
  covers the prompt and tools from the first request.
- Delete the agent: its chats remain as plain chats and the composer shows No Agent.
- ACP: make an agent on Claude Code in a project folder; ask it to read and change a file. The first
  turn may wait while npx fetches the adapter; then the dialog lists Claude's own options, the
  transcript shows its tool rows, and the composer shows its modes instead of the model picker.
  Switch to Plan and ask again; Stop mid-turn; quit Tinycast and continue the chat — the session
  reloads. Repeat with Codex and with `hermes acp`, and with a command that does not exist (an error
  names it).
- Harnesses: `acp-test` (framing, updates, permissions, prompts, modes and a scripted agent process
  in `Tests/acp-fixtures/fake-agent.mjs`: streaming, consent, reuse, refusal, cancel, reload, lost
  sessions, a missing command, two agents sharing a session id); `agent-test` (skills, catalog, path policy, tool sets, specs, consent
  policy and per-agent rules, toolset order and routing, batches, budget, elision, the prompt and the
  rules it states, persistence, the plan checklist shared with ACP, newer families kept out of the
  previous build's way, a reading-only toolset and per-call row titles, compaction's coverage, reuse,
  bounds and notes kept per chat); `agent-tools-test` (the executor against a real folder: reads,
  writes with consent, link escapes, commands, timeouts and Stop, memory, skills, HTML; the built-ins
  through a toolset, with and without an agent's own rules; every refused effect; `update_plan`); and
  `agent-loop-test` (the fork's loop and upstream's on the same scripts under 128 KB; routing,
  signals, Stop, parallel batches, a long turn that elides; `delegate`'s spec and name, a sub-agent's
  request, tools, answer, cost, bounds and Stop; compaction with nothing dropped, made once then
  reused then grown, a failed summary and Stop while it is made); `web-search-test` covers the search
  provider through a toolset and the loop; `ai-provider-test` pins which routes are asked to cache and
  where the marks go; and `agent-schedule-test` covers background runs and
  schedules (see [background-agents.md](background-agents.md#manual-sweep)).
