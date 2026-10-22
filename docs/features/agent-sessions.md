# Agent Sessions

**Search Agent Sessions** lists every past Claude Code, Codex and Tinycast AI session in one palette
screen: titles, first and last prompts, folder and branch, and a preview of the last turns. ↵ resumes
a session where it lived — `cd` into its folder and `claude --resume <id>` or `codex resume <id>` in
the terminal it ran in — or reopens a Tinycast chat in AI Chat. **Jump to Agent** brings forward the
terminal tab of an agent that is waiting for you. An opt-in **live status** adds small hooks to Claude
Code and Codex so Tinycast can say, with a HUD, when an agent finishes or needs you. The feature lives
in `Features/AgentSessions/`, plus the few lines that wire it in.

## Invariants

- **Read-only on agent data.** Transcripts are opened for reading; Codex's SQLite databases open with
  `SQLITE_OPEN_READONLY` and `PRAGMA query_only`, and every connection closes before its function
  returns. The hub writes only its own cache, `live-status.json`, the hook backups, the self-deleting
  `.command` files and — after an approved diff — the two hook files.
- **Nothing is read until the screen opens, and it is all released on pop to root.**
  `AgentSessionsCoordinator.applyEnabled` at launch only shows or hides two commands; the index and
  the activity state are built on first use. `AgentSessionIndex.close()` runs from the screen's
  `onDisappear` and empties every array, cancels the load and any transcript search. A preserved
  re-summon inside the pop-to-root window keeps the loaded index.
- **No timers, no watchers, no resident process.** A refresh happens when the screen opens and on ⌘R.
  Activity ages out when it is next touched. The only child process is `claude agents --json`, with a
  3 s watchdog; on timeout or cancellation its whole tree is reaped through `ProcessTree`. Terminals
  are launched by LaunchServices and are never Tinycast's children.
- **Live status changes the agents' files only through an approved diff.** Settings shows each file,
  whether it is created, changed or removed, and the exact lines; nothing is written before **Turn
  On** or **Turn Off**. Each file is re-read first and a file that changed meanwhile sends the panel
  back to review. The original is backed up (newest five kept) and its permissions restored. Only this
  channel's handlers are touched, found by the marker `-b <bundle id> "tinycast://agent-sessions/event`
  in their command; no custom key is ever added to an agent's JSON.
- **Events need the token.** `tinycast://agent-sessions/event` carries the per-install token from
  `live-status.json`, compared in constant time; a wrong or missing token, an unknown field value or a
  malformed one drops the event silently. Every `tinycast://agent-sessions/…` URL is claimed, so none
  falls through to opening the launcher. A HUD's words come from Tinycast's own lookup of the session
  and fixed strings, never from the URL.
- **Hooks never launch Tinycast and never slow the agent.** Each hook is `async`, drains stdin after a
  64 KB head, uses absolute tool paths, exits 0, and does nothing unless `lsappinfo` finds this
  channel's bundle running; `open -g -b <bundle>` delivers to this channel only.
- **Capabilities stay off and never travel.** Live status is off by default and is a capability: it is
  `live-status.json` plus the hooks, outside `AppSettings`, so no backup or `settings.json` carries it.
  `agentSessionsEnabled`, `agentSessionsTerminal` and `agentStatusMenuBar` are excluded from backups;
  only `agentSessionsEnabled` has a settings-file key (`ai.agentSessions`). Its menu-bar rows are
  off by default and show in the one Agents item only while an agent works, waits or finished
  unseen ([background agents](background-agents.md#while-and-after-a-run)).
- **Tinycast's own ACP sessions show once.** A Claude or Codex session whose id is in
  `AgentStore.acpSessions` is a Tinycast chat and is listed only as that chat; Codex threads with the
  `tinycast` originator are dropped for the same reason.
- **Only a person's own sessions are tracked.** An event for an automated run (`claude -p`, an SDK
  run, `codex exec`, a Codex subagent or guardian review) or for Tinycast's own session (an
  `acpSessions` id, the `tinycast` originator, or an agent whose process runs under Tinycast) is
  dropped, along with any entry it had before it was known. So no HUD, menu-bar row or Jump to Agent
  ever points at one, and a burst of them never evicts a waiting session from the 32 kept.

## Layout

