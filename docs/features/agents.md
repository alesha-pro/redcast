# Agents

An **agent** lives in one folder. A chat given an agent works there: its turns read that folder's
`AGENTS.md`, the skills in `<folder>/.agents/skills` and `~/.agents/skills`, the agent's own notes and
instructions, and its built-in tools — files, terminal, web and memory — act there. Agents are this
fork's; upstream lists AI-assistant features under [not planned](../not-planned.md), so the feature
stays in `Features/Agents/` plus the few lines in `AIChatCoordinator`, `AIChatDetailView`,
`AISettingsView` and `AppCore` that wire it in.

## Invariants

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
- Harnesses: `agent-test` (skills, catalog, path policy, tool sets, prompt, persistence) and
  `agent-tools-test` (the executor against a real folder: reads, writes with consent, link escapes,
  commands and timeouts, memory, skills, HTML).
