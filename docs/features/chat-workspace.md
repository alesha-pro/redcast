# Chat workspace

AI Chat's window, reorganised the way Raycast's AI Chat is: folders in the sidebar above Recent,
and the chat's settings in a sidebar of their own on the right, plus what Raycast's chat does that
upstream's did not: Archive and Recently Deleted, branches, editing a sent question, folding long
ones, ⌘1–⌘0, Always on Top and a banner when a reply finishes out of sight.
The feature is this fork's, in `Features/ChatWorkspace/`, plus marked lines in
`AIChatCoordinator` (the split view it shows, instructions, history load), `AIChatWindowChrome`
(its chords), `ChatHistoryStore`, `ChatSession`, `AIChatState`, `AgentCoordinator` and `AppCore`.
Upstream's `AIChatSidebarView` and `AIChatSplitViewController` stay in the tree, unused, so a merge
that touches them stays mechanical.

## Invariants

- **One small document beside the history, and nothing about a chat is lost by reading it.**
  `ChatWorkspaceStore` keeps `ai-chat-workspace.json` next to `ai-chats.sqlite3` in the bundle's
  Application Support folder. It holds the folders, in order, and an entry per chat that has
  something to say: its folder, Additional Instructions, Creativity, when it was archived, and
  when it went to Recently Deleted with the title it had. `ChatWorkspace(data:)` keeps whatever parses — a folder without an
  id or name, a chat key that is not a UUID or a date that is not a number is dropped alone, never
  the file — and every field it does not know, at the top, in a folder or in a chat's entry, is
  written back as it came (`unknown`). A missing or unreadable file is an empty workspace, so a
  history from before folders loads unchanged. The file is written only when something changes, by
  an atomic write, and travels in no backup, as the chats it describes do not.
- **Off means fully off, and nothing is resident.** The document is read just before the history
  loads, when AI is on (`ChatWorkspaceCoordinator.prepare`), and leaves memory with it (`close`).
  Nothing runs on a timer or polls: stale entries are pruned, deletions past 60 days erased and idle
  chats archived only as the history loads and as the window opens (`tidy`). ⌘'s digits come from
  a key-event monitor that lives with the window. Notifications are asked for only when their switch
  is turned on, and the notifier is made only for the first banner it posts.
- **Recently Deleted keeps a chat whole and out of sight.** Delete moves a chat there: a running
  reply stops and saves first, the chat is unpinned, and `ChatHistoryStore.isHidden` keeps it out of
  every list built from the history — the sidebar, Quick AI's Chat History, ⌃⇥, Opens to and a save
  that lands late — while its transcript, agent and notes stay on disk (`pruneAgentSummaries` keeps
  them). Restore lists it again; Delete Permanently…, Empty Recently Deleted… and a deletion 60 days
  old erase it with upstream's delete. Retention and Delete All Chats still apply to it.
- **An edited question rewrites the history, never splices it.** Sending an edit drops that
  question and every later message from memory and from `messages` (`AIChatState.rewind`,
  `ChatHistoryStore.dropMessages`) before the edit goes out as an ordinary send, so the stored
  transcript is exactly what the screen shows. Esc gives back the draft from before and changes
  nothing. Codex sees different history and starts a fresh thread, as it does for any change.
- **A chat is listed once.** `ChatSidebarLayout` puts a pinned chat in Pinned wherever it is filed,
  an unpinned one in its folder, and the rest in Recent by day. Filing a chat unpins it, as dropping
  it on a folder does; dropping one on a day header takes it back to Recent.
- **Deleting a folder never deletes a chat.** `ChatWorkspace.deleteFolder` moves its chats back to
  Recent and keeps their own settings; the confirmation says so.
- **The chat's settings are the chat's, wherever they are shown.** The right sidebar
  (`ChatSettingsSidebar`) reads one `ChatSettingsState` that `AIChatCoordinator` builds from the
  same calls the composer's menus made (`ChatSettingsSource`), so a pick there is the pick the
  composer used to make: the model and effort still move the app default, an ACP agent's selects
  still go to its session. Additional Instructions and Creativity are new and per chat, kept in the
  chat's workspace entry; Web Search stays the app-wide switch it was, and says so.
