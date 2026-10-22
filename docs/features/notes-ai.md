# Notes and AI

Tinycast's [Notes](notes.md) reach AI Chat in two ways. **Attach Note…** in the composer's **+** menu,
or `@note` typed into the draft, opens a searchable picker, and the note you pick rides the next
message as a text file. And an [agent](agents.md) given the **Notes** tools can search and read your
notes, and add reports and summaries to them. Both are this fork's, kept to `Features/NotesAI/` plus
the few lines that wire it in: one lazy coordinator on `AppCore`, one accessor on `AIChatCoordinator`,
the menu item and modifier in `AIChatDetailView`, `NotesStore.amendDraft`, and the agent registry.

## Invariants

- **Off with Notes.** With `notesEnabled` off there is no menu item, `@note` is plain text, the agent
  registry offers no Notes provider and a call already offered answers that Notes is turned off.
  Nothing lists or creates the Notes folder until one of these is used with Notes on.
- **Nothing resident.** `NotesAICoordinator` holds a few references and does no IO until the picker
  opens. The picker's `NotePickerModel` exists only while it is shown, lists the folder once and
  reads bodies only while a query is typed, off-main, a superseded query cancelling its reads. The
  provider is built per agent turn. No timer, no watcher, no setting, no settings-file key, no backup
  field.
- **Attaching is a pick, refused over 32 KB.** A note is staged through `AIChatCoordinator.stage` as
  `<title>.md`, so the chip, removal, the attachment budget, chat history and an ACP agent's embedded
  resource behave as for any text file. A note over `AIAttachmentBudget.maxInlinedTextBytes` is
  refused with the text-file message, never cut. A chat cleared while the note loads drops it with the
  "still loading" message.
- **The picker never touches the Notes switcher.** It searches through its own `NotesRepository`
  value, so an open switcher's query and results are unaffected. It flushes the open draft first; a
  draft still unsaved after that attaches as the editor shows it, and any other note is read from
  its file, which a hidden window's clean draft may lag.
- **`@note` is a trigger, not syntax.** Exactly one typed space after `@note` at the end of the draft,
  at a word boundary, removes the token and opens the picker; a paste or any other edit never does,
  and Esc or a click away puts `@note ` back. At the draft's start an MCP server slugged `note` keeps
  the token as its address.
- **The tools are off per agent until ticked.** `AgentToolKind.notes` is not in
  `AgentToolKind.defaults`, so no agent has it until its editor's Notes box is ticked, and only an
  agent on the chat's model (`runtime == nil`) runs Tinycast's tools at all. `agents.json` carries
  the family and is in no backup and no settings file.
- **Reading is personal, adding always asks.** `notes_search` and `notes_read` are
  `AgentToolRisk.personal` and do not ask. `notes_append` is `.change`, and `AgentConsentPolicy` gives
  `(notes, change)` the rule ask whatever the agent's Changes rule says: note text can carry an
  injected prompt, so no rule makes an addition silent. It is never offered to a read-only agent, is
  refused when nobody is there to ask, and Allow for This Chat records
  `AgentGrant(family: .notes, risk: .change)`, so it never covers a file write, nor a file grant an
  append.
- **A current or unsaved draft takes the append, a stale one never.** An append to the store's
  active note goes through `NotesStore.amendDraft`, which starts a new editor epoch and autosaves,
  only while the draft holds unsaved text or matches the file. A clean draft the file has moved past
  — the window hid, the file was edited — refuses, so the repository writes the file and the loaded
  store reloads it, keeping the edit. Any other note is written by the repository and a loaded store
  re-lists. Notes switched off while the dialog was up refuses the write.
- **Tool results stay under 28 KB** and say how to continue: search lists at most 30 notes with one
  line each, read pages by line with an offset to continue from. What the tools say is English, as
  every tool's is; the dialog is localized.

## Layout

