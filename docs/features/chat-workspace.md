# Chat workspace

AI Chat's window, reorganised the way Raycast's AI Chat is: folders in the sidebar above Recent.
The feature is this fork's, in `Features/ChatWorkspace/`, plus marked lines in
`AIChatCoordinator` (the split view it shows, instructions, history load), `AIChatWindowChrome`
(its chords), `ChatHistoryStore`, `ChatSession`, `AIChatState`, `AgentCoordinator` and `AppCore`.
Upstream's `AIChatSidebarView` and `AIChatSplitViewController` stay in the tree, unused, so a merge
that touches them stays mechanical.

## Invariants

- **One small document beside the history, and nothing about a chat is lost by reading it.**
  `ChatWorkspaceStore` keeps `ai-chat-workspace.json` next to `ai-chats.sqlite3` in the bundle's
  Application Support folder. It holds the folders, in order, and an entry per chat that has
  something to say: its folder. `ChatWorkspace(data:)` keeps whatever parses — a folder without an
  id or name, a chat key that is not a UUID or a date that is not a number is dropped alone, never
  the file — and every field it does not know, at the top, in a folder or in a chat's entry, is
  written back as it came (`unknown`). A missing or unreadable file is an empty workspace, so a
  history from before folders loads unchanged. The file is written only when something changes, by
  an atomic write, and travels in no backup, as the chats it describes do not.
- **Off means fully off.** The document is read just before the history loads, when AI is on
  (`ChatWorkspaceCoordinator.prepare`), and leaves memory with it (`close`). Nothing runs on a
  timer: stale entries are pruned only as the history loads and as the window opens (`tidy`).
- **A chat is listed once.** `ChatSidebarLayout` puts a pinned chat in Pinned wherever it is filed,
  an unpinned one in its folder, and the rest in Recent by day. Filing a chat unpins it, as dropping
  it on a folder does; dropping one on a day header takes it back to Recent.
- **Deleting a folder never deletes a chat.** `ChatWorkspace.deleteFolder` moves its chats back to
  Recent and keeps their own settings; the confirmation says so.
- **A folder is organisational, and optionally a project.** It may carry instructions and an agent.
  Its instructions go into every chat filed in it, after Redcast's preamble and the system prompt
  and before the chat's own (`ChatInstructions.compose`), so upstream's rule that the user's text
  follows the preamble holds and a cached prompt prefix is the same for every chat. Its agent is
  the one a chat started in the folder begins on (New Chat in Folder), bound like a pick in the
  composer, so the working directory is the agent's: a folder adds no second one. ACP agents brief
  their own sessions and are not sent these instructions.

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
