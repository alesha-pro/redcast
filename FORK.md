# alesha-pro/tinycast — the agent-native fork

An unofficial fork of [Tinycast](https://github.com/abue-ammar/tinycast) by Abue Ammar. Everything that
makes Tinycast fast, native and small is upstream's work; this fork adds what upstream has chosen not to
build — screen-aware AI, agents that live in a folder, and a launcher that works *with* the coding agents
you already run. Upstream's reasons are on record in [not planned](docs/not-planned.md) (#1151, #1550):
this fork exists for exactly those features, and keeps everything else as close to upstream as it can.

**Positioning.** Spotlight in macOS 26 now covers a launcher's basics — app actions, quick keys,
clipboard history. Raycast is moving to agents and skills behind a subscription. The space left is a
native, local-first launcher that is the control centre for *your* agents: Codex, Claude Code, Gemini,
OpenCode, Goose, Hermes, local models — on the subscriptions and machines you already have.

## Shipped in this fork

| Feature | What it does | Docs |
| --- | --- | --- |
| Quick Action placeholders | `{clipboard}`, `{date}`, `{argument name="…" options="…"}` in custom AI actions; arguments asked in the launcher | [quick-actions](docs/features/quick-actions.md#placeholders) |
| Continue in AI Chat | ⌘J turns a Quick Action result into a chat that refines it | [quick-actions](docs/features/quick-actions.md#the-panel) |
| Screen Awareness | Double-tap right ⌘: the window in front — title, URL, selection, focused field, readable text, screenshot — attached to AI Chat | [screen-awareness](docs/features/screen-awareness.md) |
| Agents | A chat that lives in a folder: its `AGENTS.md`, project and global `.agents/skills`, notes, and built-in tools (files, terminal, web, memory) on any tool-calling API model, every change and command asked first unless the agent's permissions say otherwise | [agents](docs/features/agents.md) |
| Native agent harness | Agent chats on API models run the fork's own tool loop: tool families plug in as providers with a risk each, every change, command and fetch passes one consent policy, read-only calls in a round run in parallel, a long turn elides old results instead of stopping, and Stop ends a running command and voids a late Allow | [agents](docs/features/agents.md#adding-a-tool-family) |
| Web search | A `web_search` tool for agents and every API model: Exa, Parallel and DuckDuckGo with no key, then your SearXNG, Brave or Tavily, tried in order | [web-search](docs/features/web-search.md) |
| Notes ↔ AI | Attach Note… in the composer or `@note` picks a note to send with the next message; agents with the Notes tools search and read your notes and add reports to them, every addition asked first whatever the agent's other rules say | [notes-ai](docs/features/notes-ai.md) |
| Background and scheduled agents | `@agent do X` in root search runs a turn with no window: a transient menu-bar item shows it working, a HUD (and an opt-in banner) says when it ended, and the result is a chat. Schedules run an agent daily, on working days or every few hours while Tinycast is open, with one sleeping task, a catch-up rule and an optional note. Unattended requests ask only someone at the Mac, with Return on Don't Allow | [background-agents](docs/features/background-agents.md) |
| ACP agents | An agent can run as its own CLI over the Agent Client Protocol — Claude Code, Codex, Gemini CLI, OpenCode, Goose, Hermes or any command — on your own logins, with its permission requests, tool rows, plans and modes in AI Chat, and sessions that survive a relaunch | [agents](docs/features/agents.md#acp-agents) |
| Voice AI | Cloud dictation through Gemini Flash on your own OpenRouter, Gemini or OpenAI-compatible connection, and Ask by Voice: speak a question about the window in front, get the answer beside it or typed into the field. Audio goes only to the connection you approved | [voice-ai](docs/features/voice-ai.md) |
| Raycast AI for extensions | `AI.ask`, `useAI` and `canAccess(AI)` answered by your own model, off until you allow it and asked once per extension (a dismissed question asks again); only in a command you open, never in a menu-bar command, a background refresh or anything one launches | [extension-ai](docs/features/extension-ai.md) |
| Extension runtime fixes | Google sign-in without a client secret (`querystring` coerces like Node), and extensions that bundle undici (`buffer.Blob`/`File`, undici's requests sent through the `fetch` bridge); ported from sermelipharo/tinycast-space | [extensions](docs/features/extensions.md) |
| AI usage | Settings → AI → Usage: tokens and cost per model or ACP agent for a day, week or month, read from the chats on this Mac; an OpenRouter key's UTC spend and limit on Check Balance. An ACP reply counts what its session's running total rose; a tool-loop reply now costs its whole turn, and OpenAI's own API records tokens | [usage-dashboard](docs/features/usage-dashboard.md) |

Builds of this fork use the bundle id `com.tinycast.app.fork`: they never update themselves from
upstream's feed, and they keep their settings apart from an installed upstream Tinycast.

## Living with upstream

- `origin` is this fork, `upstream` is abue-ammar/tinycast. Upstream lands almost daily.
- Fork features live in their own `Features/<Name>/` folders and touch shared files in as few lines as
  possible, so `git fetch upstream && git merge upstream/main` stays a mechanical merge.
- Agent chats run the fork's `AgentLoopProvider`; `agent-loop-test` runs it and upstream's
  `AIToolLoopProvider` on the same script, so a merge that changes upstream's loop fails a harness
  until the fork follows.
- `LauncherScreen.init`'s claim hunk (`@agent` rows answering alone) is the fork's likeliest merge
  conflict: it is one contiguous block, so resolve it there and keep upstream's comments above their
  lines.
- `Tinycast.xcodeproj` is generated: after a merge, resolve `project.yml` and run `xcodegen generate`
  rather than hand-merging `project.pbxproj`. `Localizable.xcstrings` entries are inserted by hand in
  catalog order (a local `sync-strings.sh` reorders hundreds of unrelated entries).
- Every fork change keeps upstream's bar: harnesses, `./Scripts/lint.sh`, eight languages, docs in the
  same commit. Two harnesses fail on a clean upstream checkout too and are not fork regressions:
  `form-input-test` (display-bound) and, occasionally under load, `icon-cache-test`.

## Roadmap

Sizes are focused working days. Waves are ordered by leverage, not by size.

### Wave 0 — fork foundation

- **Release script.** One command builds the fork in Release with its bundle id and a stable signing
  identity, installs it and relaunches it, versioned from `git describe`.
- **Upstream sync.** A script (and later a scheduled Action that opens a PR) that merges upstream,
  regenerates the project, runs the harnesses and lists what upstream changed.
- **Ports from other forks** (all AGPL, credited): alias + Space from `sermelipharo/tinycast-space`;
  Change Alias / Change Shortcut from ⌘K from `jhasubhash/tinycast`. The same fork's extension-runtime
  fixes for Google sign-in and undici have shipped (see above).

### Wave 1 — agent-native core

1. **ACP agents — shipped** (see above). Next on it: render diffs and command output inside tool
   rows, expose the agent's slash commands (`available_commands_update`) in the composer, a launcher
   row and hotkey per agent, and Tinycast's own `fs/*` / `terminal/*` so edits can show in an editor.
2. **Agent Sessions hub.** Search every past Codex, Claude Code and Tinycast session from the launcher
   (titles, first prompts, full text), preview it, and resume it in its folder and terminal. A live
   list of running agents fed by Claude Code hooks and Codex `notify`: a HUD and menu-bar badge when an
   agent finishes or waits for approval, one key to jump to it. *3–4 days.* The menu-bar badge
   reuses the background agents' `AgentRunsStatusItem`.
3. **Voice to AI — partly shipped** (see Voice AI above): cloud dictation, and hold-to-talk with the
   screen attached as Ask by Voice. Next on it: dictation *modes* that pass the transcript through a
   prompt before it is typed (speak Russian, get an English post; per-app tone), a *voice command*
   over the selection ("make this shorter"), hold-to-talk on a single modifier, and asking an agent
   by voice. Upstream declined voice control (#1550). *2 days.*
4. **Tinycast as an MCP server.** A bundled stdio helper that lets Claude Code, Codex and any MCP
   client use the launcher's hands: clipboard history, the frontmost window's context, notes,
   snippets, calendar, opening apps and URLs, a native `notify`, and `ask_user` — a Tinycast dialog an
   agent can raise while you are in another app. *3–4 days.*

### Wave 2 — context and power

5. ~~**Background and scheduled agents.**~~ Shipped (see above). Next on it: a per-agent launcher
   row and hotkey, the unattended briefing for ACP agents, and a spend cap for schedules.
6. **Screen Awareness+ and Capture.** Area and full-screen capture, Vision OCR when an app exposes no
   Accessibility text (canvas apps, games), Finder's selected files, a `{screen}` placeholder for
   Quick Actions ("reply to this" in one key), a `screen_context` agent tool, and a searchable
   screenshot library (upstream #1211 declined; `dnw3` and `fminkowski` forks built capture). *3–4 days.*
7. **Web search — shipped** (see above). Next: `read_page` for plain chats, and the same tool for
   Codex and Claude through Tinycast's MCP server (item 4).
8. **Raycast AI for extensions — shipped** (see above). Next on it: honour the requested `AI.Model`
   (an Anthropic id to an Anthropic connection), `creativity` as temperature where a route takes one,
   `AI.experimental_decide`, extension model providers, and AI from a menu-bar item's own action, where
   the click is the gesture (the menu-bar lane has no AI host today).
9. **Model arena.** One prompt to two to four models side by side, streaming in columns; keep the best
   answer and continue with that model. *3 days.*

### Wave 3 — daily delights

10. **AI paste and AI snippets.** "Paste transformed…" on any clipboard item (translate, tidy, as a
    list, as JSON), and an `{ai prompt="…"}` snippet placeholder that expands through a model.
11. **Leader-key menus.** Vim-style key sequences and nested keyboard menus of actions (`mzarabi`'s
    leader mode, `zachthinks/ZLaunch`'s LaunchDeck).
12. **Developer utilities.** Kill by port, JSON / Base64 / URL / hash / UUID tools, colour picker,
    Caffeinate, timers and Pomodoro (`nikteg`, `Sai1boats` forks), `#` to run a shell line from root
    search.
13. **Notes ↔ AI — shipped** (see above): Attach Note… and `@note` in AI Chat, the
    `notes_search` / `notes_read` / `notes_append` tools for agents on the native harness, and a
    schedule's Append the answer to a note (item 5). Next on it: an Attach Note… item in Quick AI's ⌘K
    menu, and the notes tools in the MCP server (item 4) for ACP agents.
14. **Usage dashboard — shipped** (see above). Next on it: a ledger so Quick Actions count, an
    optional OpenRouter management key for the account balance, a trend strip, and a launcher command
    that opens the section.
15. **App-aware snippets.** Offer the snippets written for the app in front first (`NikAtNight`).
16. **Moonshot — meeting copilot.** On-device transcription of microphone and system audio into a
    running transcript, summarised into Notes when the meeting ends.

## Credits

Upstream: [abue-ammar/tinycast](https://github.com/abue-ammar/tinycast), AGPL-3.0. Ideas surveyed from
the forks named above; anything ported from them is credited in its commit. The extension-runtime fixes
come from [sermelipharo/tinycast-space](https://github.com/sermelipharo/tinycast-space) (patches 0004,
0008 and 0009).