| File | Holds |
| --- | --- |
| `Model/NoteTools.swift` | Tool names, limits and the definitions the model sees |
| `Model/NoteToolFormat.swift` | Which note a name means, joining appended text, snippets, rows, the output cap |
| `Model/NoteMention.swift` | The `@note ` trigger in a draft edit |
| `Model/NoteAttachmentPolicy.swift` | A note as a staged text document, or too long |
| `Service/NoteToolRunner.swift` | One call against the folder; `NoteToolConsent`; `NoteToolWriter` and its store route |
| `Service/NoteAgentTools.swift` | The `AgentToolProvider`: specs per turn, the consent dialog's wording |
| `UI/NotesAICoordinator.swift` | The picker's chat, attaching, and the provider for `AgentCoordinator.providers(for:)` |
| `UI/NotePickerModel.swift` | The picker's rows, debounced search and selection, alive while shown |
| `UI/NotePickerCard.swift` | The card over the transcript, its keys, and the `.notePicker` modifier with `@note` |

## Tools

| Tool | Family | Risk | Access | Default |
| --- | --- | --- | --- | --- |
| `notes_search` | notes | personal | any | always |
| `notes_read` | notes | personal | any | always |
| `notes_append` | notes | change | workspace, full | ask, fixed |

- `notes_search` takes `query` and `limit` (10, at most 30). It lists the folder, reads each body once
  for the match and its first matching line, ranks with the Notes switcher's own `NoteSearch`, and
  checks cancellation per note. An empty query lists the newest notes. A note is named by its title,
  with its file name when an unnamed note shows its first line instead, and dated
  `yyyy-MM-dd HH:mm` in the Mac's time zone.
- `notes_read` takes `note`, `offset` and `limit` (2,000 lines). A note is found by file name, then
  by the name the tools print for it (`<first line> (<file>.md)`, matched by its file so an edited
  first line still finds it), then title, then first line, case and accents folded; two at the
  deciding step fail with both file names, and none fails with up to five close titles.
  `notes_append` finds its note the same way.
- `notes_append` takes `note`, `text` (64 KB) and `create` (default true). Exactly one blank line
  goes before the text and the note ends in a newline. A missing note is created under its title, a
  slash turned into a dash, after the dialog names it: "Create the note “T”" or "Add to “T”", with
  the text's first 600 characters and its size.

## Manual sweep

- Notes off: the + menu has no Attach Note…, `@note ` stays text, and an agent with the Notes box
  ticked is offered no Notes tool; the editor's Notes box is disabled.
- Notes on, in AI Chat: Attach Note… lists notes newest first with relative dates; typing a word from
  a note's body finds it; ↑/↓ move, ↩ stages a chip, and the sent request carries the note inline.
- A 40 KB note is refused with the text-file message. Switching chats with the card open closes it.
  Clicking into the composer closes it.
- Type `hi @note `: the token vanishes and the picker opens; Esc puts `@note ` back. Paste
  `x @note y`: nothing opens. With an MCP server slugged `note`, `@note x` at the start stays its
  address, and mid-draft `@note ` still opens the picker.
- Edit an agent: Notes is unticked; tick it. Ask it to find and summarise a note: the transcript shows
  `Notes · notes_search` and `notes_read`, and no dialog.
- Ask for a report in Notes: the dialog reads "wants to add to a note" with the text. Don't Allow
  leaves the note as it was; Allow adds it. With that note open in the Notes window, the text appears
  in the editor, survives the next keystroke and is saved.
- Open a note in Notes and hide the window. Edit its file in another editor, then have the agent add
  to it: the file keeps the edit and the addition, and showing Notes shows both.
- Make a note in Notes without naming it. Ask the agent to find it and add to it: it reads and adds
  to that `Untitled N` note, and no note named after its first line appears.
- With Files ticked, set Changes to Always Allow: a file write runs without a dialog, an append still
  asks. Set it to Never Allow: no file write is offered, an append still asks. A read-only agent is
  never offered `notes_append`.
- Harness: `notes-ai-test` (definitions and specs, the toolset's offer and consent whatever Changes
  says, `@note`, joining, resolution and its printed names read back, search, paging and the 28 KB
  cut, append with consent, refusal, creation and limits, the open-draft route, the attachment budget,
  and `NotesStore.amendDraft` end to end, a stale clean draft and an unsaved one included).
