# Background and scheduled agents

An [agent](agents.md) can work with no window open. Typing `@rig check the GPU temps` in root search
starts a turn in a new chat bound to the agent, hides the palette and puts a small indicator in the
menu bar; a HUD, and a Notification Center banner for agents that opt in, says when it ended, and
**Open** brings the chat up in AI Chat. An agent can also have **schedules**: daily, on working days
or every few hours, each with a prompt and a rule for runs missed while the Mac slept. Every run is
an ordinary chat, and a schedule can also append its answer to a note.

Everything lives in `Features/Agents/` plus a few lines in `AIChatSurfacesState`, `AIChatCoordinator`,
the launcher's fallback files, `CommandID`, `AISettingsView` and `AppCore`, and, for each agent's own
row and chord, `AppIndex`, `LauncherList`, `LauncherCoordinator`, `AppActionsMenu`, `HotKeyAction`,
`HotKeyManager` and `VisibilityStore`, each hunk marked `Fork:`.

## Invariants

- **A background run is an ordinary chat.** `AgentBackgroundCoordinator` makes a fresh
  `AIChatState`, sends through `AIChatCoordinator.send` and parks the chat in
  `AIChatSurfacesState.answeringElsewhere` (`park`), where a window chat left mid-reply already waits.
  There is no second execution path: tools, MCP, ACP (an agent's remembered model and options
  included), history, titles and the sidebar's spinner work unchanged, and `holder(of:)` finds the
  run, so no second writer can open it. Clicking it in the sidebar takes the live chat over and the
  reply keeps streaming on screen. When the reply ends the chat is unparked, so its transcript is
  freed.
- **Nothing exists until something needs it.** With no enabled schedule and no agent asking for
  banners, `AgentCoordinator` makes no `AgentBackgroundCoordinator` at all; `AgentBackgroundNeeds`
  decides, and `agent-schedule-test` proves that agents alone, a switched-off schedule or AI off need
  nothing, and that a scheduler with no enabled schedule holds neither a task nor an observer; the
  coordinator's own guard is in the manual sweep. A launcher run makes the coordinator, and it is
  dropped again once nothing runs, shows or waits.
- **One sleeping task, no heartbeat.** `AgentScheduler` sleeps until the next due time with a 30 s
  tolerance, drops that task when the Mac is about to sleep and re-arms on wake, clock and time-zone
  changes: four observers, kept only while some schedule is enabled. A run in flight adds one
  watchdog task and one `ProcessInfo` activity that keeps the Mac from idle-sleeping, both released
  when the run ends, and shows in the one transient Agents `NSStatusItem`.
- **One Agents menu-bar item, and only while it has something to show.** `AgentsStatusItem` lists
  background runs and Agent Sessions' live sessions together; `AgentCoordinator.refreshMenuBar`
  makes it when either source has a run working, waiting or finished unseen, or a session working,
  waiting or finished unseen, and removes it when neither has. Each half keeps its own switch: the
  sessions appear only while AI, the hub and its **Show running agents in the menu bar** are on.
  There is no timer and no observer; rows are built as the menu opens.
- **After sleep, every due run waits out the settle.** The wake, a clock change and a run's end can
  reach the scheduler in any order. Each compares the continuous clock, which counts sleep, with the
  suspending one, which does not; any gap over a second means the Mac slept, so the first of them
  already holds a due run 60 s for the network.
- **Schedules are only active while Redcast runs.** There is no launchd job, helper or XPC service.
  Times are local wall-clock times wherever the Mac is. A run up to five minutes late is on time;
  after launch or wake a due run waits 60 s for the network.
- **Missed runs collapse or are dropped.** Under **Run once when back** every missed occurrence
  becomes one run; under **Skip it** they are dropped and the next runs on time. A new, re-timed or
  re-enabled schedule starts counting from that moment, so it never catches up. A busy agent's due
  run waits for its current run to end rather than being retried on a timer.
