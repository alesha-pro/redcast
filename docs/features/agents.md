# Agents

An **agent** lives in one folder. A chat given an agent works there: its turns read that folder's
`AGENTS.md`, the skills in `<folder>/.agents/skills` and `~/.agents/skills`, the agent's own notes and
instructions, and its built-in tools — files, terminal, web and memory — act there. Agents are this
fork's; upstream lists AI-assistant features under [not planned](../not-planned.md), so the feature
stays in `Features/Agents/` plus the few lines in `AIChatCoordinator`, `AIChatDetailView`,
`AISettingsView` and `AppCore` that wire it in.

## Invariants

- **An agent runs either on the chat's model or as its own CLI.** `AgentProfile.runtime` nil is the
  built-in agent below; set, the agent is an [ACP](#acp-agents) process — Claude Code, Codex, Gemini
  CLI, OpenCode, Goose, Hermes or any command — and `AIChatCoordinator.provider(for:scopedTo:)` hands
  the chat to `ACPAgentProvider` before any model route is considered.
- **Any route with tool calling runs the tools.** The built-in tools are ordinary `AITool`s added in
  `AIChatCoordinator.tools(for:scopedTo:)`, so every route `AIToolLoopProvider` wraps — OpenAI,
  Anthropic, Gemini, OpenRouter and any OpenAI-compatible endpoint — runs them. The loop routes a
  call by name: `AgentToolbox.allNames` to the chat's `AgentToolExecutor`, everything else to MCP.
  No built-in name contains `__`, so none can be read as an MCP server's tool. Codex and Claude run
  their own loop and receive the agent's context but not yet its tools; Apple Intelligence and routes
  without tool calling are not agent routes.
- **The tools menu switches MCP, never the agent.** An agent's tools ride every turn of its chat;
  `ChatToolScope` still narrows MCP servers as before.
- **Every change and every command asks.** `write_file`, `edit_file` and `run_command` go through
  `AgentCoordinator.permit`, a `DialogController` choice of Allow, Allow for This Chat, or Don't Allow.
  The chat grant is per kind (writes, commands), in memory, and cleared when the chat's agent changes.
  A declined call returns a result telling the model to ask what the user wants instead.
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
- **What tools return is material.** The agent's prompt says so, and every result is held under the
  loop's 32 KB cap by the executor first, so a cut can still say where to continue.
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
  listening, and starts a fresh session when the agent has lost it.
- **Its sessions show once in Agent Sessions.** A Claude or Codex session whose id is in
  `acpSessions` is listed only as its Tinycast chat (see [agent-sessions.md](agent-sessions.md)).
- **Nothing outlives the agent.** An ACP agent is a tree — `npx`, the adapter, the vendor CLI it
  spawns (Claude Code's is about 380 MB together) — and closing stdin lets the top go while a
  grandchild lingers, orphaned to launchd. `ProcessTree` reads the descendants by `proc_listchildpids`
  before a stop and after every turn, keyed by pid and start time so a reused pid is never
  signalled; a stop closes stdin, sends SIGTERM to every survivor a second later and SIGKILL two
  seconds after that, and an agent that exits on its own has its last-known tree reaped the same way.
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
  request as cancelled.
- **Updates map onto the transcript.** Message chunks are text, thought chunks reasoning, a plan a
  reasoning block when it changes, tool calls rows that close exactly once — a call still open when
  the turn ends is closed as failed — and one usage at the end from the prompt's result, with the
  window from the last `usage_update`. Attachments go as image blocks and embedded resources when the
  agent declared it takes them, else inlined. A `refusal` stop reason is an error.
- **Modes are the agent's.** The modes a session offers (Claude Code's plan, Codex's read-only…)
  replace the model and reasoning pickers in the composer. The choice is stored on the agent as
  `acpMode`, applied with `session/set_mode` to a live session and to each new one, and the menu
  follows `current_mode_update` when the agent moves itself.
- **The chat's MCP servers ride `session/new`.** Command servers always, HTTP ones when the agent
  declares `mcpCapabilities.http`, narrowed by the chat's tools menu like any other route.

## Layout

| File | Holds |
| --- | --- |
| `Model/AgentProfile.swift` | The profile: folder, access, tool families, skill sources, instructions sources, model |
| `Model/AgentStore.swift` | Agents and chat bindings as JSON; the notes' location |
| `Model/AgentSkill.swift` | `SKILL.md` front matter, the merged catalog, and `AgentContext.prompt` |
| `Model/AgentToolbox.swift` | `AgentPathPolicy` and the tool definitions per profile |
| `Service/AgentContextLoader.swift` | Reads `AGENTS.md` (or a lone `CLAUDE.md`), `~/.agents/AGENTS.md`, skills, notes |
| `Service/AgentToolExecutor.swift` | Runs each call; ripgrep search, terminal with timeout, web fetch, HTML to text |
| `UI/AgentCoordinator.swift` | Bindings, cached context, the turn's prompt, tools and consent |
| `Model/AgentRuntime.swift` | ACP presets and the command/arguments an agent runs |
| `Model/ACPProtocol.swift` | Framing, `session/update` decoding, permissions, prompt blocks, modes, `ACPEventMapper` |
| `Service/ACPConnection.swift` | One agent process: launch, `initialize`, requests, permission routing, exit |
| `Service/AgentACPHost.swift` | Processes per agent, sessions per chat, load/new, modes; `ACPAgentProvider` |
| `Settings/AgentsSettingsSection.swift`, `AgentEditorPanel.swift` | The AI pane's list and the editor |

The composer's agent menu is `AIAgentPicker` in `AIChatDetailView.swift`, beside the model picker,
because the composer's label and menu styles are private to that file.

## Tools

| Tool | Family | Access | Asks |
| --- | --- | --- | --- |
| `list_dir`, `read_file`, `search_files` | files | any | no |
| `write_file`, `edit_file` | files | workspace, full | yes |
| `run_command` | terminal | workspace, full | yes |
| `web_fetch` | web | any | no |
| `memory_read`, `memory_write` | memory | any | no |
| `load_skill` | — (when skills exist) | any | no |

`run_command` runs through `ShellCommandRunner.stream` with the login shell's environment in the
agent's folder, stopped after its timeout (120 s by default, 600 s at most); escape sequences are
stripped and only the output's tail is kept. `search_files` prefers ripgrep and falls back to
`grep -rnIE`, run without a shell so a pattern is never interpreted. `web_fetch` uses a private
`.ephemeral` session with no cache, reads at most 2 MB, and turns HTML into text.

## Manual sweep

- Settings → AI → Agents → Add Agent: pick a folder that has an `AGENTS.md` and `.agents/skills`;
  the editor lists the folder's and `~/.agents/skills`' skills, and switching one off keeps it out.
- In AI Chat pick the agent in the composer, on an OpenRouter or API model, and ask what the project
  is: the reply reflects `AGENTS.md`, and the transcript shows `list_dir`/`read_file` calls.
- Ask it to add a line to a file: the dialog shows the path and the change; Don't Allow leaves the
  file untouched and the model asks what to do instead; Allow for This Chat stops the next question.
- Ask it to run `ls ..`: the command dialog appears; ask it to read `../something`: refused.
- Ask a question a skill covers: the transcript shows `load_skill` before the work.
- Tell it to remember something, start a new chat with the same agent, ask about it.
- A read-only agent is never offered the terminal or writes; a chat without an agent is unchanged.
- Delete the agent: its chats remain as plain chats and the composer shows No Agent.
- ACP: make an agent on Claude Code in a project folder; ask it to read and change a file. The first
  turn may wait while npx fetches the adapter; then the dialog lists Claude's own options, the
  transcript shows its tool rows, and the composer shows its modes instead of the model picker.
  Switch to Plan and ask again; Stop mid-turn; quit Tinycast and continue the chat — the session
  reloads. Repeat with Codex and with `hermes acp`, and with a command that does not exist (an error
  names it).
- Harnesses: `acp-test` (framing, updates, permissions, prompts, modes and a scripted agent process
  in `Tests/acp-fixtures/fake-agent.mjs`: streaming, consent, reuse, refusal, cancel, reload, lost
  sessions, a missing command), `agent-test` (skills, catalog, path policy, tool sets, prompt, persistence) and
  `agent-tools-test` (the executor against a real folder: reads, writes with consent, link escapes,
  commands and timeouts, memory, skills, HTML).
