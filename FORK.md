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
| Agent Sessions | Search every past Claude Code, Codex and Tinycast session from the launcher — titles, prompts, folder and branch, a preview, and text inside transcripts on request — and resume it in its folder and terminal with one key; live sessions show their status and Jump to Agent brings a waiting one forward. Opt-in live status adds reviewed hooks to Claude Code and Codex for a HUD and a menu-bar item when an agent finishes or waits | [agent-sessions](docs/features/agent-sessions.md) |
| Alias + Space | Type an entry's alias exactly and press Space: it opens, or its first field takes the caret; `\`␣ types a space, and apps keep searching. From `sermelipharo/tinycast-space`, after `mSarheed/pipcast` | [alias actions](docs/features/alias-actions.md) |
| Change Alias / Change Shortcut | Edit an entry's alias in place, or record its global shortcut, from its ⌘K menu. From `jhasubhash/tinycast`, as reshaped in `sermelipharo/tinycast-space` | [alias actions](docs/features/alias-actions.md#change-alias--change-shortcut) |

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
- `Scripts/fork/sync-upstream.sh` does the merge: into `sync/upstream-<sha>`, upstream's
  `project.pbxproj` and runtime bundle regenerated, the string catalog merged key by key, an
  `Upstream-Sync:` trailer, then the build, harness, lint and purity gates and a summary of what
  upstream changed. Other conflicts stop it for `--continue`. Upstream force-pushes `main` now and
  then; the script re-anchors on commits it can prove are already merged and otherwise stops with a
  `git range-diff` to read. Details: [fork tooling](docs/fork-tooling.md#scriptsforksync-upstreamsh).
- **A sync branch lands by fast-forward or a merge commit, never squash or rebase**: either drops
  upstream's ancestry, and the next sync replays everything.
- Upstream's five workflows must be disabled before Actions is ever enabled on the fork (one `gh`
  loop, in [fork tooling](docs/fork-tooling.md#upstream-workflows-on-the-fork)). A nightly sync Action
  with one rolling PR is proposed there, not active; it needs a `FORK_SYNC_TOKEN` fine-grained token
  (Contents, Pull requests and Workflows read-write) with a one-year expiry, to be noted here. Only
  its publish job, which runs no repository code, ever holds that token.
- Every fork change keeps upstream's bar: harnesses, `./Scripts/lint.sh`, eight languages, docs in the
  same commit. Two harnesses fail on a clean upstream checkout too and are not fork regressions:
  `form-input-test` (display-bound) and, occasionally under load, `icon-cache-test`.

## Installing the fork

`Scripts/fork/install.sh` builds the fork in Release for this Mac, signs it with the keychain's one
`Apple Development` identity, quits the installed app gracefully, swaps the new bundle in by rename and
relaunches it. About shows the `git describe` version and the commit count (a fresh clone needs
`git fetch upstream --tags` first). Details and the manual sweep are in
[fork tooling](docs/fork-tooling.md#scriptsforkinstallsh).

- `--self-check` resolves the identity, version and paths and builds nothing; `--self-test` rehearses
  an install, a rollback and a start from Tinycast with a stubbed build in `$TMPDIR`; `--rollback` puts
  back the copy the last install replaced; `--no-launch` and `--force-quit` do what they say.
- It refuses to replace upstream's same-named `Tinycast.app`, and to install a build whose code
  requirement differs from the installed one: that would cost every privacy grant.
  `--accept-new-identity` goes ahead and prints the `tccutil reset` lines; it never runs them itself.
- Started from a Tinycast agent or command, it moves to a session of its own before it builds and
  logs to `build/fork/install.log`: an agent's command watchdog and Tinycast's quit both end the
  process group that started it.
- If macOS App Management blocks the swap, the script names the setting and leaves the old app in place.
- The Accessibility grant survives a reinstall. A capture refused while other apps capture fine is that
  one app's process refusing: quit and reopen the app you captured before toggling the grant.

## Roadmap

Sizes are focused working days. Waves are ordered by leverage, not by size.

### Wave 0 — fork foundation

- **Release script — shipped** as `Scripts/fork/install.sh` (see [Installing the fork](#installing-the-fork)).
- **Upstream sync — shipped** as `Scripts/fork/sync-upstream.sh`. The scheduled Action that keeps one
  rolling PR stays a [proposal](docs/fork-tooling.md#proposed-a-nightly-sync-action-not-active) until
  the script has done three to five syncs by hand.
- **Ports from other forks — shipped** (all AGPL, credited): alias + Space from
  `sermelipharo/tinycast-space`, Change Alias / Change Shortcut from ⌘K from `jhasubhash/tinycast`,
  and the same `sermelipharo/tinycast-space` extension-runtime fixes for Google sign-in and undici
  (see above). Confetti (`raycast://confetti`) was left out.

### Wave 1 — agent-native core

1. **ACP agents — shipped** (see above). Next on it: render diffs and command output inside tool
   rows, expose the agent's slash commands (`available_commands_update`) in the composer, a launcher
   row and hotkey per agent, and Tinycast's own `fs/*` / `terminal/*` so edits can show in an editor.
2. **Agent Sessions hub — shipped** (see above). Live status uses Codex hooks rather than `notify`,
   which Computer Use already holds. Next on it: Gemini CLI and OpenCode histories as sources, one
   merged "Agents" menu-bar item with background agents (item 5), `claude://code/continue` for Claude
   app sessions once the route is confirmed, and `CLAUDE_CONFIG_DIR` / `CODEX_HOME` overrides.
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
the forks named above; anything ported from them is credited in its commit.

- [sermelipharo/tinycast-space](https://github.com/sermelipharo/tinycast-space): alias + Space
  ([691c43ef](https://github.com/sermelipharo/tinycast-space/commit/691c43efe07e12ca87f4601ee4257a6631505bf1))
  and the reshaped ⌘K alias and shortcut editing
  ([f29cad1b](https://github.com/sermelipharo/tinycast-space/commit/f29cad1bf3318af9692566d5ee9ce45bca589170)),
  and the extension-runtime fixes for Google sign-in and undici (its patches 0004, 0008 and 0009).
- [jhasubhash/tinycast](https://github.com/jhasubhash/tinycast): inline alias and shortcut editing in
  the ⌘K panel
  ([f509d005](https://github.com/jhasubhash/tinycast/commit/f509d005518818e70d9c559017bd932a62899956)),
  and the first `sync-upstream.sh` this fork's sync script learned from.
- [mSarheed/pipcast](https://github.com/mSarheed/pipcast): the alias + Space idea
  ([4141ac68](https://github.com/mSarheed/pipcast/commit/4141ac680e)).
