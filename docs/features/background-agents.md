# Background and scheduled agents

An [agent](agents.md) can work with no window open. Typing `@rig check the GPU temps` in root search
starts a turn in a new chat bound to the agent, hides the palette and puts a small indicator in the
menu bar; a HUD, and a Notification Center banner for agents that opt in, says when it ended, and
**Open** brings the chat up in AI Chat. An agent can also have **schedules**: daily, on working days
or every few hours, each with a prompt and a rule for runs missed while the Mac slept. Every run is
an ordinary chat, and a schedule can also append its answer to a note.

Everything lives in `Features/Agents/` plus a few lines in `AIChatSurfacesState`, `AIChatCoordinator`,
the launcher's fallback files, `CommandID`, `AISettingsView` and `AppCore`.

## Invariants

- **A background run is an ordinary chat.** `AgentBackgroundCoordinator` makes a fresh
  `AIChatState`, sends through `AIChatCoordinator.send` and parks the chat in
  `AIChatSurfacesState.answeringElsewhere` (`park`), where a window chat left mid-reply already waits.
  There is no second execution path: tools, MCP, ACP, history, titles and the sidebar's spinner work
  unchanged, and `holder(of:)` finds the run, so no second writer can open it. Clicking it in the
  sidebar takes the live chat over and the reply keeps streaming on screen. When the reply ends the
  chat is unparked, so its transcript is freed.
- **Nothing exists until something needs it.** With no enabled schedule and no agent asking for
  banners, `AgentCoordinator` makes no `AgentBackgroundCoordinator` at all; `AgentBackgroundNeeds`
  decides, and `agent-schedule-test` proves that agents alone, a switched-off schedule or AI off need
  nothing, and that a scheduler with no enabled schedule holds neither a task nor an observer; the
  coordinator's own guard is in the manual sweep. A launcher run makes the coordinator, and it is
  dropped again once nothing runs, shows or waits.
- **One sleeping task, no heartbeat.** `AgentScheduler` sleeps until the next due time with a 30 s
  tolerance, drops that task when the Mac is about to sleep and re-arms on wake, clock and time-zone
  changes: four observers, kept only while some schedule is enabled. A run in flight adds one
  watchdog task, one transient `NSStatusItem` and one `ProcessInfo` activity that keeps the Mac from
  idle-sleeping, all released when the run ends.
- **After sleep, every due run waits out the settle.** The wake, a clock change and a run's end can
  reach the scheduler in any order. Each compares the continuous clock, which counts sleep, with the
  suspending one, which does not; any gap over a second means the Mac slept, so the first of them
  already holds a due run 60 s for the network.
- **Schedules are only active while Tinycast runs.** There is no launchd job, helper or XPC service.
  Times are local wall-clock times wherever the Mac is. A run up to five minutes late is on time;
  after launch or wake a due run waits 60 s for the network.
- **Missed runs collapse or are dropped.** Under **Run once when back** every missed occurrence
  becomes one run; under **Skip it** they are dropped and the next runs on time. A new, re-timed or
  re-enabled schedule starts counting from that moment, so it never catches up. A busy agent's due
  run waits for its current run to end rather than being retried on a timer.
- **An unattended request reaches only someone at the Mac.** A request that would ask — a change, a
  command, an ACP permission — follows the agent's **In the background** choice. **Ask me** shows
  the dialog only when the Mac was used in the last two minutes; it never activates Tinycast, waits
  its turn behind any open dialog and puts Return on Don't Allow, so typing elsewhere can never
  approve anything. When nobody is there, or under **Decline**, the request is refused at once and
  counted on the run's row. A rule of Always Allow still allows, and Never Allow still refuses.
  `AgentConsentPlan` says how a request is put, and `AgentConsentGate.ask` decides it again when its
  turn in the queue comes, so someone who left during the wait is not asked and a Stop shows nothing.
  An ACP refusal nobody chose picks the agent's refuse-once option, or cancels the request when it
  offers none, so it never leaves an "always" behind.
- **Agent questions queue.** `AgentConsentGate` asks one at a time and only once no dialog is up,
  observed rather than polled, so a foreground and a background ask no longer refuse each other.
- **Only Always-trusted MCP servers ride an unattended turn.** Servers set to Ask are excluded through
  the run chat's tools menu, so MCP's own dialog, which allows on Return, never appears for one.
- **Nothing here travels in a backup or `settings.json`.** The policy, the banner opt-in and the
  schedules live in `agents.json`, `agent-schedules.json` and `agent-schedule-runs.json` beside the
  other agent files, which are in no backup category and have no `SettingsFileKey`.
