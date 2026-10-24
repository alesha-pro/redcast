# Redcast — the agent-native fork of Tinycast

[alesha-pro/redcast](https://github.com/alesha-pro/redcast) is an unofficial fork of
[Tinycast](https://github.com/abue-ammar/tinycast) by Abue Ammar. Everything that makes Tinycast fast,
native and small is upstream's work; this fork adds what upstream has chosen not to build — screen-aware
AI, agents that live in a folder, and a launcher that works *with* the coding agents you already run.
Upstream's reasons are on record in [not planned](docs/not-planned.md) (#1151, #1550): this fork exists
for exactly those features, and keeps everything else as close to upstream as it can.

**Redcast is the name you see, and only that.** The installed app is `Redcast.app` with a
`Redcast Dictation` helper, and its menus, windows, onboarding and privacy prompts say Redcast in
English and all eight translations. About still says it is based on Tinycast by Abue Ammar, and
Support names Tinycast, since its checkout funds upstream's author. Underneath it stays Tinycast, so upstream merges stay mechanical and an upgrade keeps everything: the
Xcode project, targets, sources and type names, the bundle id `com.tinycast.app.fork` (and with it
settings, Application Support, privacy grants and Keychain items), `.tinycast` backups, the
`tinycast://` scheme, file paths and log subsystems. The name is set at build time and in the string
catalogs, never in `project.yml` ([how](docs/fork-tooling.md#scriptsforkrebrandmjs)). Older sections
below say Tinycast where they mean the app.

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
| Agents | A chat that lives in a folder: its `AGENTS.md`, project and global `.agents/skills`, notes, and built-in tools (files, terminal, web, memory) on any tool-calling API model, every change and command asked first unless the agent's permissions say otherwise. Settings → AI → Agents → Agent for new chats starts every new AI Chat chat on one agent, ACP ones too, as if picked in the composer, which still switches it per chat; it binds with the first message, so an empty chat leaves nothing behind. `read_file` reads PDFs by pages (scans by OCR), images, Word, RTF, ODT and saved pages through a [shared document reader](docs/features/document-text.md); `search_files` finds files through Spotlight, across the home folder and iCloud Drive with full access; once a run is unattended or its chat has read the user's files, notes, screen or attachments, `web_fetch` opens only eight pages a turn among links the user gave, search results and same-site links on pages it read | [agents](docs/features/agents.md) |
| Native agent harness | Agent chats on API models run the fork's own tool loop, sized to the task: a simple question is one round with no tool or one, a task of several steps a short plan, the work, a check of the key facts and a short result. Tool families plug in as providers, each with a risk, and every change, command and fetch passes one consent policy; read-only calls in a round run four at a time. Each agent's Effort (Quick, Balanced, Thorough) sets its run's rounds, tool output, background minutes and sub-agents: near the end the model is told to wrap up, and at it hands over the result, what is done, what is not and what to do next, never an error, with one plan kept and read back for the run. Thinking models are sent their own reasoning back between tool rounds in the form each provider documents (DeepSeek, Qwen on DashScope and Qwen Cloud, Kimi, MiniMax, GLM, OpenRouter, Claude, Gemini, any other host as it came), never another model's, and a gateway that refuses the field loses only the field. Busy or rate-limited routes are waited out, an overflow sheds old results and then old history, a reply the output cap cut runs none of its calls, and cache hits are counted apart. A long turn elides old results; a long chat keeps notes on the turns it no longer sends. Opt-in Sub-agents hands read-only tasks to `delegate` copies of the agent on the same model, side by side. Opt-in Screen lets `screen_context` read the text of the window behind Tinycast, only on a turn the user sends from the chat and only after a dialog that names the app. On Anthropic's own API and on OpenRouter, Claude is asked to cache every request that will be sent again. Stop ends a running command, sub-agent, retry wait or summary and voids a late Allow. `agent-scenario-test` drives whole turns on each provider's wire. A call's row names what it was given (`run_command: <the command>`), a retry row names what failed, and every failure is logged. Return while a reply runs queues the message for after it; Send Now (⌘↵) steers a native agent at its next step, as pi and DeepSeek Harness do, and stops any other reply to send at once | [agents](docs/features/agents.md#adding-a-tool-family), [agent harness](docs/features/agent-harness.md) |
| Web search | A `web_search` tool for agents and every API model: Exa, Parallel and DuckDuckGo with no key, then your SearXNG, Brave or Tavily, tried in order; with Web search on, a plain chat can also `read_page` a page you linked or a search found. Pages read as compact Markdown with their links, long ones in parts, PDFs by pages; hidden text is dropped, and a page only its scripts would fill is said to be one, so the model reads another result | [web-search](docs/features/web-search.md) |
| Quick AI tools | Quick AI's ⌘K turns Web Search on and off, the setting the composer's + menu toggles. Settings → AI → Agents → Quick AI answers with runs Quick AI's new chats on an agent of the chat's model, with its tools, folder, instructions and permissions, its name above the chat, and ⌘K → Answer with switches it for one chat; ACP agents stay in AI Chat. Every chat is told the local time to the quarter hour, and one without an agent which tools it has (MCP ones by pointer, since `@server` picks them per message), with live facts sent through `web_search` and then `read_page`, or in one line where Web Search is turned on | [quick-ai-tools](docs/features/quick-ai-tools.md) |
| Notes ↔ AI | Attach Note… in the composer or Quick AI's ⌘K menu, or `@note`, picks a note to send with the next message; agents with the Notes tools search and read your notes and add reports to them, every addition asked first whatever the agent's other rules say | [notes-ai](docs/features/notes-ai.md) |
| Background and scheduled agents | `@agent do X` in root search asks the agent in Quick AI (↵) or, with ⌘↵, runs a turn with no window, and every agent is a launcher row of its own (Return a new chat; ⌘K Run in Background… and Edit Agent) with an optional global chord that types its `@handle`. One transient Agents menu-bar item shows background runs and Agent Sessions' live sessions together; a HUD (and an opt-in banner) says when a run ended, and the result is a chat. Schedules run an agent daily, on working days or every few hours while Tinycast is open, with one sleeping task, a catch-up rule, an optional note and an optional daily spend cap in US dollars over the costs routes report, counted even for runs cut short by a quit. Unattended requests ask only someone at the Mac, with Return on Don't Allow; native and ACP agents are both told when nobody is watching | [background-agents](docs/features/background-agents.md) |
| ACP agents | An agent can run as its own CLI over the Agent Client Protocol — Claude Code, Codex, Gemini CLI, OpenCode, Goose, Hermes or any command — on your own logins, with its permission requests, tool rows that unfold the call's diff or command output, plans and its slash commands offered in the composer in AI Chat, and sessions that survive a relaunch. The composer picks the agent's own model, reasoning effort and mode where an API chat's pickers sit, with its other options under ⋯. Each chat keeps its own picks across an idle stop or a relaunch, and the last pick is the agent's default for every new session before its first prompt, background and scheduled runs included; the editor shows that default model. An unattended run's prompt says nobody may be at the Mac | [agents](docs/features/agents.md#acp-agents) |
| Voice AI | Cloud dictation through Gemini Flash on your own OpenRouter, Gemini or OpenAI-compatible connection, on a prompt adapted from Ottex's: spoken punctuation, lists, line breaks and corrections in Russian and English, Languages I speak, your words to spell, and the app in front (its name and window title, or with a screenshot) as a hint, never an instruction, with dictation modes (Translate to English, Polish, As a message or your own) that rewrite the transcript per app. The capsule names the mode, and Tab or ⇧Tab switches it, even while the shortcut is held. Ask by Voice: speak a question about the window in front and get the answer beside it or typed into the field. Or hand the request to an agent as a background task with the window attached; that run is saved as its chat. Edit Selection by Voice: say how to change the selected text, and it is replaced in place if the selection hasn't moved. Both commands can be held on a key combination or a single modifier such as right Option. Audio goes only to the connection you approved and is saved only when a dictation fails, for Dictation History's Retry | [voice-ai](docs/features/voice-ai.md) |
| Dictation History | Every finished dictation, on-device or in the cloud, and, once switched on, every Ask by Voice question and voice edit, kept as text — what was typed, the transcript a mode rewrote, the mode, engine and model, the app, the time and the length — in a Dictation History launcher command (found by "transcripts" and "voice history" too): search over the text, a preview, ↵ pastes it where the caret was, ⌘C copies (text selected in the preview copies as text), ⌘K copies the raw transcript or an Ask's request, or deletes. A dictation whose transcription fails, on device or in the cloud, is listed as failed with the error and keeps its recording (only failed ones, at most 20, 7 days and 100 MB, never backed up): ↵ or ⌘K's Retry transcribes it again with the current model and Retry with… on any audio-capable connection and model the voice settings offer or an installed on-device model, another connection asked first; the text becomes the entry's, typed nowhere until ↵, and the recording goes. Settings → Dictation → History keeps it Off, 1, 7, 30 (default) or 90 days or Forever, trims it on write, takes Ask by Voice and voice edits only behind a switch that is off by default, keeps failed recordings behind one that is on, clears it after asking and binds the command's shortcut; nothing is read at launch, and it travels in no backup | [dictation-history](docs/features/dictation-history.md) |
| Raycast AI for extensions | `AI.ask`, `useAI`, `AI.experimental_decide` and `canAccess(AI)` answered by your own model, off until you allow it and asked once per extension (a dismissed question asks again); `creativity` becomes a temperature where the route takes one, and an opt-in switch lets a model an extension names (Claude, GPT, Gemini…) reach that vendor's closest model among your API connections — read from the name's host, so Groq's or Vercel's hosted models keep yours; only in a command you open or from a menu-bar item you click, never in a menu's render, a background refresh or anything one launches | [extension-ai](docs/features/extension-ai.md) |
| Extension runtime fixes | Google sign-in without a client secret (`querystring` coerces like Node), and extensions that bundle undici (`buffer.Blob`/`File`, undici's requests sent through the `fetch` bridge); ported from sermelipharo/tinycast-space | [extensions](docs/features/extensions.md) |
| AI usage | Settings → AI → Usage: tokens and cost per model or ACP agent for a day, week or month, read from the chats on this Mac and from a small usage log of the replies no chat keeps (Quick Actions, Ask by Voice and dictation, extension AI, chat titles; numbers only, 400 days, never backed up), with a strip of per-hour or per-day bars; an OpenRouter key's UTC spend and limit on Check Balance, and the account's credits with an optional management key sent only to OpenRouter's /credits; the "AI Usage" command opens the section. An ACP reply counts what its session's running total rose; a tool-loop reply, a chat's or an agent's, costs its whole turn, and OpenAI's own API records tokens | [usage-dashboard](docs/features/usage-dashboard.md) |
| Agent Sessions | Search every past Claude Code, Codex, Gemini CLI, OpenCode and Tinycast session from the launcher — titles, prompts, folder and branch, a preview, and text inside transcripts on request — and resume it in its folder and terminal with one key; ⌘O opens a Claude app session in Claude itself (`claude://code/continue`). Claude Code and Codex folders moved with `CLAUDE_CONFIG_DIR` / `CODEX_HOME` are named in Settings (locked while live status is on). Live sessions show their status and Jump to Agent brings a waiting one forward. Opt-in live status adds reviewed hooks to Claude Code and Codex for a HUD and rows in the one Agents menu-bar item when an agent finishes or waits | [agent-sessions](docs/features/agent-sessions.md) |
| Raycast look | Raycast's palette and red: built-in commands, system actions, Settings panes and ⌘K glyphs wear Raycast's colours by family (AI red, clipboard and snippets orange, notes and calendar amber, system green, files and voice blue, windows and quicklinks purple), on Raycast-style tiles with white glyphs; apps, files and extensions keep their own icons, and an extension's `raycast-*` colours are Raycast's exact values. Raycast red is the accent (switches, checkboxes, default and Send buttons, focus, links) and the selected row's wash; a dialog's primary button is solid red so it never passes for Delete, section headers are bolder, and progress stays blue. Every agent wears a colour of its own, derived from its id or picked from swatches in its editor, on its launcher tile, the composer's picker, the head of its chats, the Agents menu-bar rows, Settings and Usage. General › Appearance › Colorful icons turns the tiles and glyphs back to upstream's; the accent stays | [ui](docs/ui.md#colour-the-raycast-palette-fork) |
| Redcast icon | The command key whose top-right loop burns into an ember, white on a vermilion (#F23D32) Liquid Glass tile, and the same mark as the menu-bar template. `Scripts/fork/install.sh` picks `Tinycast/redcast.icon` with `ASSETCATALOG_COMPILER_APPICON_NAME`, so upstream's icon files stay untouched. `docs/brand/` holds the icon and the mark as SVG, in the shipped vermilion, and the README's PNG renders; the working sources and every rejected concept stay outside the repo | [fork tooling](docs/fork-tooling.md#scriptsforkinstallsh) |
| Alias + Space | Type an entry's alias exactly and press Space: it opens, or its first field takes the caret; `\`␣ types a space, and apps keep searching. From `sermelipharo/tinycast-space`, after `mSarheed/pipcast` | [alias actions](docs/features/alias-actions.md) |
| Change Alias / Change Shortcut | Edit an entry's alias in place, or record its global shortcut, from its ⌘K menu. From `jhasubhash/tinycast`, as reshaped in `sermelipharo/tinycast-space` | [alias actions](docs/features/alias-actions.md#change-alias--change-shortcut) |

Builds of this fork use the bundle id `com.tinycast.app.fork`: they never update themselves from
upstream's feed, and they keep their settings apart from an installed upstream Tinycast, which can sit
next to Redcast in `/Applications`.

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
  catalog order (a local `sync-strings.sh` reorders hundreds of unrelated entries). A short key whose
  meaning depends on where it appears, such as `at`, gets a catalog `comment` for translators.
- New UI text is written with Tinycast in its key, as upstream would, and translated the same way;
  `node Scripts/fork/rebrand.mjs` then gives it an English value and translations that say Redcast,
  and `--check` fails while any key still needs that. Text about upstream itself (About's credit,
  its Discord row, and Support, whose checkout funds upstream's author) is listed in the script and
  keeps the name.
- `Scripts/fork/sync-upstream.sh` does the merge: into `sync/upstream-<sha>`, upstream's
  `project.pbxproj` and runtime bundle regenerated, both string catalogs merged key by key and
  rebranded, the fork's own `README.md`, `FUNDING.yml` and issue contact links kept whatever upstream
  did to its copies, an `Upstream-Sync:` trailer, then the build, harness, lint and purity gates and
  a summary of what upstream changed. Other conflicts stop it for `--continue`. Upstream force-pushes
  `main` now and then; the script re-anchors on commits it can prove are already merged and otherwise
  stops with a `git range-diff` to read.
  Details: [fork tooling](docs/fork-tooling.md#scriptsforksync-upstreamsh).
- **A sync branch lands by fast-forward or a merge commit, never squash or rebase**: either drops
  upstream's ancestry, and the next sync replays everything.
- Upstream's five workflows must be disabled before Actions is ever enabled on the fork (one `gh`
  loop, in [fork tooling](docs/fork-tooling.md#upstream-workflows-on-the-fork)). A nightly sync Action
  with one rolling PR is proposed there, not active; it needs a `FORK_SYNC_TOKEN` fine-grained token
  (Contents, Pull requests and Workflows read-write) with a one-year expiry, to be noted here. Only
  its publish job, which runs no repository code, ever holds that token.
- Every fork change keeps upstream's bar: harnesses, `./Scripts/lint.sh`, eight languages, docs in the
  same commit. Its panels and rows fit in all eight: a choice in an editor is a menu, radio buttons or
  a `SteadySegmentedPicker`, never a plain segmented `Picker`, whose equal segments once clipped the
  schedule editor in French and Russian. Two harnesses fail on a clean upstream checkout too and are
  not fork regressions: `form-input-test` (display-bound) and, occasionally under load,
  `icon-cache-test`.

## Installing the fork

`Scripts/fork/install.sh` builds the fork in Release for this Mac as `/Applications/Redcast.app`, signs
it with the keychain's one `Apple Development` identity, quits the installed app gracefully, swaps the
new bundle in by rename and relaunches it. About shows the `git describe` version and the commit count
(a fresh clone needs `git fetch upstream --tags` first). Details and the manual sweep are in
[fork tooling](docs/fork-tooling.md#scriptsforkinstallsh).

- **From Tinycast.app to Redcast.app.** When `/Applications/Tinycast.app` is this fork (its bundle id,
  and the same code requirement as the new build), the first install quits it, installs
  `Redcast.app`, moves the old copy into the rollback slot and unregisters it from LaunchServices;
  `--rollback` puts `Tinycast.app` back, and a second `--rollback` redoes the move. Privacy grants are
  keyed by bundle id and code requirement, so they carry over. Launch at login may still name the old
  path: if Redcast does not open at login, switch it off and on in Settings › General.
  Upstream's own `Tinycast.app` (another bundle id) is never touched; the script only says both are
  installed. A fork `Tinycast.app` beside `Redcast.app`, which an un-updated worktree's `install.sh`
  would put back, is refused: merge `main` into a worktree before installing from it.

- `--self-check` resolves the identity, version and paths, prints the migration it would do, and
  builds nothing; `--self-test` rehearses an install, a rollback, the migration and its rollback, and
  a start from the app, with a stubbed build in `$TMPDIR`;
  `--rollback` puts back the copy the last install replaced; `--no-launch` and `--force-quit` do
  what they say. A build rolled back to reads this one's files; continuing an ACP chat there drops
  the saved diffs and output of the reply it rewrites ([why](docs/features/agents.md#invariants)).
- It refuses to replace a bundle that is not the fork's, and to install a build whose code
  requirement differs from the installed one: that would cost every privacy grant.
  `--accept-new-identity` goes ahead and prints the `tccutil reset` lines; it never runs them itself.
- Started from a Tinycast agent or command, it moves to a session of its own before it builds and
  logs to `build/fork/install.log`: an agent's command watchdog and Tinycast's quit both end the
  process group that started it.
- If macOS App Management blocks the swap, the script names the setting and leaves the old app in place.
- The Accessibility grant survives a reinstall. A capture refused while other apps capture fine is that
  one app's process refusing: quit and reopen the app you captured before toggling the grant.

## Roadmap

Sizes are focused working days. Waves are ordered by leverage, not by size. Every item carries the
owner's decision: **shipped**, **undecided**, **paused**, **not now** or **declined**; a shipped
item's "next on it" list is agreed work, and what follows its "Undecided:" waits for the owner.
Declined items stay listed so the numbers other docs cite keep their meaning.

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

- **Native agent harness — shipped** (see above), including cross-turn compaction, `update_plan`, a
  read-only `delegate` sub-agent, `screen_context` (chat turns only, never background runs or
  sub-agents) and prompt-cache markers for Claude on Anthropic's API and OpenRouter, then the balanced
  general agent from the harness research (its plan's wave 0 and wave 1's budget, retries, reading,
  plan and prompt): interleaved thinking on every major provider, Effort and run budgets with an
  enforced hand-over, retries and an overflow ladder, the output cap, one plan per run, concurrent
  sub-agents, a cache-stable prompt, and documents, Markdown pages and Spotlight for reading. Next on
  it, in order of value for a balanced agent (sizes are the research's estimates):
  - **Run journal and Continue**: every round written to SQLite as it ends, a failed or stopped run
    resumed from it, a call with no result told its outcome is unknown. *3 days.*
  - **Pages that need JavaScript**: `web_fetch` renders such a page in a WebKit view that lives only
    for the call. *1.5 days.*
  - **Verification and delivery**: the claims a result rests on checked against their sources
    before it is done, files handed over and exported to PDF, DOCX or RTF. *4.5 days.*
  - **Steering and ask-with-timeout**: a message sent mid-run joins the next round; one question to
    the user waits a while, then the run goes on with the assumption it names. *2.5 days.*
  - **Unattended safety**: `run_command` in a Seatbelt sandbox that writes only to the run's
    folder, so a background run may run it unasked, and guards on what a run nobody watches does.
    *5 days.*
  - **The run's workspace**: a folder per run with findings and their sources, and large results
    spilled to files, their head and tail in context. *2 days.*
  - **In-run compaction**: a long run summarises its older rounds instead of only eliding them.
    *3 days.*
  - **Mac actions**: calendar, reminders, Shortcuts, opening files and apps, the clipboard, each
    under consent and behind a plan the user approved. *6 days.*
  - **Reminders and "only new"**: follow-ups the user confirms, and schedules that report only what
    changed since their last run. *2.5 days.*
  - **Search polish**: `web_search` with up to four queries merged, private addresses refused
    before connecting, an honest User-Agent and Accept-Language. *1 day.*
  - **Fresh and fork researchers**: parallel research tasks, fresh or forked from the run, with a
    result schema. *2.5 days.*
  - **Goal mode**: rounds toward a goal with criteria until it is met, blocked or out of budget.
    *3 days.*

  Undecided: plain chats on the same loop (so `web_search` and compaction reach them with no
  upstream edit), a sub-agent's tokens counted in Usage, and a Personal data row in an agent's
  Permissions. The row needs Notes reads to ask too, so that Ask Each Chat means the same thing for
  both.

1. **ACP agents — shipped** (see above). Diffs and command output unfold inside tool rows, the
   agent's slash commands are offered in the composer, and each agent has a launcher row and hotkey
   (with item 5). The agent's model, reasoning and other Session Config Options are picked in the
   composer, kept per chat and remembered on the agent as the next chat's default, with the older
   `models` / `modes` shapes as the fallback.
   Tinycast's own `fs/*` / `terminal/*` were evaluated and left out: no preset adapter calls them,
   and a client terminal would run agent commands outside their own sandboxes
   ([why](docs/features/agents.md#tinycasts-own-fs-and-terminal)). Next on it: nothing agreed.
   Undecided: streaming command output into a row (`_meta.terminal_output`), and images inside tool
   content.
2. **Agent Sessions hub — shipped** (see above). Live status uses Codex hooks rather than `notify`,
   which Computer Use already holds. Gemini CLI and OpenCode histories, `claude://code/continue` for
   Claude app sessions, the `CLAUDE_CONFIG_DIR` / `CODEX_HOME` folders and one Agents menu-bar item
   shared with background agents (item 5) have shipped. Next on it: nothing agreed. Undecided: live
   status for Gemini CLI (its hooks) and OpenCode (a plugin); folder fields for `GEMINI_CLI_HOME` and
   `OPENCODE_DB`; and OpenCode's `session_v2` schema once it is released.
3. **Voice to AI — shipped** (see Voice AI above): cloud dictation with dictation modes, Ask by
   Voice with hold-to-talk on a single modifier and an agent as an optional target, Edit Selection
   by Voice, Dictation History, a launcher command over every finished transcript, and a dictation
   prompt adapted from Ottex's, told the languages you speak and the app in front. Next on it:
   nothing agreed. Undecided: measuring modes' one-request reliability per model, which may tune
   `VoiceRoutePolicy.rewritesWhileTranscribing`; modes for the on-device engine behind their own
   consent, a capsule caption naming the agent or the edit while recording, choosing an agent per
   press, and reordering modes; for the history, running a mode on an entry again and pinning
   entries. Upstream declined voice control (#1550).
4. **Tinycast as an MCP server — declined.** A stdio helper that would have lent the launcher's
   clipboard, screen, notes and dialogs to Claude Code, Codex and other MCP clients. Those stay
   inside Tinycast's own agents.

### Wave 2 — context and power

5. **Background and scheduled agents — shipped** (see above), including a launcher row and hotkey per
   agent, the unattended briefing for ACP agents, a daily spend cap for schedules, and one Agents
   menu-bar item shared with Agent Sessions' live status (item 2). Next on it: nothing agreed.
   Undecided: a per-agent cap or a cap on launcher runs, and cost estimates for routes that report
   none.
6. **Screen Awareness+ and Capture — undecided.** Area and full-screen capture, Vision OCR when an
   app exposes no Accessibility text (canvas apps, games), Finder's selected files, a `{screen}`
   placeholder for Quick Actions ("reply to this" in one key) and a searchable screenshot library
   (upstream #1211 declined; `dnw3` and `fminkowski` forks built capture). The `screen_context` agent
   tool shipped with the native harness. *3–4 days.*
7. **Web search — shipped** (see above), with `read_page` for plain chats: it reads only a page the
   user linked in their own words or a search in the same turn returned, at the address the user or
   the engine wrote, at most five a turn, through `web_fetch`'s bounded read, under the same toggle.
   Quick AI tools (see above) brought it to Quick AI's ⌘K, with a Quick AI agent and a prompt that
   tells every chat the time and a plain one its tools. Next on it: nothing agreed. Undecided: the
   keyed engines Serper, Linkup, Ollama and Mojeek, reading an earlier turn's results without a new
   search, and ACP agents in Quick AI, which would need their pickers in the palette's header and a
   process kept up for a quick question.
8. **Raycast AI for extensions — shipped** (see above), including the requested `AI.Model` (opt-in,
   by the vendor its first word names, silently falling back to the extension model;
   Groq/Vercel/Baseten/Together names keep it), `creativity` as temperature (none for Gemini; one
   retry without it where a route refuses it), `AI.experimental_decide` (prompted probabilities, not
   logprobs) and AI from a menu-bar item's own action. Extension model providers
   (`ai.modelProvider`, `getModels`) were evaluated and left out: surfacing them in AI Chat needs a
   JS-backed provider layer and a resident extension runtime
   ([why](docs/features/extension-ai.md#what-maps-to-what)). Next on it: nothing agreed. Calibrated
   `experimental_decide` probabilities need logprobs no route exposes.
9. **Model arena — declined.** One prompt to two to four models side by side.

### Wave 3 — daily delights

10. **AI paste and AI snippets — declined.** "Paste transformed…" on a clipboard item, and an
    `{ai prompt="…"}` snippet placeholder.
11. **Leader-key menus — declined.** Vim-style key sequences and nested keyboard menus of actions.
12. **Developer utilities — paused**, perhaps as extensions rather than built-ins. Kill by port,
    JSON / Base64 / URL / hash / UUID tools, colour picker, Caffeinate, timers and Pomodoro (`nikteg`,
    `Sai1boats` forks), `#` to run a shell line from root search.
13. **Notes ↔ AI — shipped** (see above): Attach Note… and `@note` in AI Chat, Attach Note… in Quick
    AI's ⌘K menu, the `notes_search` / `notes_read` / `notes_append` tools for agents on the native
    harness, and a schedule's Append the answer to a note (item 5). Next on it: nothing agreed
    (`@note` in Quick AI's query was left out: the launcher and MCP addressing already parse that
    query).
14. **Usage dashboard — shipped** (see above), including the usage log for Quick Actions, voice,
    extension AI and chat titles, the optional OpenRouter management key for the account balance, the
    trend strip and the AI Usage command. Next on it: nothing agreed. Undecided: a per-origin
    breakdown (Quick Actions / voice / extensions) from the log's existing origin column, which needs
    no format change, and reading OpenRouter BYOK's `upstream_inference_cost`.
15. **App-aware snippets — declined.** Offer the snippets written for the app in front first.
16. **Moonshot — meeting copilot — not now.** On-device transcription of microphone and system audio
    into a running transcript, summarised into Notes when the meeting ends.

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