- **Creativity reaches only a route that takes it.** `ChatCreativityProvider` sets
  `AIRequest.temperature` (Raycast's levels: None 0, Low 0.4, Medium 0.7, High 1, Maximum 1.5) on
  every request an API route sends, tool rounds included, and is not there at all while the chat is
  on Model Default. Gemini keeps its own temperature, as extensions' `creativity` does, and installed
  CLIs and ACP agents take none, so the control is disabled for them. A model that refuses a
  temperature before saying anything is asked again without it.
- **A folder is organisational, and optionally a project.** It may carry instructions and an agent.
  Its instructions go into every chat filed in it, after Redcast's preamble and the system prompt
  and before the chat's own (`ChatInstructions.compose`), so upstream's rule that the user's text
  follows the preamble holds and a cached prompt prefix is the same for every chat. Its agent is
  the one a chat started in the folder begins on (New Chat in Folder), bound like a pick in the
  composer, so the working directory is the agent's: a folder adds no second one. ACP agents brief
  their own sessions and are not sent these instructions.
- **The window's transcript is upstream's eager stack, drawn by AppKit as before.** No lazy stack
  and no custom text drawing, so scrolling is exactly upstream's; memory is saved only around it.
  See [Memory](#memory); `Scripts/fork/chat-memory.sh` measures both memory and scrolling.
- **A chat is loaded whole when it opens and let go whole when it is left.** Nothing outlives a
  switch: a text view leaving the window drops its text at once, and no action keeps the chat it
  was made for. A closed window keeps only an idle, saved chat's id and reloads it on reopen
  (`ChatWindowRelease`).

## Folders

The sidebar (`ChatWorkspaceSidebar`) opens with a search field and a New Folder button. Search
matches titles at once and message text after a short pause (`ChatHistoryStore.conversationIDs`,
a `LIKE` over the messages in four case forms, since SQLite folds only ASCII). Under it come Pinned
(only when something is pinned), Folders and the days. A folder row is its tile (one of seven
colours and sixteen symbols, `ChatFolder.hues` and `ChatFolder.symbols`), its name and a count; a
click folds or unfolds it, and hovering it offers New Chat in Folder. Its chats sit in under it
behind a bar in its colour.

- **Create**: the button, the + on Folders or Move to Folder → New Folder…; the name is edited in
  place at once, and the new folder takes the next colour.
- **Rename, colour, settings, delete**: the folder's menu. Folder Settings… slides a panel over the
  sidebar (`ChatFolderEditor`): name, colour, icon, instructions and the agent new chats start with.
  Changes save as they are made.
- **File a chat**: drag it onto a folder, choose Move to Folder in its menu, or press ⌃⌘M in the
  window (`ChatMoveNSMenu`, under the Actions button). Drag it onto a day header, or choose Recent,
  to take it out.
- The open chat's row wears the accent's wash rather than the list's own selection, so it reads the
  same whether or not the window is key; a click opens a chat, a double click on its title renames it.
  The list selects nothing, so ⌫ no longer deletes the open chat; its menu and ⌘K do.

## Chat Settings

The toolbar's last button, over the right sidebar, ⇧⌘I, the composer's model chip and the sidebar's
✕ show or hide it; the choice is remembered (`ChatWorkspaceSettings.showsInspector`). It is an
inspector split item that collapses first when the window narrows, so the transcript keeps its
minimum width, and comes back as the window widens. Its cards:

- **Title** (rename; a chat with no message yet has none to rename), **Agent** with each agent's
  tile and Manage Agents…, **Model** with the maker's mark, **Reasoning**, **Creativity** and
  **Folder**. A chat on an ACP agent shows that agent's own selects instead of Model and Reasoning:
  its model, reasoning, mode and the rest, as its session lists them.
- **Additional Instructions**, a multi-line field saved as it is typed and sent last in the chat's
  system prompt, after the folder's.
- **Tools**: Web Search (every chat's, as before) and this chat's MCP servers, all, some or none,
  with MCP Settings….
- **Context**: the ring and its percentage (green, orange from 80%, red at 100%), what is in
  context of the model's window, the last turn's input with its cached share and output with its
  thinking share, the chat's tokens and its cost added up over every reply that reported one, and
  messages and history against the budget. It replaces the grey token count that ended the
  transcript; Quick AI keeps that line.

The composer keeps what is typed and the essentials: + (Attach Files…, Attach Note…), one chip
with the agent's tile, the model's mark and name that opens the settings, the mic while Dictation is
on, and Send/Stop. The window's title is the chat's, with the model and agent under it as the
subtitle, as Raycast's title bar has.

## Messages and the window

- **The latest reply's actions stay in view** under it: Copy, Regenerate (⌘R), Branch Chat and the
  time; earlier ones show theirs on hover. A question offers Edit Message.
- **Branch Chat** (a reply's row, a chat's menu or ⌘K) makes a new chat with the history up to that
  message, under new ids, named "… (Branch)", filed and asked as the original, on its agent.
- **↑ in an empty composer** brings the last question back to edit; ↑ and ↓ step through earlier
  ones while the recalled text is unchanged, and stepping past the newest, or Esc, gives the draft
  back. The question is outlined with an Editing tag and a line over the composer says what Return
  will do (`ChatRecall`, `ChatEditingBanner`).
- **A long question folds** to ten lines (a line past ninety characters counts as several) behind
  Show more; Find in Chat opens it. Quick AI draws questions as before.
- **⌘1…⌘9 and ⌘0** open the first ten rows the sidebar shows, from the top, skipping folded folders
  and Archived; while ⌘ alone is held each of those rows shows its digit (`ChatShortcutIndex`).
- **Archive** (a chat's menu or ⌘K) moves a chat to the collapsed Archived section; filing or
  pinning it brings it back. Settings → AI → AI Chat Window → Archive inactive chats (Never, the
  default, a week, a month or three months) archives unpinned chats idle that long, sparing any
  chat open or answering.
- **Recently Deleted**, collapsed at the bottom, lists deleted chats with how long ago they went;
  each restores or is deleted for good from its menu, and the header empties the section.
- **Keep Window on Top** (⌥⌘T or ⌘K) floats the window above other apps', remembered.
- **Notify when a reply finishes** (Settings → AI → AI Chat Window, off by default) posts a banner
  naming the chat, never what it says, when a window chat's reply ends while the window is not the
  key window of the active app; a click opens that chat. Quick AI's replies and background agent
  runs, which have their own banner, never post one. Turning it on asks macOS for permission; a
  refusal turns it back off and says where to allow it.
- Already upstream's, so kept as they were: Copy Chat (its menu and ⌘K), Regenerate (⌘R), Find in
  Chat (⌘F), ⌘J from Quick AI, and Queue / Send Now. Thumbs up and down are left out: no route
  takes feedback, and a rating kept only here would say nothing to anyone.

## Colour

Everything here is a token: `Theme.Colors.chat…` and `RaycastHue.ink`/`wash` in
`ChatWorkspaceTheme.swift`, over the brand's vermilion (#F23D32), and `ChatPalette` for the inks.

- Folders wear their own hue: the tile, the bar beside their chats, the menus' tiles.
- Section headers are tinted: Pinned yellow, Folders purple, the days red, Archived and Recently
  Deleted grey. Their ink is the tile's tone a fifth darker on light (`ChatPalette.lightInk`) and
  Raycast Dark's value on dark, so every hue reads at 4.5:1 or better on white, on `#F2F2F2` and on
  `#1E1E1E`; `chat-workspace-test` checks each one.
- The open chat's row is a vermilion wash, 14% on light and 26% on dark, under primary text.
- The model's mark wears its maker's colour (`ChatBrandHue`, and Agent Sessions' CLI hues where
  they overlap) in the settings sidebar, its menus and the composer's chip; an agent wears its tile.
- The reader's message sits on a vermilion wash (9% light, 20% dark) edged a step deeper, in both
  surfaces. A finished tool call's glyph says what it did (`ChatToolKind`): web blue, files purple,
  terminal green, notes yellow, an MCP server's orange; a search's globe is blue and a thinking
  fold's brain magenta. A failed call stays red.
- A code block's language is a small pill in its language's hue (`CodeLanguageHue`).
- The composer's caret and selection are the accent's (`ChatComposerInk`).

## Memory

The model: a chat opens whole, as upstream's eager stack builds it, and everything it built goes
when the window leaves it, by a switch or a close. Nothing changes how a transcript lays out,
draws or scrolls.

**Tried and reverted.** `ddef6f46` made the window's transcript a `LazyVStack`
(`ChatTranscriptStack`) and drew each reply's text per visible slice into an `IOSurface` on the
CPU (`ChatTextViewport`). Its harness showed the window under idle + 100 MB, but on the owner's
chats scrolling stuttered, jumped and would not settle, since a lazy stack replaces estimated
heights under the reader and the slice redrew on every bounds change; the installed app still
spiked to 240 MB and settled at 370 MB. `96cb7402` reverted all of it. The harness had missed
both, because its 40 chats were small and alike, its screenshots compressed to a fraction of a
real one, and it never timed a scroll.

**Measured with** `Scripts/fork/chat-memory.sh` (`-O`, macOS 27, on screen, 120 Hz display; see
[testing](../testing.md)). The fixture now holds 107 chats: a hundred short ones, the four
60-message chats (code, tables, math, tool rows, sources, file links, reasoning), and three more
like the owner's: eight replies of 5,266 lines in all (prose that wraps, lists, code, tables); an
agent run of 24 turns with 288 tool rows whose arguments run to 200 characters, diffs and output
under a third of them, 72 reasoning folds, text between the calls and eleven files with a folder
per reply for the links and Files strip; and 40 messages of long Russian prose. The screenshot
chat carries eight 3456×2234 screenshots of 3.6 MB each. Each cycle opens on a long chat, switches
seven times (short, the long replies, short, the agent run, Russian, math, screenshots), pages up
through the screenshots, opens and closes Chat Settings and closes the window. Idle is 11 MB of
footprint and 2.6 MB of live malloc; the harness has no palette or launcher, so the app's idle is
about 20 MB higher.

| Cycle 2, MB | 96cb7402 |
| --- | ---: |
| Footprint peak, open to close | 691 |
| Highest footprint while open | 661 |
| Live malloc peak | 230 |
| Footprint 4 s after closing | 170 |
| Live malloc after closing | 58 |

Scrolling, a steady 3,000 pt/s down and back up, three passes of each, as ranges over the passes
(frame interval and main-thread busy time per frame, ms):

| | 96cb7402 |
| --- | --- |
| Long replies (133,860 pt): interval p50 / p95 / max | 8.3 / 8.3–8.4 / 12.5–16.7 |
| frames over 16.7 ms, refreshes missed | 0, 1–3 |
| busy p50 / p95 / max | 6.1–6.4 / 6.6–7.5 / 9.8–12.8 |
| Agent run (47,167 pt): interval p50 / p95 / max | 16.7 / 16.7–17.5 / 24.5–30.3 |
| frames over 16.7 ms, refreshes missed | 23–86, 944–972 |
| busy p50 / p95 / max | 15.2–16.3 / 16.1–17.3 / 20.1–25.4 |

No pass moved backwards or changed the document's height, and the offset never strayed from the
asked one by more than one frame's step (25 pt). The agent run holds 60 frames a second at best:
its main thread spends a whole 120 Hz frame on each step.

### Steps

Each step was measured against the tree before it, back to back. A video render shared the
machine from step 1 on and doubled every frame time, so compare within a row, not with the
baseline above.

- **1. Tiles at their size.** `ChatImageThumbnail` decoded an attached picture with
  `NSImage(data:)`: a 31 MB bitmap per 3456×2234 screenshot behind a 96 pt tile, about 250 MB for
  the screenshot chat. `ChatImageDownsampler` makes an ImageIO thumbnail whose short edge fills
  the tile at the screen's scale, one at a time on a serial queue that drains per item. Nothing
  else reads the tile: a request still sends the original bytes, and a file's Quick Look and Open
  read the file itself.

- **2. The chat goes when the window leaves it.** On a switch, the old chat outlived the new
  one: SwiftUI kept the composer's ⌘↵ Send Now action from the first render, so its
  `AIChatState`, with every message and attached picture, stayed alive behind a keyboard-shortcut
  binding (`leaks --traceTree` on a memory graph). The action now reads the window's chat when
  it runs. And AppKit keeps a removed `NSTextView` for seconds, in a deferred drag-type block, so
  a left chat's text views, attributed strings, tables and code headers overlapped the next chat's;
  `ChatSelectableTextView` now drops its text and headers as it leaves the window and renders
  again if it ever comes back. On close, `ChatWindowRelease` (from `ddef6f46`) keeps only an
  idle, saved chat's id, with no draft, staged file or tool picks, and `showWindow` reloads it
  before the open policy, so the window reopens on the same chat. With `CHAT_MEMORY_CENSUS=1`
  every switch leaves the counts of the chat it shows, and nothing of the one before:
  `AIChatState` stays at 2 (Quick AI and the window) where it was 3, code headers read 40, 0, 96,
  0, 0, 20, 40, 40 for the chats in turn, `NSTextTableBlock` 1,080, 0, 2,688, 0, 0, 0, 1,080, 1,080,
  and after closing both are 0. Only empty text-view shells linger until AppKit lets them go.

| Cycle 2, MB, before → after | Peak | Highest open | After closing | Malloc after closing |
| --- | ---: | ---: | ---: | ---: |
| 1. Tiles | 733 → 456 | 686 → 378 | 189 → 212 | 84 → 92 |
| 2. Release | 502 → 391 | 449 → 353 | 244 → 182 | 91 → 32 |

Scrolling, two passes each way, ms (interval p50 / p95 / max; busy p50 / p95):

| Before → after | Long replies interval | busy | Agent run interval | busy |
| --- | --- | --- | --- | --- |
| 1. Tiles | 16.7 / 16.7 / 25–33 → 16.7 / 16.7 / 31–42 | 11–14 / 15 → 11 / 15–16 | 37–39 / 42–51 / 52–67 → 38 / 46–50 / 56–68 | 36–37 / 41–49 → 37–38 / 43–48 |
| 2. Release | 8–25 / 28–30 / 37–50 → 8–25 / 27–30 / 33–52 | 5–24 / 27–29 → 5–24 / 26–28 | 41–61 / 56–70 / 77–99 → 32–62 / 37–76 / 56–833 | 39–60 / 54–67 → 31–60 / 36–74 |

Step 2 ran twice, four passes a chat; its 833 ms is one frame of one pass, and its other passes
fall inside the spread of the tree before it. From step 2 on, under the render, a chat's first
pass held 8.3 ms frames and the later ones about 25 ms, in both trees alike.

## Manual sweep

- Create two folders: each is named in place and gets its own colour. Rename one from its menu and
  by Folder Settings…; pick a colour and an icon there and see the row change as you click.
- Drag a chat onto a folder, then onto Today: it moves and comes back. Pin a filed chat: it shows in
  Pinned only. ⌃⌘M on the open chat lists the folders and Recent, with a check on the current one.
- Give a folder instructions ("Answer in French") and ask a filed chat something: the answer
  follows them; a chat in Recent does not. With an agent set, New Chat in Folder starts on it.
- Delete a folder: the dialog says its chats stay, and they are back in Recent.
- Quit and relaunch: folders, colours, icons, folding and filing are as they were. Delete
  `ai-chat-workspace.json`: every chat is back in Recent and nothing else changed.
- Turn AI off and on: the folders come back with the history.
- ⇧⌘I, the toolbar button, the chip and ✕ each show or hide Chat Settings; close and reopen the
  window and it is as you left it. Narrow the window: the settings fold away first, then return.
- In Chat Settings switch the model, effort and agent: the subtitle and the chip follow, and the
  next reply uses them. Rename the chat in Title: the sidebar row follows.
- Set Creativity to None on an API model and ask twice: answers match closely; Model Default sends
  no temperature. On a Codex, Claude CLI or Gemini model the control is disabled.
- Write Additional Instructions ("Reply in one sentence"): the next reply obeys, another chat does
  not, and they survive a relaunch.
- In light and dark: folders, headers, the selected row, the user bubble, tool glyphs, a Swift and a
  JSON code block's language pills and the composer's caret all take their colours, and switching
  the system appearance repaints them without reopening the window.
- Archive a chat from its menu: it moves to Archived; Move to Folder brings it back. Set Archive
  inactive chats to a week with a chat untouched for longer: reopening the window archives it, a
  pinned or open one stays.
- Delete a chat: it is in Recently Deleted at once, gone from Quick AI's Chat History and ⌃⇥, and
  restores with its agent, folder and instructions. Delete Permanently… asks first.
- Hold ⌘: the first ten rows show their digits; ⌘3 opens the third. Fold a folder: its chats lose
  theirs.
- In an empty composer press ↑: the last question returns, outlined, with the banner; ↑ again
  steps back, ↓ forward, Esc restores what you had typed. Edit and send: the old question and its
  replies are gone, here and after a relaunch.
- Paste a question of thirty lines: it shows ten and Show more. Branch from a reply: a new chat
  "… (Branch)" opens with the history up to it.
- ⌥⌘T keeps the window above another app's; relaunch and it still does. With Notify on, ask a
  question and switch to another app: a banner names the chat and a click opens it.
- Turn a server off under Tools: the next turn cannot call it. With a reply that reported usage,
  Context shows its tokens, the chat's total and, where the route reports it, its cost.