- **Notification Center only on opt-in, and never with the answer.** A banner names the agent, the
  run and whether it finished; the answer stays in the chat. `AgentRunNotifier` and its delegate
  exist only while some agent opts in, and macOS asks for permission on the toggle's own click.
- **ACP agents are released as soon as an unattended run ends**, through `AgentACPHost.release`,
  unless a window or Quick AI chat is using the same agent, so its `npx`, adapter and vendor CLI
  tree is gone at once instead of after the two-minute idle stop.
- **The network is used only for the turn itself**, on the user's `@`, Ask by Voice or Run Now, or
  at a schedule's due time. A scheduled run names its chat itself, so it spends no extra title request.

## From the launcher

An agent's **handle** is its name lower-cased, letters and digits of any script kept and every other
run of characters one `-`; an empty result is `agent`, and a clash takes `-2`, `-3` in creation order
(`AgentTaskAddress`). `@` in root search addresses agents; in a chat composer it still addresses MCP
servers.

| Query | Rows | ↵ | ⌘↵ |
| --- | --- | --- | --- |
| `@`, `@ri` | one **Choose Agent** row per agent whose handle starts so | completes to `@rig ` | — |
| `@rig ` | one **Choose Agent** row, "Type a task, or press Return to chat" | a new AI Chat with the agent | — |
| `@rig check temps` | one **Run in Background** row under `Use “check temps” with…` | starts the run, hides the palette | runs it in AI Chat in front of you |
| `@nobody x`, `@ri x`, `mail@x` | ordinary search | | |

These rows **answer alone**: `FallbackCoordinator.claim` returns a `FallbackClaim` and
`LauncherScreen` shows no ranked results, cards or files beside it, so ↵ can never launch whatever
happened to rank first. They are `Fallback.agent` and `.agentPick`, never part of `available`, so
Settings › Fallbacks never lists them. An ordinary query costs the claim one character's
comparison. **Run Agent Task** seeds root search with `@`; it is listed in the launcher and under
Settings › AI › Commands, where its hotkey and alias come free, while AI is on and an agent exists.

[Ask by Voice](voice-ai.md#ask-an-agent-by-voice) starts the same run when an agent is chosen under
its **Answer with**: the spoken request, transcribed, is the task, and the window in front is staged
in the run's chat through `start(_:with:attachments:)` before the send, as a pasted capture would be.

## While and after a run

The menu-bar item appears with the first run and goes once nothing is running and every finished run
has been seen. It shows, in order of priority, a run waiting for an answer, runs in flight (with a
count past one), an unseen failure or an unseen success. Its menu is built only when opened: one row
per run, newest first, with ⌥ turning a running row into **Stop**; opening it marks finished runs
seen. A launcher run and Run Now show a HUD at the start and the end; a schedule's own runs show none,
so nothing pops up at 3 a.m. A run whose chat is on screen in a key AI Chat window is marked seen
with no HUD and no banner. A run still going after the agent's limit (15 minutes by default, 5 to
60) is stopped.

A native agent's model is told, while its turn runs unattended, that nobody can answer and that it
should finish with a short report (`AgentBackgroundBriefing`); a follow-up typed in the window later
is an ordinary turn. ACP agents get their context once per fresh session, which knows no chat, so
they do not get the briefing yet.

## Schedules

Settings › AI › Agents lists each agent's schedules under it. A schedule has a name, a prompt, a
**Repeat** rule (daily or weekdays at a time, or every 1, 2, 3, 4, 6, 8 or 12 hours from a time),
a catch-up rule, an optional note and an enabled switch. **Weekdays** are the locale's working days,
through `Calendar.isDateInWeekend`. The prompt expands `{date}`, `{time}`, `{weekday}` and the rest
through `SnippetTemplateEngine`; `{clipboard}` and `{selection}` expand to nothing. Each run is a chat
titled `<name> · <date>`. **Run Now** saves the schedule and runs it like a launcher run, leaving its
next time where it was.

`agent-schedules.json` is authored data: a file that exists but will not read is never written over,
the same rule as `agents.json`. `agent-schedule-runs.json` holds each schedule's **baseline**, when it
last fired or started counting, apart from the schedules so a run never rewrites what the user wrote.
The next run is the first occurrence strictly after the baseline; a baseline ahead of the clock is
read as now, so a clock set back cannot postpone a day.

With **Append the answer to a note**, a finished run adds `## <name> — <date, time>` and the answer,
cut at 64 KB with a pointer to the chat, one blank line below what the note held. The note open in
the Notes editor is changed through `NotesStore`, which stays its only writer while editing; any
other is written on disk and re-listed the next time Notes opens. With Notes off, nothing is written.

## Layout

