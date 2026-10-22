# Notes and AI

An [agent](agents.md) given the **Notes** tools can search and read your Tinycast [Notes](notes.md),
and add reports and summaries to them. This is the fork's, kept to `Features/NotesAI/` plus the few
lines that wire it in: one lazy coordinator on `AppCore`, `NotesStore.amendDraft`, and one line in
the agent registry.

## Invariants

- **Off with Notes.** With `notesEnabled` off the agent registry offers no Notes provider, and a call
  already offered answers that Notes is turned off. Nothing lists or creates the Notes folder until a
  Notes tool runs with Notes on.
- **Nothing resident.** `NotesAICoordinator` holds a few references and does no IO; the provider is
  built per agent turn. No timer, no watcher, no setting, no settings-file key, no backup field.
- **The tools are off per agent until ticked.** `AgentToolKind.notes` is not in
  `AgentToolKind.defaults`, so no agent has it until its editor's Notes box is ticked, and only an
  agent on the chat's model (`runtime == nil`) runs Tinycast's tools at all. `agents.json` carries
  the family and is in no backup and no settings file.
- **Reading is personal, adding is a change.** `notes_search` and `notes_read` are
  `AgentToolRisk.personal` and do not ask; `notes_append` is `.change` under the agent's Changes rule,
  so it asks by default, is never offered to a read-only agent or under Never Allow, is refused when
  nobody is there to ask, and its description says which. Allow for This Chat records
  `AgentGrant(family: .notes, risk: .change)`, so it never covers a file write.
- **The open note is amended through the store, never on disk.** `NotesStore` is the only writer while
  a note is open, so an append to the active note goes through `NotesStore.amendDraft`, which starts a
  new editor epoch and autosaves; any other note is written by the repository and a loaded store
  re-lists. Notes switched off while the dialog was up refuses the write.
- **Tool results stay under 28 KB** and say how to continue: search lists at most 30 notes with one
  line each, read pages by line with an offset to continue from. What the tools say is English, as
  every tool's is; the dialog is localized.

## Layout

| File | Holds |
| --- | --- |
| `Model/NoteTools.swift` | Tool names, limits and the definitions the model sees |
| `Model/NoteToolFormat.swift` | Which note a name means, joining appended text, snippets, rows, the output cap |
| `Service/NoteToolRunner.swift` | One call against the folder; `NoteToolConsent`; `NoteToolWriter` and its store route |
| `Service/NoteAgentTools.swift` | The `AgentToolProvider`: specs per turn, the consent dialog's wording |
| `UI/NotesAICoordinator.swift` | The provider for `AgentCoordinator.providers(for:)` |

## Tools

| Tool | Family | Risk | Access | Default |
| --- | --- | --- | --- | --- |
| `notes_search` | notes | personal | any | always |
| `notes_read` | notes | personal | any | always |
| `notes_append` | notes | change | workspace, full | ask (Changes) |

- `notes_search` takes `query` and `limit` (10, at most 30). It lists the folder, reads each body once
  for the match and its first matching line, ranks with the Notes switcher's own `NoteSearch`, and
  checks cancellation per note. An empty query lists the newest notes. A note is named by its title,
  with its file name when an unnamed note shows its first line instead, and dated
  `yyyy-MM-dd HH:mm` in the Mac's time zone.
- `notes_read` takes `note`, `offset` and `limit` (2,000 lines). A note is found by file name, then
  title, then first line, case and accents folded; two at the deciding step fail with both file names,
  and none fails with up to five close titles.
- `notes_append` takes `note`, `text` (64 KB) and `create` (default true). Exactly one blank line
  goes before the text and the note ends in a newline. A missing note is created under its title, a
  slash turned into a dash, after the dialog names it: "Create the note “T”" or "Add to “T”", with
  the text's first 600 characters and its size.

## Manual sweep

- Notes off: an agent with the Notes box ticked is offered no Notes tool; the editor's Notes box is
  disabled.
- Edit an agent: Notes is unticked; tick it. Ask it to find and summarise a note: the transcript shows
  `Notes · notes_search` and `notes_read`, and no dialog.
- Ask for a report in Notes: the dialog reads "wants to add to a note" with the text. Don't Allow
  leaves the note as it was; Allow adds it. With that note open in the Notes window, the text appears
  in the editor, survives the next keystroke and is saved.
- Set Changes to Always Allow: the append runs without a dialog. A read-only agent is never offered
  `notes_append`.
- Harness: `notes-ai-test` (definitions and specs, the toolset's offer and consent, joining,
  resolution, search, paging and the 28 KB cut, append with consent, refusal, creation and limits, the
  open-draft route, and `NotesStore.amendDraft` end to end).
