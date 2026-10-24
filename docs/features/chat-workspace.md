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
- **The window holds only what it shows, and its transcript goes when it closes.** The window's
  transcript is a lazy stack (`ChatTranscriptStack`). A reply's text is drawn only for the slice
  on screen (`ChatTextViewport`). An attached picture is decoded at its tile's pixels
  (`ChatImageDownsampler`), and a closed window keeps only its chat's id
  (`releaseWindowTranscript`). On macOS 27 a transient peak stays in the footprint, so each of
  these avoids the peak instead of freeing memory afterwards. See [Memory](#memory);
  `Scripts/fork/chat-memory.sh` measures it.

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

On macOS 27, malloc keeps freed small blocks dirty, and AppKit renders a layer-backed view's
drawing on the GPU in a burst. Both make a transient peak cost as much as a resident one: the
first stays in the footprint for good, and the second was a 90 MB spike on every switch. The
window therefore avoids peaks instead of freeing memory later.

- **Lazy transcript.** Upstream's eager `VStack` built every message's SwiftUI graph and
  `NSTextView` layout on every switch. A 60-message chat cost 80–115 MB of live malloc, and 167 MB
  with this fork's per-message modifiers. In the window, `ChatTranscriptStack` builds the
  messages near the viewport only; Quick AI keeps the eager stack. Find scrolls to the match's
  message by id first (`ChatTranscriptReveal`), so the anchor exists before it is asked for.
- **Text drawn per slice, on the CPU.** A `ChatSelectableTextView` has no backing of its own
  (`wantsUpdateLayer`, an empty `updateLayer`). Its `ChatTextViewport` subview covers the visible
  part of the text plus 200 pt each way and follows scrolls of the enclosing clip view. It draws
  that slice into an `IOSurface` that becomes the layer's contents. AppKit's own path records a
  display list and rasterises it on the GPU: footprint rose by about 90 MB for a second or two on
  each switch, even with backings no taller than the screen. Drawing the same text into a bitmap
  removed the spike. Snapshots and drag images still call the text view's own `draw(_:)`.
- **Thumbnails at their size.** `ChatImageThumbnail` decoded the whole picture with
  `NSImage(data:)`, which cost 24 MB per 2960×2000 screenshot behind a 96 pt tile.
  `ChatImageDownsampler` makes an ImageIO thumbnail whose short edge fills the tile at the screen's
  scale. Decodes run one at a time on a serial queue, so at most one full decode is ever in flight.
- **A closed window releases its chat.** On `willClose`, an idle, saved chat with no draft, nothing
  staged and its tools untouched is replaced by an empty state that remembers only its id.
  `showWindow` reloads it from history before the open policy runs, so the window still reopens on
  the chat it showed. New Chat, opening another chat, Quick AI's ⌘J, AI off and a deletion all clear
  the remembered id first.
- The edited-question outline applies to questions only, so a reply carries no editing overlays.

Measured with `Scripts/fork/chat-memory.sh` (Release-like `-O`, macOS 27, on screen). The fixture
is 40 chats, four of 60 messages each with 70-line code blocks, tables, math, tool rows, sources,
file links, long reasoning and 2960×2000 screenshots. Each cycle opens the window, switches five
chats, pages up through the screenshots chat, opens and closes Chat Settings, and closes the
window. Idle is 11 MB of footprint and 2.5 MB of live malloc; the harness's idle has no palette or
launcher, so it is about 20 MB below the app's.

| Cycle 2, MB | a8e1601e | 60cd8723 (before) | after |
| --- | ---: | ---: | ---: |
| Footprint peak, open to close | 442 | 489 | 95 |
| Highest footprint while open | 398 | 450 | 88 |
| Live malloc peak | 148 | 209 | 42 |
| Footprint 4 s after closing | 134 | 200 | 67 |
| Live malloc after closing | 37.8 | 44.5 | 20.1 |

Per step, as footprint now / its peak since the last step, then live malloc (cycle 2; a8e1601e has
no Chat Settings):

| Step | a8e1601e | 60cd8723 | after |
| --- | ---: | ---: | ---: |
| Idle | 11 / 11, 2 | 11 / 11, 2 | 11 / 11, 3 |
| Open on a long chat | 214 / 219, 82 | 244 / 343, 119 | 87 / 87, 34 |
| A short chat | 195 / 285, 48 | 223 / 318, 70 | 82 / 88, 34 |
| A long chat | 319 / 324, 98 | 371 / 377, 151 | 88 / 95, 37 |
| A short chat | 201 / 320, 52 | 223 / 372, 74 | 84 / 90, 35 |
| The math chat | 315 / 324, 102 | 348 / 355, 154 | 80 / 85, 36 |
| The screenshot chat | 398 / 416, 106 | 440 / 450, 164 | 88 / 95, 38 |
| Paged up to its start | 303 / 442, 122 | 350 / 489, 175 | 78 / 94, 36 |
| Chat Settings open, closed | — | 450 / 462, 162 | 80 / 81, 39 |
| Window closed | 134 / 303, 38 | 200 / 450, 44 | 67 / 80, 20 |

Each fix on its own, from the runs that found it (cycle 2 or later): the lazy stack alone brought
the switches to 80–100 MB, but they still spiked to 180–210 MB; slices drawn through AppKit kept the
spike; slices drawn on the CPU brought the peak to about 90 MB; thumbnails and the release on close
each moved a few MB with this fixture, whose screenshots compress to well under a real one's size.
Paging up the 60-message chat delays the main thread by 2 ms median and 3 ms at worst, against
16–69 ms at worst before, when the eager stack had already built everything at a far higher cost.

Cycles 1–3 settle at 66–68 MB after closing, with no growth across cycles. ICU's `DecimalFormat`
instances stay at 5. CoreSVG's trees stay at about 4,600 `SVGAttribute`, or 4,800 once a later
cycle draws one more symbol. They are CoreUI's cache of the SF Symbols already drawn, parsed once
per symbol, not once per render.

What remains, and why the targets are not fully met:

- **Peak: idle + 77–84 MB, against a target of idle + 60.** About 40 MB is live malloc for the
  window itself: the sidebar's 40 rows, the visible messages, the toolbar, the composer and the
  hidden Chat Settings tree. The rest is CoreAnimation and the slice surfaces (6–10 MB), the
  screenshot tiles, and malloc's own regions.
- **After closing: idle + 54–56 MB, against a target of idle + 15.** About 16 MB is live, and most of
  it is one-time runtime state that the real app has mostly paid already at idle: Swift type
  metadata (3.4 MB), Objective-C method caches (1.6 MB), SwiftUI, AppKit and CoreText caches,
  and CoreUI's symbol trees (1.3 MB). The other ~35 MB is malloc-small pages, freed after the
  window's ~40 MB live peak but kept dirty by macOS 27, and no API returns them
  (`malloc_zone_pressure_relief` included). The only way left to lower it is a smaller peak.
- Settings, measured the same way (`CHAT_MEMORY_PANES=1`), is the next offender, and it is not
  this window's: with Shortcuts and then Backup open, the footprint is 99–122 MB from an idle of
  11, Backup spikes about 100 MB more, and closing leaves 96–112 MB, higher after the second visit
  than after the first. Settings also holds most of the CoreSVG trees, about 13,000
  `SVGAttribute`, which stay flat once each pane has been seen. `DecimalFormat` stays at 3–6 there
  as well, so the hundreds seen in the app come from something neither harness opens.

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
- In a long chat with code, tables, math and a screenshot: switching opens at the latest message;
  paging up draws each message as it arrives, code boxes and tables included; a selection drags
  across paragraphs and copies; ⌘F finds a word in an early message and scrolls to it; the
  screenshot's tile is sharp. Close the window and reopen it: the same chat is back. Activity
  Monitor's Memory for Redcast stays near its value before the window opened, and does not jump
  by 100 MB on a switch.
- ⌥⌘T keeps the window above another app's; relaunch and it still does. With Notify on, ask a
  question and switch to another app: a banner names the chat and a click opens it.
- Turn a server off under Tools: the next turn cannot call it. With a reply that reported usage,
  Context shows its tokens, the chat's total and, where the route reports it, its cost.