| File | Holds |
| --- | --- |
| `Model/AgentSession.swift` | The row model, sources and hosts, live status, `AgentSessionText` cuts |
| `Model/ClaudeTranscriptDecoder.swift` | JSONL head and tail facts, the line filter, human prompts, titles, preview turns |
| `Model/ClaudeIndexFormat.swift` | The cache file, `ClaudeRescanPolicy` (reuse, tail or full read per transcript) |
| `Model/CodexStateReader.swift` | `state_5.sqlite` threads, `thread_history_1.sqlite` turns, rollout turns, hosts, titles |
| `Model/AgentSessionQuery.swift` | Filter, folded search keys, ranking |
| `Model/AgentResumeCommand.swift` | Terminals, shell quoting, resume commands, AppleScript and `.command` bodies |
| `Model/AgentHookFileFormat.swift` | The hook command, install/remove/state, `JSONMemberSplice`, `OrderedJSON`, `LiveStatusRecord` |
| `Model/AgentEvent.swift` | `AgentDeepLink`, events, `AgentActivityPolicy` (prune, jump, HUD), `ClaudeAgentsListing` |
| `Service/AgentSessionsScanner.swift` | Listing, bounded head and tail reads, the cache file, previews, event lookup |
| `Service/AgentTranscriptSearch.swift` | Search inside transcripts on request |
| `Service/AgentTerminalRunner.swift` | Opens a command or folder in a terminal; focuses a tab by tty |
| `Service/AgentProcessHost.swift` | Host app and tty from a pid, by a `sysctl` walk up the parents |
| `Service/AgentHookRepository.swift` | Snapshots, every file re-read before any is written, backups, `live-status.json` |
| `Service/ClaudeLiveSessionsProbe.swift` | `claude agents --json`; its tree is reaped through `Agents/Service/ProcessTree.swift` |
| `UI/AgentSessionsCoordinator.swift` | The action surface: screen, resume, jump, events, HUDs, live status |
| `UI/AgentSessionIndex.swift` | The loaded sessions, their keys and live state while the screen is open |
| `UI/AgentActivityState.swift` | What the hooks reported |
| `UI/AgentSessionsScreen.swift` | The palette screen and its ⌘K menu |
| `UI/AgentSessionsList.swift`, `UI/AgentSessionPreview.swift` | The list and the preview |
| `Settings/AgentSessionsSettingsSection.swift`, `Settings/AgentHooksPanel.swift` | The AI pane's section and the diff panel |

## What is read

Formats were measured on Claude Code 2.1.285–2.1.303 and codex-cli 0.162; no private text is quoted.

- **Claude Code.** Only `~/.claude/projects/<folder>/<session>.jsonl` at depth two is a session;
  anything deeper is a subagent. The folder name is a lossy encoding of the cwd, so the cwd is read
  from the file, and a `relocated` entry's `relocatedCwd` wins for resuming. The head is read in 16 KB
  chunks up to 512 KB until the cwd and the first human prompt are known; lines over 128 KB are
  skipped without buffering. The tail is the last 64 KB, widened once to 256 KB when it held no
  title; titles follow `custom-title`, then `ai-title`, then a legacy `summary`, then the first prompt
  cut to 80 characters. `lineKind` classifies a line by its first 512 bytes before anything is
  decoded: an assistant line names `"role":"assistant"` inside `message`, and its own `type` comes
  kilobytes later. Entry point `claude-desktop` is the Claude app, `sdk-*` is an automated run.
- **Codex.** Visible threads come from `state_5.sqlite` (`preview <> ''`, a non-JSON `source`, not
  archived unless asked), with columns probed by `PRAGMA table_info`; guardian and subagent threads
  are dropped. A preview comes from `thread_history_1.sqlite`'s projected items, else the uncompressed
  rollout's tail; a rollout that is now `.jsonl.zst` has no preview, since reading zstd would take a
  dependency.
- **Tinycast.** `ChatHistoryStore.conversations`, already resident while AI is on; a chat bound to an
  agent takes that agent's folder.

The Claude index is cached in `Caches/<bundle id>/agent-sessions/claude-index.json` (mode 0600): per
transcript its size, mtime, cwd, branch, entry point, first and last prompt (≤ 300 characters) and
title. An unchanged file is reused, a grown one reads only its tail, anything else is read again.
Switching the hub off deletes the cache.

## Resume

`AgentResumeCommand` builds `cd '<folder>' && claude --resume <id>` (`--fork-session` to fork),
`codex resume <id>` / `codex fork <id>` and `claude attach <short id>`; an id outside
`[0-9A-Za-z-]{1,64}` gets no command at all. Folders are single-quoted for the shell and
backslash-escaped for AppleScript. **Automatic** is the terminal the live session runs in, else
Terminal.

| Terminal | How |
| --- | --- |
| Terminal, iTerm2 | AppleScript in a new window or tab (Automation consent once) |
| Ghostty ≥ 1.3 | AppleScript surface configuration with the folder and the command as input |
| Ghostty < 1.3, Warp | Opens the folder (Warp: `warp://action/new_tab?path=`), copies the command, a HUD says to paste |
| Zap | A self-deleting `.command` in the temporary directory, opened with Zap |

A missing folder copies the command and says so. A live session with a known host is brought forward
instead (**Jump to Session**): Terminal and iTerm2 select the tab by tty.

## Live status

**Pull.** When the screen opens and Claude rows exist, one `claude agents --json` (located once
through `ExecutableLocator` and memoised) marks rows Working, Needs you or Open; background sessions
use their `state`. Hosts and ttys are resolved from each pid off-main.

**Push.** The command each hook runs (tool paths absolute; `BUNDLE`, `TOKEN`, `AGENT`, `EVENT` filled in):

