# Dictation History

**Dictation History** keeps the text of every finished dictation, on-device or in the cloud, and of
every Ask by Voice question and voice edit, and lists it in a launcher command: newest first,
searched as you type, previewed in full, and pasted again into the app in front with ↵. It is the fork's take
on Raycast's dictation history, kept to `Features/DictationHistory/` plus the `Fork:`-marked lines
listed under [Upstream touches](#upstream-touches). No audio is ever kept; the recording stays where
[Dictation](dictation.md) and [Voice AI](voice-ai.md) leave it, in memory until it is transcribed.

## Invariants

- **Text only, and only once the text is final.** An entry is written when a dictation's text is
  known, whether or not its paste then lands: the text typed (live chunks included), the engine's own
  transcript when a mode's second request rewrote it, the mode's name, the engine and model, the app
  in front (name and bundle id), the date and the recording's length. An Ask by Voice reply is kept
  with its transcribed question, and a voice edit with its instruction, marked by kind; an agent's
  spoken request is not, since its run is already a chat. A recording with no speech, a cancelled one
  and one whose transcription failed leave nothing.
- **Nothing at launch, no resident work.** `AppCore.start()` only shows or hides the command, from
  one `UserDefaults` read; the file is first touched by a finished dictation, by opening the screen
  or by a change to Keep history. There is no timer, watcher, cache or process: a trim happens on a
  write or an open.
- **Written off-main, in order.** Every append, delete, trim and clear runs on a detached utility
  task that waits for the one before it, so a Clear issued after a dictation lands after it, and
  under one `Mutex` in `DictationHistoryFile`. A failed write never touches the dictation; the screen
  loads only after the writes already queued.
- **Loaded when the screen opens, freed when it closes.** `DictationHistoryIndex` reads and folds
  the file off-main on open, and `close()` empties it from the screen's `onDisappear`. A palette
  hidden over the screen keeps it until the pop to root, exactly as Agent Sessions does.
- **Bounded by Keep history.** Off, 1, 7, 30 (the default) or 90 days, or Forever. An append reads
  the file's first 32 bytes and, once that oldest line is more than an hour past the span, rewrites
  the file atomically without what aged out; an open drops it too, so nothing older is ever shown.
  A shorter span applies to the file at once, and Off removes it and records nothing. A file left
  with no line is removed.
- **Clear is asked first.** ⌃⇧X, the ⌘K row and Settings' **Clear…** all reach one coordinator
  method that asks through Tinycast's own dialog before the file goes. **Delete Entry** (⌃X) is not
  asked, as in Clipboard History.
- **Never in a backup, never in settings.json.** The history is private text on this Mac: no
  `BackupCategory` carries it, and `dictationHistoryRetention` is excluded from settings backups (an
  import must never arrive carrying an instruction to delete transcripts) and has no settings-file
  key.
- **The line format reads both ways.** `dictation-history.jsonl` in the bundle id's Application
  Support folder: per line the date's whole seconds, a tab, then JSON with sorted keys, which
  escapes every newline a transcript holds. A reader ignores keys it does not know, reads a missing
  one as none, an unknown kind as a dictation and an unknown engine as none; a line without a date,
  an id or a text is skipped. Rewrites keep every dated line byte for byte, so a later build's fields
  survive an older build's trim, and a line a crash cut short is dropped by the next append rather
  than ended.
- **↵ types like a snippet.** Paste goes through `TextInjector` to the caret the palette covered,
  an AI Chat composer included, borrowing the clipboard and giving it back. ⌘C and ⌘↵ copy unmarked,
  so the copy joins Clipboard History like any other; ⇧⌘C copies the raw transcript or the request.

## Layout

| File | Holds |
| --- | --- |
| `Model/DictationHistoryEntry.swift` | One entry, its line format both ways, and reading, trimming and deleting a file's bytes |
| `Model/DictationHistoryRetention.swift` | Keep history's spans, their cutoffs and titles |
| `Model/DictationHistoryQuery.swift` | Folded search keys and the every-word filter |
| `Service/DictationHistoryFile.swift` | The file: the locked append and its trim, the load, delete, trim and clear |
| `Settings/DictationHistorySettings.swift` | The fork's own store for Keep history |
| `Settings/DictationHistorySection.swift` | The Dictation pane's History section: Keep history, the command's row, Clear… |
| `UI/DictationHistoryCoordinator.swift` | The action surface: recording, the screen, paste, copy, delete, clear, ⌘C |
| `UI/DictationHistoryIndex.swift` | The loaded entries and their keys while the screen is open |
| `UI/DictationHistoryScreen.swift` | The palette screen and its ⌘K menu |
| `UI/DictationHistoryList.swift`, `UI/DictationHistoryPreview.swift` | The list by date and the preview with its Information block |

## Recording

`DictationCoordinator` hands each finished dictation to a `finished` closure with a default: the
final text, the engine's own transcript, the sample count and the injection target, before the
capsule closes. `VoiceCloudTranscriber` notes its last transcript, the mode it used, the model and,
when a mode took two requests, the transcript it rewrote, and forgets them when the capsule closes;
the coordinator takes them when the transcript matches, and otherwise records the on-device model
(`DictationModel.title`). A dictation into AI Chat's composer names Tinycast itself as the app. The
length is the whole recording's, to a tenth of a second. Gemini rewrites a mode in one request, so
only a mode on another model keeps a raw transcript.

`VoiceAskCoordinator` takes a `history` closure with a default and records a reply once it is whole,
however it is then delivered (typed, shown, replaced or shown instead): the answer or the edit as the
text, the transcribed question or instruction as the transcript, its route's model, the app it was
asked in, and no length.

## The screen

A list on the left grouped by Today, Yesterday, This Week, This Month and Earlier, each row the
entry's first line, its kind for an Ask or an edit, the app and the mode, and the time; the preview
on the right shows the whole text, the raw transcript or the request when there is one, and
Type, Mode, Application, Engine, Model, Duration and Recorded. Search matches every typed word
anywhere in the text, the transcript, the app or the mode, folding case, accents and width (ё finds
е), and keeps the newest-first order.

| Key | Action |
| --- | --- |
| ↵ | Paste to the app in front |
| ⌘C, ⌘↵ | Copy to Clipboard |
| ⇧⌘C | Copy Raw Transcript, when the entry has one |
| ⌃X, ⌘⌫ | Delete Entry |
| ⌃⇧X | Delete All Entries, after the dialog |

⌘C reaches the coordinator from the panel's command shortcut hook only while no query text is
selected, so selected text in the search field still copies as text. The command is found by its
name in the interface's language and in English, and by "transcripts" and "voice history" in both;
its alias, launcher checkbox and global shortcut sit in the History section, since the Dictation pane
owns it. It is listed while Keep history is not Off and Dictation or Ask by Voice is on.

## Upstream touches

Each marked with a one-line `Fork:` comment: the `dictationHistory` `CommandID` (its case, name and
symbol, and the `keywords` it is found by), `CommandCatalog.makeEntry` passing those keywords, the
Dictation pane's `ownedCommands`, `LauncherCoordinator.runCommand`, the `PaletteMode` case with its
symbol and placeholder, `RootPaletteView`'s screen, the ⌘C branch in `PaletteWindowController`'s
command shortcut hook, `DictationCoordinator`'s `finished` closure, its two calls and the
recording's sample count, `DictationSettingsView`'s section, `AppCore`'s coordinator, its two
closures, its `applyEnabled` at start and the two tracks, the `AppSettingsKey`, its reason in
`SettingsBackupCoverage`, the `SettingsAnchor` and the `SettingsSearchCatalog` entries.

## Manual sweep

- Dictate into TextEdit with the on-device model, then open Dictation History: the entry is first,
  under Today, with TextEdit, On this Mac, Parakeet · Redux, its length and time. ↵ pastes it into
  TextEdit at the caret and the clipboard is what it was before.
- With Cloud transcription on and Translate to English for TextEdit, dictate in Russian: the entry
  shows the English text, the mode and the model; on a local OpenAI-compatible model it also shows
  the Raw transcript, and ⇧⌘C copies it.
- Dictate into AI Chat's composer: the entry names Redcast as the app.
- Ask by Voice a question, then Edit Selection by Voice: both appear with their kind in the row, the
  answer or the edit as the text, and the question or instruction under Request.
- Stay silent, or press Escape while it transcribes: nothing is added.
- Type "transcripts", "voice history" or "Dictation History" in the launcher, and in a Russian
  interface "расшифровки" or "история диктовки": the command is found. Bind it a shortcut in
  Settings › Dictation › History and press it.
- Search with two words from different fields (an app and a word of the text): only entries with
  both remain; "елка" finds "Ёлка".
- ⌘C with nothing selected in the search field copies the entry and closes the palette; select some
  typed text and ⌘C copies that text instead.
- ⌃X deletes the entry at once; ⌃⇧X asks, and Clear History empties the list and removes
  `dictation-history.jsonl` from `~/Library/Application Support/<bundle id>/`.
- Set Keep history to 1 Day with older entries present: they leave the file at once. Off hides the
  command and removes the file; a dictation then writes nothing.
- Turn Dictation and Ask by Voice off: the command is hidden; the History section still clears.
- Open and close the screen with Activity Monitor watching: memory returns to where it was once the
  palette pops to root, and no thread or wakeup stays while idle.
- Export a backup with every category: the archive holds no transcript.

## Harness

`dictation-history-test` reads back a line with tabs, newlines, quotes and Cyrillic; holds a pinned
first-build line field for field and writes it byte for byte; reads a later build's line with an
unknown kind, engine, extra keys and a bad duration and keeps it byte for byte on a trim; skips lines
without a date, JSON, an id or a text while a rewrite keeps dated ones; caps the text and drops a
transcript equal to it; and pins the retention spans and their stored values. On a scratch folder it
appends and loads newest first, creates no file on a read, writes nothing for Off, trims on an append
only past the slack and never shows what aged out, drops on a load what aged out since the last
write and removes an emptied file, drops a cut-short last line on the next append without swallowing
it, tolerates and keeps a corrupt line in the middle, deletes one id while keeping a later build's
line, and clears. Search: every word anywhere, case, accent and ё folding, the transcript, app and
mode searched, order kept. `voice-coordinator-test` checks what the cloud engine notes (model, mode,
the rewritten transcript, nothing after silence or once the capsule closes) and that Ask by Voice
and Edit Selection by Voice record their reply with the question or instruction, and nothing for no
speech.
