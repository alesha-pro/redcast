# Send to AI

**Send to AI** (⌘J) hands the selected row of Clipboard History, Search Files (and a file row in
root search) or Dictation History to Quick AI, attached or quoted and ready for the question, the
way Quick AI's own ⌘J hands a conversation on to AI Chat. **Send to AI Chat**, in the same ⌘K
section, starts a new AI Chat chat with it instead. The feature is this fork's, in
`Features/SendToAI/` plus the `Fork:`-marked lines listed under [Upstream touches](#upstream-touches)
and two methods on the fork's own `DictationHistoryCoordinator`.

## Invariants

- **No staging of its own.** A file goes through the composer's own file path
  (`QuickAICoordinator.attachPastedFileFromLauncher`, or `AIChatCoordinator.attach(files:to:)` for a
  new chat), so the route decides with the usual refusals: an image on a model that sees none, a
  PDF on one that reads none, a type Tinycast never attaches, a file past the size cap. Text staged
  as a file goes through `stage(_:into:)`, exactly as a Screen Awareness capture does, and a quote
  is typed into the composer's draft: the palette query in Quick AI, `AIChatState.draft` in a chat,
  each appended to what is already there.
- **Quick AI opens as summoning it would.** `showStaging` and `attachPastedFileFromLauncher` apply
  Quick AI's open policy, so it resumes or starts a chat by the same rule as summoning it, and
  the screen the row came from stays behind it: Escape goes back to the list. **Send to AI Chat** is
  ⌘N's new chat (an empty one is kept, its staging with it), then the window.
- **Short text is quoted, long text is attached.** One line of at most 200 characters is quoted,
  in straight double quotes followed by a space, since Quick AI's composer is the palette's
  one-line field. Anything longer or with a line break is staged as `Clipboard.txt` or
  `Dictation.txt`, cut to the composer's 32 KB inlined-text cap on a character, with a marker.
  The names are English: they go on the wire, in the `Attached file:` header.
- **What each row sends.** A text entry, trimmed, as above; a colour entry quoted as copied, with
  its hex after it when it was written another way (`rgb(242, 61, 50) (#F23D32)`); an image entry
  its saved PNG; a file entry or a File Search result the file; a folder its path, quoted, since a
  folder is no attachment; a dictation its text as above, and an Ask by Voice entry its question
  and answer together as `Voice question.txt`. A failed dictation, a blank clip and a row with no
  file have nothing to send: ⌘J falls through and ⌘K shows no rows.
- **Only while AI is on.** With AI off neither row is listed and ⌘J does nothing.
- **Nothing resident.** No state, no observation, no launch work: the payload is built on the
  gesture or when ⌘K opens, and a clipboard file entry is looked at once then, to tell a folder
  from a file.
- **`Model/` is Foundation-only and filesystem-free.** `SendToAIPayload.make` takes the row as
  plain values (`SendToAISource`) and the cap as a parameter; `Tests/send-to-ai-test.swift` pins
  the payload for every kind of row.

## Keys

| Screen | ⌘J | ⌘K |
| --- | --- | --- |
| Clipboard History | Send to AI | Send to AI, Send to AI Chat, above Delete Entry |
| Search Files, a file row in root search | Send to AI | Send to AI, Send to AI Chat, above Move to Trash |
| Dictation History | Send to AI | Send to AI, Send to AI Chat, above Delete Entry |

⌘J was free on all three: `PaletteShortcut` resolves it to `continueInChat` everywhere, and only
Quick AI, Chat History and Agent Sessions answer it. Send to AI Chat has no chord, because a
shifted ⌘J resolves to the same token and a new one would change every screen's.

## Files

| File | Holds |
| --- | --- |
| `Model/SendToAIPayload.swift` | `SendToAISource`, and the files, notes and draft each kind of row becomes |
| `UI/SendToAIActions.swift` | the two gestures, the ⌘K rows, and each screen's row as a source |

## Upstream touches

- `ClipboardScreen.swift`: ⌘J in `perform`, and the two rows in `ClipboardActionsMenu`.
- `FileSearchScreen.swift`: ⌘J in `FileSearchActionsMenu.perform` and the two rows in its
  `content`, which root search's file rows share.

## Manual sweep

- Clipboard History, a one-line text entry, ⌘J: Quick AI opens with the text quoted in the
  composer and the caret after it; Escape comes back to the history on the same row.
- A multi-line entry: the composer is empty and a `Clipboard.txt` chip is staged; ask a question
  and the reply reads the text.
- A colour entry (`#F23D32`, then `rgb(242, 61, 50)`): the colour is quoted, the second with its hex.
- An image entry on a vision model: the image is staged with its thumbnail. On a text-only model
  the HUD says the model can't read images, and nothing is staged.
- A copied file (a PDF, then a `.zip`): the PDF is staged; the `.zip` is refused by name. A copied
  folder: its path is quoted.
- Search Files, a result, ⌘J and ⌘K → Send to AI Chat: Quick AI with the file staged; then AI
  Chat's window on a new chat with the file staged and the palette gone. A folder result quotes its
  path. A file row in root search does the same.
- Dictation History: a short dictation is quoted, a long one staged as `Dictation.txt`, an Ask by
  Voice entry (with Include Ask by Voice on) staged as `Voice question.txt`; a failed entry's ⌘K
  has no Send rows and ⌘J does nothing.
- With an unsent draft in AI Chat's empty chat, Send to AI Chat appends the quote on a new line
  and keeps the draft.
- Settings → AI off: no Send rows in any ⌘K, and ⌘J does nothing.