```sh
p=$(head -c 65536); cat >/dev/null; [ -n "$(lsappinfo find bundleid=BUNDLE)" ] || exit 0;
s=$(printf '%s' "$p" | sed -n 's/.*"session_id" *: *"\([0-9A-Za-z-]\{1,64\}\)".*/\1/p' | head -n 1);
n=$(printf '%s' "$p" | sed -n 's/.*"notification_type" *: *"\([a-z_]\{1,40\}\)".*/\1/p' | head -n 1);
open -g -b BUNDLE "tinycast://agent-sessions/event?v=1&k=TOKEN&agent=AGENT&event=EVENT&session=$s&kind=$n&pid=$PPID"; exit 0
```

Claude Code gets `UserPromptSubmit` (working), `Notification` matching `permission_prompt`,
`elicitation_dialog`, `elicitation_url_dialog` and `agent_needs_input` (waiting), `Stop` (finished),
`StopFailure` (failed) and `SessionEnd` (ended) in `~/.claude/settings.json`; Codex gets
`UserPromptSubmit`, `PermissionRequest`, `Stop` and `SessionEnd` in `~/.codex/hooks.json`, created
when absent and deleted again when it held only these. Codex's `notify` is never touched: it is
already taken by Computer Use, and Codex allows one. Codex runs new hooks only after `/hooks` trusts
them; **Update…** keeps the token, so the command and the trust survive it. The `hooks` value is
re-rendered in the file's own indent and line endings with its keys in their original order; every
other byte of the file stays as it was.

An event resolves its session from this Mac's own history and its host app and tty from the pid; a
Codex thread is looked up by id even when the listing hides it, so a subagent reads as automated and
Tinycast's own thread as Tinycast's. Only a person's own sessions are kept (see Invariants). A HUD is
shown only for finished, waiting or failed; never for a Claude app or Codex app session, a host that
is in front, an unchanged status, or a repeat within 10 s. Activity keeps at most 32 entries, drops
an ended one after 10 minutes and anything after 12 hours.

With **Show running agents in the menu bar** on, the hub's live sessions are a section of the one
Agents menu-bar item that background runs use (`Agents/UI/AgentsStatusItem.swift`): the hub gives it
`menuBarIndicator` and `menuBarRows`, built as the menu opens, and the item's opening marks finished
sessions seen. Rows jump to their session; Search Agent Sessions and Clear Finished sit below. With
the switch off, the item shows no session, row or hub action at all.

## Manual sweep

Run in `Tinycast Dev.app` with AI on.

1. **Search Agent Sessions** lists Claude, Codex and Tinycast rows; a first open shows progress, a
   re-open and a relaunch are instant (the cache works).
2. A title, a folder name and words from the first prompt each find the session.
3. ↵ on a Claude CLI session resumes it in Terminal (Automation prompt once); repeat with iTerm2,
   Ghostty ≥ 1.3, Warp (new tab plus a copied command) and **Zap** — the `.command` must *run* in
   Zap; if it opens in Zap's editor, Zap's launch kind becomes `.folderURL("zap")`.
4. ⌃⌘↵ forks; ⌘↵ copies the command and pasting it works.
5. A Codex thread resumes with `codex resume`; ⌘O opens it in the Codex app.
6. A Claude app session: ⌘O activates Claude.app. Try `claude://code/continue?session=<uuid>` by
   hand and record here whether it opens the session; until then ⌘O only activates the app.
7. A Tinycast chat opens in AI Chat; ⌘↵ opens it in Quick AI; an agent's chat shows the agent's name.
8. A session whose folder was deleted: ↵ copies the command and the HUD explains.
9. ⌘K → Show Automated Runs reveals `claude -p` and `codex exec` runs; Include Archived shows archived
   Codex threads.
10. "Search inside transcripts" finds a word said only mid-session; typing cancels it.
11. Start a Claude CLI session in Terminal and let it wait for permission: the row shows **Needs you**
    under Live, and **Jump to Agent** brings that tab forward.
12. Settings → AI → Agent Sessions → Live status → **Turn On…**: the diff shows only the inserted
    `"hooks"` lines and a new `~/.codex/hooks.json`; Turn On writes them and the backups exist. In
    Codex, `/hooks` lists four hooks and trusting them works.
13. With another app in front, a finished Claude turn gives "Claude Code finished in <folder>", a
    permission prompt "… needs you …"; none while that Terminal is in front, none for a Claude.app
    session. `claude -p`, `codex exec`, an AI Chat turn on the Codex route and an agent chat in
    Tinycast give no HUD, no menu-bar row and are never a Jump to Agent target. Check `$PPID`
    resolves the host for both agents.
14. The Agents menu-bar item (opt-in for sessions) appears while an agent works and leaves after
    Clear Finished; its Agent Sessions rows jump. With only one finished agent left, open the menu
    and click its row: the terminal comes forward and the item then leaves. When another agent
    finishes, choose Search Agent Sessions from the menu instead: the screen opens. A background run
    at the same time shares the item, under Background Runs.
15. Quit Tinycast and run an agent: nothing launches, and the transcript shows no hook error.
16. **Turn Off…** restores the original bytes (`diff` against the backup). Edit `settings.json` while
    the panel is open: Turn On refuses and shows the new diff.
17. `open "tinycast://agent-sessions/event?v=1&k=wrong&agent=claude&event=finished&session=x"`:
    nothing happens and the launcher does not open.
