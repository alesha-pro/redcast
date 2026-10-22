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
| Agents | A chat that lives in a folder: its `AGENTS.md`, project and global `.agents/skills`, notes, and built-in tools (files, terminal, web, memory) on any tool-calling API model, every change and command asked first | [agents](docs/features/agents.md) |
| ACP agents | An agent can run as its own CLI over the Agent Client Protocol — Claude Code, Codex, Gemini CLI, OpenCode, Goose, Hermes or any command — on your own logins, with its permission requests, tool rows, plans and modes in AI Chat, and sessions that survive a relaunch | [agents](docs/features/agents.md#acp-agents) |

Builds of this fork use the bundle id `com.tinycast.app.fork`: they never update themselves from
upstream's feed, and they keep their settings apart from an installed upstream Tinycast.

## Living with upstream

- `origin` is this fork, `upstream` is abue-ammar/tinycast. Upstream lands almost daily.
- Fork features live in their own `Features/<Name>/` folders and touch shared files in as few lines as
  possible, so `git fetch upstream && git merge upstream/main` stays a mechanical merge.
- `Tinycast.xcodeproj` is generated: after a merge, resolve `project.yml` and run `xcodegen generate`
  rather than hand-merging `project.pbxproj`. `Localizable.xcstrings` entries are inserted by hand in
  catalog order (a local `sync-strings.sh` reorders hundreds of unrelated entries).
- Every fork change keeps upstream's bar: harnesses, `./Scripts/lint.sh`, eight languages, docs in the
  same commit. Two harnesses fail on a clean upstream checkout too and are not fork regressions:
  `form-input-test` (display-bound) and, occasionally under load, `icon-cache-test`.

## Installing the fork

`Scripts/fork/install.sh` builds the fork in Release for this Mac, signs it with the keychain's one
`Apple Development` identity, quits the installed app gracefully, swaps the new bundle in by rename and
relaunches it. About shows the `git describe` version and the commit count (a fresh clone needs
`git fetch upstream --tags` first). Details and the manual sweep are in
[fork tooling](docs/fork-tooling.md#scriptsforkinstallsh).

- `--self-check` resolves the identity, version and paths and builds nothing; `--rollback` puts back
  the copy the last install replaced; `--no-launch` and `--force-quit` do what they say.
- It refuses to replace upstream's same-named `Tinycast.app`, and to install a build whose code
  requirement differs from the installed one: that would cost every privacy grant.
  `--accept-new-identity` goes ahead and prints the `tccutil reset` lines; it never runs them itself.
- Started from a Tinycast agent or command, it finishes in a session of its own
  (`build/fork/install.log`), because quitting Tinycast reaps its agents' process trees.
- If macOS App Management blocks the swap, the script names the setting and leaves the old app in place.
- The Accessibility grant survives a reinstall. A capture refused while other apps capture fine is that
  one app's process refusing: quit and reopen the app you captured before toggling the grant.

## Roadmap

Sizes are focused working days. Waves are ordered by leverage, not by size.

### Wave 0 — fork foundation

- **Release script — shipped** as `Scripts/fork/install.sh` (see [Installing the fork](#installing-the-fork)).
- **Upstream sync.** A script (and later a scheduled Action that opens a PR) that merges upstream,
  regenerates the project, runs the harnesses and lists what upstream changed.
- **Ports from other forks** (all AGPL, credited): alias + Space and the extension-runtime fixes for
  Google sign-in and undici from `sermelipharo/tinycast-space`; Change Alias / Change Shortcut from ⌘K
  from `jhasubhash/tinycast`.

### Wave 1 — agent-native core

1. **ACP agents — shipped** (see above). Next on it: render diffs and command output inside tool
   rows, expose the agent's slash commands (`available_commands_update`) in the composer, a launcher
   row and hotkey per agent, and Tinycast's own `fs/*` / `terminal/*` so edits can show in an editor.
2. **Agent Sessions hub.** Search every past Codex, Claude Code and Tinycast session from the launcher
   (titles, first prompts, full text), preview it, and resume it in its folder and terminal. A live
   list of running agents fed by Claude Code hooks and Codex `notify`: a HUD and menu-bar badge when an
   agent finishes or waits for approval, one key to jump to it. *3–4 days.*
3. **Voice to AI.** On top of the existing on-device dictation: dictation *modes* that pass the
   transcript through a prompt before it is typed (speak Russian, get an English post; per-app tone),
   a *voice command* over the selection ("make this shorter"), and hold-to-talk into AI Chat or an
   agent with the screen attached. Upstream declined voice control (#1550). *3 days.*
4. **Tinycast as an MCP server.** A bundled stdio helper that lets Claude Code, Codex and any MCP
   client use the launcher's hands: clipboard history, the frontmost window's context, notes,
   snippets, calendar, opening apps and URLs, a native `notify`, and `ask_user` — a Tinycast dialog an
   agent can raise while you are in another app. *3–4 days.*

### Wave 2 — context and power

5. **Background and scheduled agents.** `@agent do X` from the launcher runs without a window; a
   menu-bar badge shows progress, a notification brings back the result. Schedules for recurring jobs
   (a morning digest, a nightly report into Notes). *3–4 days.*
6. **Screen Awareness+ and Capture.** Area and full-screen capture, Vision OCR when an app exposes no
   Accessibility text (canvas apps, games), Finder's selected files, a `{screen}` placeholder for
   Quick Actions ("reply to this" in one key), a `screen_context` agent tool, and a searchable
   screenshot library (upstream #1211 declined; `dnw3` and `fminkowski` forks built capture). *3–4 days.*
7. **Web search and page reading on every route.** A `web_search` tool (Brave, Exa, Tavily or a
   self-hosted SearXNG) and `read_page` for every chat and agent, not only Codex and OpenRouter
   (upstream #1610). *1–2 days.*
8. **Raycast AI for extensions.** Implement `AI.ask` and `useAI` in the extension runtime on top of
   Tinycast's providers; today the runtime rejects the whole `AI` namespace, so every AI-powered
   Raycast extension fails. *2–3 days.*
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
13. **Notes ↔ AI.** `@note` as chat context; agents and scheduled jobs write their reports into Notes.
14. **Usage dashboard.** Tokens and spend per model and per day from chat history and provider APIs.
15. **App-aware snippets.** Offer the snippets written for the app in front first (`NikAtNight`).
16. **Moonshot — meeting copilot.** On-device transcription of microphone and system audio into a
    running transcript, summarised into Notes when the meeting ends.

## Credits

Upstream: [abue-ammar/tinycast](https://github.com/abue-ammar/tinycast), AGPL-3.0. Ideas surveyed from
the forks named above; anything ported from them is credited in its commit.
