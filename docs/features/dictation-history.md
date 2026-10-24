# Dictation History

**Dictation History** keeps the text of every finished dictation, on-device or in the cloud, and,
once switched on, of every Ask by Voice question and voice edit, and lists it in a launcher command:
newest first, searched as you type, previewed in full, and pasted again into the app in front with
↵. A dictation whose transcription fails is listed too, with why, and its recording is kept on disk
for a while so ⌘K can [retry it](#failed-dictations-and-retry) on the same or another model. It is
the fork's take on Raycast's dictation history, kept to `Features/DictationHistory/` plus the
`Fork:`-marked lines listed under [Upstream touches](#upstream-touches). A dictation that succeeds
keeps no audio: its recording stays where [Dictation](dictation.md) and [Voice AI](voice-ai.md)
leave it, in memory until it is transcribed.

## Invariants

- **Text once the text is final; audio only for a failure.** An entry is written when a
  dictation's text is known, whether or not its paste then lands: the text typed (live chunks
  included), the engine's own transcript when a mode's second request rewrote it, the mode's name,
  the engine and model, the app in front (name and bundle id), the date and the recording's length.
  A transcription that fails, on device or in the cloud, writes an entry with no text and the
  error's first line (at most 120 characters), and keeps its recording; a recording with no speech
  (`VoiceAudio.speechRange`) and a cancelled one leave nothing.
- **Kept recordings are few, short-lived and never travel.** Only a failed dictation's recording is
  kept: the speech `VoiceAudio.prepared` trims and encodes, a 16 kHz mono WAV named by the date's
  seconds and the entry's id, in `dictation-failed-audio/` in the bundle id's Application Support
  folder, which is marked excluded from backups (Time Machine). Every write trims the folder to the
  newest **20** recordings, at most **7 days** old (or Keep history's span when that is shorter)
  and **100 MB** in all, which ten five-minute recordings would fill. A shorter Keep history trims it
  at once, Off and Clear History remove the folder, Delete Entry removes its recording, a retry that
  transcribes removes it, and **Keep failed recordings** off removes them all and keeps none; a
  folder left with none of them is removed. The screen lists the folder only when an entry failed.
- **Ask by Voice and voice edits only when asked for.** An answer can quote the window that was
  read, and an edit's result is the reader's own selected text rather than speech, so **Include Ask
  by Voice and voice edits** is off by default and an update never starts keeping them. On, an Ask
  by Voice reply is kept with its transcribed question, and a voice edit with its instruction,
  marked by kind; switching it off stops new ones and leaves those kept to age out or be deleted.
  An agent's spoken request is never kept, since its run is already a chat. Ask by Voice's own
  footer says which of the two is true.
- **Nothing at launch, no resident work.** `AppCore.start()` only shows or hides the command, from
  one `UserDefaults` read; the file is first touched by a finished or failed dictation, by opening
  the screen or by a change to Keep history. There is no timer, watcher, cache or process: a trim
  happens on a write or an open.
- **Written off-main, in order.** Every append, delete, trim, clear and retry result runs on a
  detached utility task that waits for the one before it, so a Clear issued after a dictation lands
  after it, under one `Mutex` in `DictationHistoryFile` and one in `DictationRecordingFolder`. A
  failed write never touches the dictation; the screen loads, and a retry reads its recording, only
  after the writes already queued.
- **Loaded when the screen opens, freed when it closes.** `DictationHistoryIndex` reads and folds
  the file off-main on open, and `close()` empties it from the screen's `onDisappear`, which also
  cancels any retry still running. A palette hidden over the screen keeps it until the pop to root,
  exactly as Agent Sessions does. A recording is read only for the retry that needs it.
- **Bounded by Keep history.** Off, 1, 7, 30 (the default) or 90 days, or Forever. An append reads
  the file's first 32 bytes and, once that oldest line is more than an hour past the span, rewrites
  the file atomically without what aged out; an open drops it too, so nothing older is ever shown.
  A shorter span applies to the file at once, and Off removes it and records nothing. A file left
  with no line is removed.
- **Clear is asked first.** ⌃⇧X, the ⌘K row and Settings' **Clear…** all reach one coordinator
  method that asks through Tinycast's own dialog before the file goes. **Delete Entry** (⌃X) is not
  asked, as in Clipboard History.
- **Never in a backup, never in settings.json.** The history is private text, and the kept
  recordings private audio, on this Mac: no `BackupCategory` carries either, and its three keys are
  excluded from settings backups and have no settings-file key: `dictationHistoryRetention`, since
  an import must never arrive carrying an instruction to delete transcripts,
  `dictationHistoryVoiceReplies`, since one must never start writing answers and edited text to
  disk, and `dictationHistoryFailedRecordings`, since one must never start keeping audio or delete
  what is kept.
- **The line format reads both ways.** `dictation-history.jsonl` in the bundle id's Application
  Support folder: per line the date's whole seconds, a tab, then JSON with sorted keys, which
  escapes every newline a transcript holds. A reader ignores keys it does not know, reads a missing
  one as none, an unknown kind as a dictation and an unknown engine as none; a line without a date,
  an id or a text is skipped. Rewrites keep every dated line byte for byte, so a later build's fields
  survive an older build's trim, and a line a crash cut short is dropped by the next append rather
  than ended. A failure adds `failure` and, for a cloud mode, `modeID`, with an empty `text`, so the
  build before failures reads it as an empty dictation; a retry rewrites only that line, in place.
- **A retry is a gesture, and it never types.** Retry and Retry with… are the only things that read
  a kept recording or send it anywhere: the cloud only on that press, to a route the reader picked,
  and to a connection other than Cloud transcription's consented one only after a dialog naming it
  and the model. The result becomes the entry's text, with no paste; ↵ and ⌘C then act on it as on
  any entry.
- **↵ types like a snippet.** Paste goes through `TextInjector` to the caret the palette covered,
  an AI Chat composer included, borrowing the clipboard and giving it back. ⌘C and ⌘↵ copy unmarked,
  so the copy joins Clipboard History like any other; ⇧⌘C copies the raw transcript or the request,
  and the ⌘K row is named for whichever it is.

## Layout

| File | Holds |
| --- | --- |
| `Model/DictationHistoryEntry.swift` | One entry, its line format both ways, and reading, trimming and deleting a file's bytes |
| `Model/DictationHistoryRetention.swift` | Keep history's spans, their cutoffs and titles |
| `Model/DictationHistoryQuery.swift` | Folded search keys and the every-word filter |
| `Model/DictationKeptRecording.swift` | A kept recording's name, its bounds and trim, and its WAV read back as samples |
| `Model/DictationRetry.swift` | One retry from samples to entry, what it tried and heard, and the retries in flight |
| `Service/DictationHistoryFile.swift` | The file: the locked append and its trim, the load, delete, trim, clear and a retry's rewrite |
| `Service/DictationRecordingFolder.swift` | `dictation-failed-audio/`: keep and trim, list, read, delete, clear |
| `Settings/DictationHistorySettings.swift` | The fork's own store for Keep history and its two switches |
| `Settings/DictationHistorySection.swift` | The Dictation pane's History section: Keep history, the two switches, the command's row, Clear… |
| `UI/DictationHistoryCoordinator.swift` | The action surface: recording, failures, the screen, retry, paste, copy, delete, clear, ⌘C |
| `UI/DictationHistoryIndex.swift` | The loaded entries, their keys, the kept recordings and retries while the screen is open |
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

A transcription that throws hands its recording, the error and the target to a `failed` closure
with a default, before the capsule closes; a cancelled one, whose session token has moved on, never
reaches it, and `recordFailure` drops a `CancellationError` or cancelled request too. The entry
names the engine Dictation used, the consented route's model or the on-device model, and the mode
the capsule showed; a model's `[[NO_SPEECH]]` over audio the gate found speech in reads "No speech
was heard in the recording." Off the main actor the recording is gated and encoded, written
(while **Keep failed recordings** is on), then the line appended, and the open screen gets the entry
after both.

`VoiceAskCoordinator` takes a `history` closure with a default and hands over a reply once it is
whole, however it is then delivered (typed, shown, replaced or shown instead): the answer or the edit
as the text, the transcribed question or instruction as the transcript, its route's model, the app it
was asked in, and no length. `DictationHistoryCoordinator.record` drops it unless the voice-replies
switch is on (`Kind.isKept(voiceReplies:)`).

## Failed dictations and Retry

A failed entry's row reads "Dictation failed" with a badged waveform and the reason, or
"Retrying…", ahead of the app and the mode; its preview shows the reason and whether the recording
is still kept. Its ↵ is **Retry** and its ⌘K holds Retry, a **Retry with** section, Delete Entry
and Delete All; ⌘C and ⇧⌘C do nothing for it.

- **Retry** uses what a dictation would now: the consented Cloud transcription route while that
  switch is on (none is "Choose a model…" as the new reason), else the on-device model.
- **Retry with** lists, per enabled audio-capable connection (`VoiceRoutePolicy.retryChoices`), the
  saved Dictation and Ask by Voice models on it, its Dictation and Ask presets, and for a server
  without presets every model it lists, then each on-device model that is installed; the current
  one is checked. A connection other than Cloud transcription's consented one asks first ("Send This
  Recording to …?"); a declined dialog leaves the entry as it was. The pick never changes a setting.

A retry runs once per entry at a time (`DictationRetryState`). It reads the recording off-main and
goes through `VoiceCloudTranscriber.retranscribe`, the live request with the current cleanup,
languages and words to spell, the app by name alone while Use the app in front is not Off (its
title and picture were never kept), and the mode the cloud failed with, or for a failure on this
Mac the app's own, as a dictation would; or through `DictationModelStore.transcribe` with the
on-device model and language. Text comes back trimmed: the entry becomes a normal one at its first
date, app and length, named for the engine and model that heard it, and its recording is deleted.
Anything else keeps it failed with the new reason and what was tried. Closing the screen, deleting
the entry or clearing cancels the retry, and its result lands nowhere.

## The screen

A list on the left grouped by Today, Yesterday, This Week, This Month and Earlier, each row the
entry's first line, its kind for an Ask or an edit, the app and the mode, and the time; the preview
on the right shows the whole text, the raw transcript or the request when there is one, and
Type, Mode, Application, Engine, Model, Duration and Recorded. Search matches every typed word
anywhere in the text, the transcript, the app or the mode, folding case, accents and width (ё finds
е), and keeps the newest-first order.

| Key | Action |
| --- | --- |
| ↵ | Paste to the app in front; Retry for a failed entry |
| ⌘C, ⌘↵ | Copy to Clipboard |
| ⇧⌘C | Copy Raw Transcript, or Copy Request for an Ask or an edit, when the entry has one |
| ⌘J | [Send to AI](send-to-ai.md): Quick AI with the text quoted, or attached when long; an Ask with its question |
| ⌃X, ⌘⌫ | Delete Entry |
| ⌃⇧X | Delete All Entries, after the dialog |

⌘K adds Send to AI and Send to AI Chat (a new chat) to every entry but a failed one, which has no
text yet.

⌘C reaches the coordinator from the panel's command shortcut hook only while the first responder is
a field editor (`isFieldEditor`; SwiftUI's is not the window's `fieldEditor(_:for:)`) with nothing
selected. Selected query text, and text selected in the preview, whose selectable `Text` is not an
`NSTextView`, still copy as text. The command is found by its name in the interface's language and
in English, and by "transcripts" and "voice history" in both; its alias, launcher checkbox and
global shortcut sit in the History section, since the Dictation pane owns it. It is listed while
Keep history is not Off and Dictation is on, or Ask by Voice is on with its replies kept.

## Upstream touches

Each marked with a one-line `Fork:` comment: the `dictationHistory` `CommandID` (its case, name and
symbol, and the `keywords` it is found by), `CommandCatalog.makeEntry` passing those keywords, the
Dictation pane's `ownedCommands`, `LauncherCoordinator.runCommand`, the `PaletteMode` case with its
symbol and placeholder, `RootPaletteView`'s screen, the ⌘C branch in `PaletteWindowController`'s
command shortcut hook, `DictationCoordinator`'s `finished` and `failed` closures, their three calls
and the recording's sample count, `DictationSettingsView`'s section, `AppCore`'s coordinator, its
three closures, its `applyEnabled` at start and the two tracks, the three `AppSettingsKey`s, their
reasons in `SettingsBackupCoverage`, the `SettingsAnchor` and the `SettingsSearchCatalog` entries.

## Manual sweep

- Dictate into TextEdit with the on-device model, then open Dictation History: the entry is first,
  under Today, with TextEdit, On this Mac, Parakeet · Redux, its length and time. ↵ pastes it into
  TextEdit at the caret and the clipboard is what it was before.
- With Cloud transcription on and Translate to English for TextEdit, dictate in Russian: the entry
  shows the English text, the mode and the model; on a local OpenAI-compatible model it also shows
  the Raw transcript, and ⇧⌘C copies it.
- Dictate into AI Chat's composer: the entry names Redcast as the app.
- With Include Ask by Voice and voice edits off (the default), Ask by Voice a question and Edit
  Selection by Voice: neither is added, and Ask by Voice's footer says a question is kept only in AI
  Chat or an agent's run. Switch it on and repeat: both appear with their kind in the row, the answer
  or the edit as the text, the question or instruction under Request, and ⌘K offers Copy Request;
  the footer now names Dictation History.
- Stay silent, or press Escape while it transcribes: nothing is added, and
  `dictation-failed-audio/` is not created.
- With Cloud transcription on, turn Wi-Fi off and dictate a sentence into TextEdit: the HUD shows the
  network error, and Dictation History's first entry reads "Dictation failed" with that error;
  `~/Library/Application Support/<bundle id>/dictation-failed-audio/` holds one WAV, and Finder's
  Get Info, or `tmutil isexcluded`, shows the folder excluded from backups. Turn Wi-Fi on, select the
  entry and press ↵: "Retrying…", then the text appears in the preview, nothing is typed into
  TextEdit, and the WAV is gone. Press ↵ again: it pastes into TextEdit; ⌘C copies it.
- Fail one again (Wi-Fi off), then ⌘K: Retry with lists the consented route checked, the other
  presets and saved models, any local server's models and the installed on-device models. Pick an
  on-device model: it transcribes with no network. Fail another and pick a connection other than the
  consented one: a dialog names it and the model; Cancel leaves the entry failed and nothing is
  sent (a proxy shows no request).
- Fail one with a missing API key (or a disabled connection): the reason says so, and a retry after
  fixing it lands. Press Retry while one is running: nothing more starts.
- Delete a failed entry with ⌃X: its WAV goes. Fail two and Clear History: the folder goes. Set
  Keep history to Off: the folder goes and a failure then writes nothing. Turn Keep failed
  recordings off: the WAVs go, a failure is still listed, and its preview says the recording is no
  longer kept.
- Fail 21 dictations: the folder holds 20. Move the Mac's clock a week ahead and fail one more: only
  that one is left.
- Close the palette (pop to root) while a retry runs: the entry stays failed, and Activity Monitor
  shows no thread or wakeup left.
- Type "transcripts", "voice history" or "Dictation History" in the launcher, and in a Russian
  interface "расшифровки" or "история диктовки": the command is found. Bind it a shortcut in
  Settings › Dictation › History and press it.
- Search with two words from different fields (an app and a word of the text): only entries with
  both remain; "елка" finds "Ёлка".
- ⌘C with nothing selected in the search field copies the entry and closes the palette; select some
  typed text and ⌘C copies that text instead; drag over a sentence in the preview and ⌘C copies
  just that sentence, leaving the palette open.
- ⌃X deletes the entry at once; ⌃⇧X asks, and Clear History empties the list and removes
  `dictation-history.jsonl` from `~/Library/Application Support/<bundle id>/`.
- Set Keep history to 1 Day with older entries present: they leave the file at once. Off hides the
  command and removes the file; a dictation then writes nothing.
- Turn Dictation off with Ask by Voice on: the command is listed only while its replies are kept.
  Turn both off: the command is hidden; the History section still clears.
- Open and close the screen with Activity Monitor watching: memory returns to where it was once the
  palette pops to root, and no thread or wakeup stays while idle.
- Export a backup with every category: the archive holds no transcript.
- ⌘J on a short dictation: Quick AI opens with it quoted and Escape comes back to the history; ⌘K →
  Send to AI Chat on a long one opens a new chat with `Dictation.txt` staged. A failed entry offers
  neither ([Send to AI](send-to-ai.md)).

## Harness

`dictation-history-test` reads back a line with tabs, newlines, quotes and Cyrillic; holds a pinned
first-build line field for field and writes it byte for byte; reads a later build's line with an
unknown kind, engine, extra keys and a bad duration and keeps it byte for byte on a trim; skips lines
without a date, JSON, an id or a text while a rewrite keeps dated ones; caps the text and drops a
transcript equal to it; pins the retention spans and their stored values; and keeps an Ask or an
edit only with the voice-replies switch on. On a scratch folder it
appends and loads newest first, creates no file on a read, writes nothing for Off, trims on an append
only past the slack and never shows what aged out, drops on a load what aged out since the last
write and removes an emptied file, drops a cut-short last line on the next append without swallowing
it, tolerates and keeps a corrupt line in the middle, deletes one id while keeping a later build's
line, and clears. Search: every word anywhere, case, accent and ё folding, the transcript, app and
mode searched, order kept. Failures: a failed entry round trips with its mode's id, its pinned line
is written byte for byte and read by the first build's payload as an empty dictation, the reason is
one capped line, and a retry rewrites its line in place, other lines byte for byte. Recordings:
names round trip and foreign ones are ignored, the bounds (20, 7 days or a shorter history, 100 MB)
trim the oldest first, a WAV reads back as its samples and another rate or a stub does not, and on a
scratch folder a write marks it excluded from backups and trims to twenty and a week, a shorter span
trims at once, a delete takes one, Off and Clear remove the folder. Retries: one per entry, a
stranger's, a deleted entry's or a closed screen's result never lands, and with a fake transcriber a
heard recording makes a normal entry, a failure keeps it failed with the new reason and what was
tried, nothing heard and a missing recording fail, and a cancellation, before or during the
transcription, leaves the entry as it was. `dictation-field-test` checks that a failed cloud
transcription hands over its recording, error and field and still reports the error, and that a
cancelled one hands over nothing. `voice-coordinator-test` checks what the cloud engine notes (model, mode,
the rewritten transcript, nothing after silence or once the capsule closes) and that Ask by Voice
and Edit Selection by Voice record their reply with the question or instruction, and nothing for no
speech, and that a retry goes only to the route chosen, with the live prompt, the app by name and no
title or picture, the mode applied, without touching the capsule's note, that Retry with lists each
connection's models once, and that only another connection is asked for.