| File | Holds |
| --- | --- |
| `Model/AgentTaskAddress.swift` | Handles and `@handle task` parsing |
| `Model/AgentSchedule.swift` | The rule, the schedule, its errors, and `AgentSchedulePolicy`: occurrences, verdicts, summaries |
| `Model/AgentRun.swift` | A run, how it ended and the ledger behind the indicator, `AgentConsentMode`, `AgentConsentPlan`, `AgentBackgroundNeeds`, the note block, the briefing |
| `Service/AgentScheduler.swift` | The one sleeping task, its four observers and the sleep meter |
| `Service/AgentRunNotifier.swift` | Opt-in Notification Center banners |
| `UI/AgentBackgroundCoordinator.swift` | Starting, watching and finishing runs; consent mode; the item, the notifier and the scheduler |
| `UI/AgentConsentGate.swift` | One agent question at a time, never over another dialog, put as its plan says |
| `UI/AgentRunsStatusItem.swift` | The transient menu-bar item and its menu |
| `UI/AgentTaskLauncher.swift` | Root search's claim, ↵, ⌘↵, Run Agent Task and the rows' ⌘K menu |
| `UI/AgentNoteWriter.swift` | Appending to a note, through the store or on disk; in `UI/` because it needs `NotesStore` |
| `Settings/AgentScheduleEditorPanel.swift` | The schedule editor |

## Manual sweep

**Launcher runs**

- Type `@` in root search: every agent is listed. `@ri` + ↵ completes to `@rig `; `@rig ` + ↵ opens a
  chat with Rig. `@rig list the folder` + ↵: the palette hides, the HUD says "Rig is working in the
  background", the item appears and AI Chat's sidebar shows the chat answering. On finish: HUD "Rig
  finished" and a ✓; the menu lists the run and **Open** shows it; closing the menu removes the item.
- `@rig add a line to README` under **Ask me** while typing in another app: the dialog appears without
  activating Tinycast, says it is from a background run, and Return answers **Don't Allow**. Under
  **Decline**: no dialog, and the row says "1 request declined".
- **Ask me** while away for more than two minutes (start a run, leave the mouse and keyboard alone): no
  dialog; declined and counted.
- Two background asks at once (two agents): the second dialog waits for the first instead of vanishing.
- ⌥ on a running row → Stop: the chat ends "Cancelled". A limit of 5 minutes on a long task: stopped,
  and the row says so.
- Four quick runs: the fourth is refused with a HUD. A second run for a busy agent is refused.
- An MCP server set to Ask is not offered in a background turn; one set to Always is.
- ⌘↵ on `@rig task`: it runs in AI Chat in front of you, as a normal chat.
- **Run Agent Task** and its hotkey: the palette opens with `@`. Hidden, and the hotkey inert, while AI
  is off or there are no agents.

**Schedules**

- A daily schedule two minutes ahead with **Append the answer to a note**: it runs, the chat is titled
  "<name> · <date>" and the note has the section. With that note open and edited in Notes, the append
  goes through the editor and the edit survives.
- Sleep across a due time and wake: the run starts about 60 s after wake (**Run once when back**), or
  not at all (**Skip it**), never at the wake itself, also with a background run in flight when the
  lid closed. Quit across a due time and relaunch: the same.
- Change the time zone: the next run follows local time. Disable for two days and re-enable: no
  catch-up run. Agent busy at the due time: the run starts when the current one ends.
- No schedules: `sample` shows no `AgentScheduler` task and Activity Monitor no idle wake-ups from it.
  Agents with no schedule and no **Notify**: Xcode's memory graph shows no `AgentBackgroundCoordinator`.
- **Notify** on: macOS asks once, on the toggle. A finished run posts a banner without the answer;
  clicking it opens the chat. Off: no banner and no `UNUserNotificationCenter` delegate.
- ACP: a Claude Code agent run from `@cc …` asks with Claude's own options; **Decline** picks its
  refuse-once option. When the run ends, the `npx`/adapter/CLI tree leaves Activity Monitor at once.
  Two Claude Code agents asking at once: each dialog names its own agent and run.
- AI off mid-run: the run ends "Cancelled", and the item and the scheduler go away.

Harness: `agent-schedule-test` — handles and addresses, occurrences across weekends and daylight
saving, verdicts and catch-up, the ledger and its indicator, consent modes and plans, the gate's
whole ask (in front, quiet with Return on refusal, refused unseen when nobody is left after the wait,
nothing shown after Stop, what is counted) and a counted unattended refusal, how a run ends and its
limit, note blocks and the append on disk and through an open note's store, persistence and its
refusals, the scheduler's arming and its settle after sleep, and the consent gate waiting for a
dialog in order. `acp-test` covers the refusal option and two agents sharing a session id.