- **An unattended request reaches only someone at the Mac.** A request that would ask — a change, a
  command, an ACP permission — follows the agent's **In the background** choice. **Ask me** shows
  the dialog only when the Mac was used in the last two minutes; it never activates Redcast, waits
  its turn behind any open dialog and puts Return on Don't Allow, so typing elsewhere can never
  approve anything. When nobody is there, or under **Decline**, the request is refused at once and
  counted on the run's row, as is anything a sub-agent of the run is refused, since it never asks.
  A rule of Always Allow still allows, and Never Allow still refuses.
  `AgentConsentPlan` says how a request is put, and `AgentConsentGate.ask` decides it again when its
  turn in the queue comes, so someone who left during the wait is not asked and a Stop shows nothing.
  An ACP refusal nobody chose picks the agent's refuse-once option, or cancels the request when it
  offers none, so it never leaves an "always" behind.
- **An unattended turn is told so, on either runtime.** A native agent's instructions and an ACP
  agent's prompt both carry the briefing while, and only while, the run is active; the ACP one goes
  on every such turn, not only a fresh session's first, so the agent's own loaded session cannot
  miss it. A slash command's turn is the exception: the agent must read the command first, so it
  goes as typed. Since a run starts a fresh process, its first `/word` waits for the session's list
  ([why](agents.md#acp-agents)), so a task such as `/tmp is full…` is briefed like any other. It is
  model-facing text, never localized, and names no tool and no file.
- **Agent questions queue.** `AgentConsentGate` asks one at a time and only once no dialog is up,
  observed rather than polled, so a foreground and a background ask no longer refuse each other.
- **An unattended run's `web_fetch` opens only a few pages it was given.** The run's task text, the
  results of its own searches and the links on pages it read that stay on their site, at the
  address given, eight pages a run at most; any other address is refused before a request. That
  narrows what a run nobody watches can carry out in a URL to which few given pages it reads, rather
  than closing it ([agents](agents.md#invariants)). A native agent's sub-agents keep to the same
  pages and count toward the same eight, and a run that read the user's data narrows the chat's
  later turns as a watched one does.
- **Only Always-trusted MCP servers ride an unattended turn.** Servers set to Ask are excluded through
  the run chat's tools menu, so MCP's own dialog, which allows on Return, never appears for one.
- **Nothing here travels in a backup or `settings.json`.** The policy, the banner opt-in, the
  schedules and the spend cap live in `agents.json`, `agent-schedules.json`,
  `agent-schedule-runs.json` and `agent-schedule-spend.json` beside the other agent files, which are
  in no backup category and have no `SettingsFileKey`.
- **Schedules spend only up to the day's cap.** With a **Daily spend cap**, a run a schedule starts
  on its own is not started once the local day's finished scheduled runs cost the cap or more: it
  gets a failed row saying so instead of a chat, and its occurrence is spent. A capped run whose
  reported cost, with the day's total and the other capped runs in flight, passes the cap is stopped
  and its row says why. Costs are only what routes report (`AgentSpendMeter` over a native turn,
  `AgentACPHost.onCost` for each ACP `usage_update`); a route that reports none counts nothing.
  Run Now and `@handle` runs are a person's gesture: never held, never counted. A cap file that will
  not read counts as $0, so nothing scheduled starts until the cap is set again.
- **A capped run's reported cost counts however the run ends.** Finished, stopped, cut off by AI
  off or a quit (`stopAll` adds `cappedSpend` before it lets the runs go), or with its chat deleted
  mid-turn: `AgentRun.spend(final:)` takes the turn's final cost, else the last one its route
  reported, so a relaunch never hands a schedule a fresh day's budget.
- **An agent's row and chord cost nothing until used.** The rows exist only while AI is on, and only
  an agent with a chord is indexed in `boundAgentIDs` and registered with `HotKeyCenter`. Deleting an
  agent takes its chord, favorite, alias and ranking with it; no chord travels in a backup or
  `settings.json`, since the agents themselves do not.
- **Notification Center only on opt-in, and never with the answer.** A banner names the agent, the
  run and whether it finished; the answer stays in the chat. `AgentRunNotifier` and its delegate
  exist only while some agent opts in, and macOS asks for permission on the toggle's own click.
- **ACP agents are released as soon as an unattended run ends**, through `AgentACPHost.release`,
  unless a window or Quick AI chat is bound to the same agent (an empty chat that only shows it as
  the agent for new chats is not), so its `npx`, adapter and vendor CLI tree is gone at once
  instead of after the two-minute idle stop.
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
| `@rig check temps` | one **Ask Agent** row under `Use “check temps” with…` | asks it in Quick AI, in the palette (a CLI agent in AI Chat) | starts a background run, hides the palette |
| `@nobody x`, `@ri x`, `mail@x` | ordinary search | | |

These rows **answer alone**: `FallbackCoordinator.claim` returns a `FallbackClaim` and
`LauncherScreen` shows no ranked results, cards or files beside it, so ↵ can never launch whatever
happened to rank first. They are `Fallback.agent` and `.agentPick`, never part of `available`, so
Settings › Fallbacks never lists them. An ordinary query costs the claim one character's
comparison. **Run Agent Task** seeds root search with `@`; it is listed in the launcher and under
Settings › AI › Commands, where its hotkey and alias come free, while AI is on and an agent exists.
All of these rows are `AppEntry.Kind.agent`, like the agents' own rows below, but keep their
`agent:` and `agent-pick:` ids.

### An agent's own row and chord

While AI is on, every agent is also a row of its own in root search, under **Agents**, with its
`@handle` beside its name (`AppEntry.Kind.agent`, id `agent-profile:<uuid>`, built by
`AgentCoordinator.publishLauncherRows`). Typing its name finds it, and `agent` or `agents` lists them
all, the way `meeting` lists meetings. ↵ opens a new AI Chat with the agent. Its ⌘K menu offers
**New Chat** (↵), **Run in Background…**, which types `@handle ` into the field for a task, and
**Edit Agent**, which opens Settings › AI › Agents with the agent's editor up; then the shared
Favorites, Change Alias and Change Shortcut rows. The rows answer to AI's switch (`settingsOwner`
`.ai`), so no Settings checkbox gates them and **Hide from Search** is not offered, and Suggestions
never push one.

An agent's **chord** (`HotKeyAction.agent(id:)`) is recorded from that ⌘K row or from **Shortcut** in
the agent's editor. It summons root search with `@handle ` typed: ↵ on the empty task opens a chat,
↵ on a typed task asks it in Quick AI (a CLI agent in AI Chat), ⌘↵ runs it in the background. Only
bound agents are indexed (`boundAgentIDs`) and registered, so an agent without a chord costs nothing. Deleting an
agent clears its chord, favorite, alias, hidden flag and ranking; a chord whose agent is gone at
launch is dropped once `agents.json` has read. Chords, like agents, travel in no backup and no
`settings.json`.

[Ask by Voice](voice-ai.md#ask-an-agent-by-voice) starts the same run when an agent is chosen under
its **Answer with**: the spoken request, transcribed, is the task, and the window in front is staged
in the run's chat through `start(_:with:attachments:)` before the send, as a pasted capture would be.

## While and after a run

The Agents menu-bar item appears with the first run and goes once nothing is running and every
finished run has been seen, unless Agent Sessions still has a live session to show in it. It shows,
in order of priority, a run or session waiting for an answer, runs and sessions at work (with a
count past one), an unseen failure or an unseen success (`AgentRunLedger.Indicator.of` and
`merged(with:)`). Its menu is built only when opened: **Background Runs**, one row per run, newest
first, with ⌥ turning a running row into **Stop**; then **Agent Sessions**, one row per live
session, which jumps to it; then Search Agent Sessions while the hub's half is on, Clear Finished
while that half is on or a finished run is listed (it drops finished runs, withdrawing their
banners, and the hub's finished sessions; running and waiting ones stay), and Agent Settings….
Opening it marks finished runs and sessions seen. The work its closing does waits a turn of the main
queue, because AppKit sends the chosen row's action after `menuDidClose`, and the background
coordinator is not let go while the menu is open. A launcher run and Run Now show a HUD at the start
and the end; a schedule's own runs show none, so nothing pops up at 3 a.m. A run whose chat is on
screen in a key AI Chat window is marked seen with no HUD and no banner. A native agent's run is held
to its effort's time (5, 15 or 45 minutes, the schedule's own effort or the agent's): at that point a
call still running is stopped and its loop asks for a hand-over with tools off, a sub-agent having
ended 90 seconds before ([agents](agents.md#invariants)); one still going two minutes later is
stopped. An agent that never picked an Effort reads the least one lasting as long as the limit it
kept from before Effort, so a 30- or 60-minute agent is Thorough (45 minutes). An ACP agent keeps its
own "Stop a run after N minutes" (5–60) in its editor and has no Effort, so a schedule offers it none.

A native agent's model is told, while its turn runs unattended, that nobody can answer and that it
should finish with a short report (`AgentBackgroundBriefing.text`); a follow-up typed in the window
later is an ordinary turn. An ACP agent is told the same in its prompt: `AgentACPHost` asks its
`briefing` closure with the turn's chat, and an unattended chat's prompt carries
`AgentBackgroundBriefing.acp` — a `# Running unattended` section saying that nobody may be at the
Mac, that permission requests are declined unless someone at the Mac answers them, and to finish
with the result as the final message — after the fresh session's context, on every turn the chat
runs unattended except a slash command's, which goes as typed.

## Schedules

Settings › AI › Agents lists each agent's schedules under it. A schedule has a name, a prompt, a
**Repeat** rule (daily or weekdays at a time, or every 1, 2, 3, 4, 6, 8 or 12 hours from a time),
a catch-up rule, an optional note and an enabled switch. The editor puts Repeat in one menu on the
same line as its time ("Daily ▾ at 09:00", "Every 2 hours ▾ from 09:00") and the catch-up rule in
two radio buttons, so no language's labels can widen its 480-pt panel; a segmented control there
gave every segment the longest label's width and clipped the panel in French and Russian. **Run
Now** and **Delete** keep their own width, so the filling Cancel and Save never fold a label in two.
**Weekdays** are the locale's working days, through `Calendar.isDateInWeekend`. The prompt expands
`{date}`, `{time}`, `{weekday}` and the rest through `SnippetTemplateEngine`; `{clipboard}` and
`{selection}` expand to nothing. Each run is a chat titled `<name> · <date>`. **Run Now** saves the
schedule and runs it like a launcher run, leaving its next time where it was.

`agent-schedules.json` is authored data: a file that exists but will not read is never written over,
the same rule as `agents.json`. `agent-schedule-runs.json` holds each schedule's **baseline**, when it
last fired or started counting, apart from the schedules so a run never rewrites what the user wrote.
The next run is the first occurrence strictly after the baseline; a baseline ahead of the clock is
read as now, so a clock set back cannot postpone a day.

With **Append the answer to a note**, a finished run adds `## <name> — <date, time>` and the answer,
cut at 64 KB with a pointer to the chat, one blank line below what the note held. The note open in
the Notes editor is changed through `NotesStore`, which stays its only writer while editing; any
other is written on disk and re-listed the next time Notes opens. With Notes off, nothing is written.

### Daily spend cap

**Daily spend cap** under the agents takes US dollars, empty for none; its subtitle adds what
scheduled runs spent today, on a third line where a language needs one. The field is wide enough for
its "No cap" placeholder in every language. `agent-schedule-spend.json` holds the cap, the local day
last counted and that day's total (`AgentScheduleSpend`, every field optional); `AgentSpendPolicy`
decides, and a new day starts at zero. A run is checked as it is due — at or past the cap it is held
and its row reads "Not started: scheduled runs reached today's cap of $5.00", and opening that row
shows the cap — and again on every cost its route reports while it runs, which ACP agents send
mid-turn and the native loop after each round. When the turn ends, its last reported cost joins the
day's total, also when AI is switched off, Redcast quits or the chat is deleted before it ends. The
held run's row shows only its reason, with no "Failed:" in front, since it never started. The cap is
local to the Mac's day and time zone, like the schedules.

## Layout

| File | Holds |
| --- | --- |
| `Model/AgentTaskAddress.swift` | Handles and `@handle task` parsing |
| `Model/AgentSchedule.swift` | The rule, the schedule, its errors, and `AgentSchedulePolicy`: occurrences, verdicts, summaries |
| `Model/AgentRun.swift` | A run, how it ended and the ledger behind the indicator, `AgentConsentMode`, `AgentConsentPlan`, `AgentBackgroundNeeds`, the note block, both briefings |
| `Model/AgentScheduleSpend.swift` | The cap file's shape and `AgentSpendPolicy`: days, starts, stops, totals and the rows' reasons |
| `Service/AgentScheduler.swift` | The one sleeping task, its four observers and the sleep meter |
| `Service/AgentRunNotifier.swift` | Opt-in Notification Center banners |
| `Service/AgentSpendMeter.swift` | A capped native turn's route, passed through, its reported costs heard |
| `UI/AgentBackgroundCoordinator.swift` | Starting, watching and finishing runs; consent mode; the notifier and the scheduler; feeds the Agents item |
| `UI/AgentConsentGate.swift` | One agent question at a time, never over another dialog, put as its plan says |
| `UI/AgentsStatusItem.swift` | The one transient Agents menu-bar item and its menu, runs and sessions |
| `UI/AgentsMenuBar.swift` | `AgentCoordinator.refreshMenuBar`: when the item exists, what it shows, what its rows do |
| `UI/AgentTaskLauncher.swift` | Root search's claim, ↵, ⌘↵, Run Agent Task and the rows' ⌘K menu |
| `UI/AgentLauncherRows.swift` | Each agent's own row, its ⌘K menu, its chord's summon, and its cleanup on delete |
| `UI/AgentNoteWriter.swift` | Appending to a note, through the store or on disk; in `UI/` because it needs `NotesStore` |
| `Settings/AgentScheduleEditorPanel.swift` | The schedule editor |

## Manual sweep

**Launcher runs**

- Type `@` in root search: every agent is listed. `@ri` + ↵ completes to `@rig `; `@rig ` + ↵ opens a
  chat with Rig. `@rig list the folder` + ↵: the palette hides, the HUD says "Rig is working in the
  background", the item appears and AI Chat's sidebar shows the chat answering. On finish: HUD "Rig
  finished" and a ✓; the menu lists the run and **Open** shows it; closing the menu removes the item.
- `@rig add a line to README` under **Ask me** while typing in another app: the dialog appears without
  activating Redcast, says it is from a background run, and Return answers **Don't Allow**. Under
  **Decline**: no dialog, and the row says "1 request declined".
- **Ask me** while away for more than two minutes (start a run, leave the mouse and keyboard alone): no
  dialog; declined and counted.
- Two background asks at once (two agents): the second dialog waits for the first instead of vanishing.
- ⌥ on a running row → Stop: the chat ends "Cancelled". An agent at Quick on a long task: after five
  minutes its reply hands over what it has, and the row is done.
- Four quick runs: the fourth is refused with a HUD. A second run for a busy agent is refused.
- An MCP server set to Ask is not offered in a background turn; one set to Always is.
- ↵ on `@rig task`: Quick AI opens in the palette with the agent's header and answers there; on a CLI
  agent, AI Chat opens with it. ⌘↵: a background run starts and the palette hides.
- **Run Agent Task** and its hotkey: the palette opens with `@`. Hidden, and the hotkey inert, while AI
  is off or there are no agents.
- Type an agent's name: its row shows under Agents with `@rig` beside it; ↵ opens a chat with it.
  `agents` lists every agent. Rename the agent: the row follows, and its favorite, alias and chord
  stay. ⌘K → Run in Background…: the field reads `@rig `. ⌘K → Edit Agent: Settings opens on AI with
  Rig's editor up, also when Settings was already open on another pane.
- ⌘K → Change Shortcut, press ⌥⌘R: the chord summons the palette with `@rig ` typed from any app;
  Return opens a chat, a typed task runs in the background. The editor's Shortcut shows the same
  chord. A chord another action owns is refused with its name. An agent without a chord: nothing in
  `HotKeyCenter` for it. Delete the agent: the chord is free again and its row, favorite and alias
  are gone. AI off: no agent rows, and the chord does nothing.

**Schedules**

- With Settings › General › Language set to Russian, then French and German, relaunch and open New
  Schedule and an existing schedule: the title and every field start at the panel's left edge,
  Repeat and its time share one line, both catch-up choices read in full, and Run Now's label stays
  on one line. Every 3 hours from 01:30 saves, and its row in Settings says so.
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
  refuse-once option. Its transcript (`~/.claude/projects/…`) shows the prompt opening with the
  context, then `# Running unattended`; a follow-up typed in the window afterwards has neither. When
  the run ends, the `npx`/adapter/CLI tree leaves Activity Monitor at once. Two Claude Code agents
  asking at once: each dialog names its own agent and run.
- **Daily spend cap** of 0.01 with a schedule on an OpenRouter model (or Claude Code) two minutes
  ahead: the run starts, is stopped once its reported cost passes a cent, and its row says "Stopped at
  today's spend cap of $0.01"; the subtitle shows what was spent today. The next due run does not
  start: an unseen ✗ appears and its row says "Not started…"; clicking it opens Settings › AI ›
  Agents. Run Now and `@handle` still run. Empty the field: the next due run starts. Quit, set the
  file to `garbage` and relaunch: the field reads 0 and nothing scheduled starts until it is set.
  Quit, or turn AI off, while a capped run that has reported a cost is going: the subtitle's
  spent-today still includes it afterwards. In Russian, the subtitle with a spent-today amount ends
  on a third line with every word shown, and in French an empty field reads "Aucun plafond" whole.
- AI off mid-run: the run ends "Cancelled", and the item and the scheduler go away.
- With live status and **Show running agents in the menu bar** on, start a Claude CLI session and a
  `@rig` run: one item shows both under their headers and counts them. Let the run finish while the
  session waits: the item keeps the waiting symbol. Clear Finished: the finished run leaves
  Background Runs while a running one stays. Turn the hub's menu-bar switch off: the session rows
  and Search Agent Sessions leave the menu, Clear Finished stays only while a finished run is
  listed, and the item goes once the run is seen. No run and no live session: no item at all.

Harness: `agent-schedule-test` — handles and addresses, occurrences across weekends and daylight
saving, verdicts and catch-up, the ledger, its indicator and Clear Finished, consent modes and
plans, the gate's whole ask (in front, quiet with Return on refusal, refused unseen when nobody is
left after the wait, nothing shown after Stop, what is counted) and a counted unattended refusal,
how a run ends and its limit, note blocks and the append on disk and through an open note's store,
persistence and its refusals, the scheduler's arming and its settle after sleep, and the consent
gate waiting for a dialog in order, and the spend cap: days, starts at and below the cap, stops past
it, a new day, nonsense costs and caps, the capped origin, its running spend and what it adds
however it ends, its end state, the file's persistence and an unreadable file failing closed.
`acp-test` covers the refusal option, two agents sharing a session id, the briefing (on an
unattended chat's every turn, after the context, never on a chat someone started, and on a fresh
process's `/word` turn) and an unattended session started on the agent's remembered picks.
`agent-loop-test` runs `AgentSpendMeter` over the loop: unchanged events and a growing cost after
each round, a sub-agent's rounds included.
