# Backup

Export and import of Tinycast's own data as a single `.tinycast` file, plus the entry point for
importing a Raycast export. The feature lives in `Features/Backup/`.

A backup carries five independently selectable categories, ticked on export and again on import:
**Settings & Shortcuts**, **Clipboard History**, **Snippets**, **Notes** and **Launcher Learning**.

## Invariants

- **`SettingsBackup`'s mirror is hand-written, and reflection is never the fix.** `AppSettingsKey` owns
  every key `AppSettings` persists; `SettingsBackupCoverage` says which of them `SettingsData` carries,
  which are sourced from somewhere other than `UserDefaults`, and which are excluded **with a reason**.
  `settings-backup-test` fails when a key is none of those. Adding a setting means editing
  `SettingsBackupCoverage` in the same commit.
- **`snippetsEnabled` is excluded, and that is a security control.** It doubles as consent to keystroke
  listening, so an imported file must not be able to grant it. A `Mirror` or a macro is the wrong
  answer: neither can be read to check what is covered.
- **A flag that grants a capability is never carried by a backup**, whether it is excluded from
  `SettingsBackupCoverage` like `snippetsEnabled` or kept out of `AppSettings` entirely. Importing a
  config must not be able to grant something the user never granted. `FallbackStore` is the second
  case: its order and checkboxes live on their own `UserDefaults` keys precisely so an import cannot
  arm **Run Shell Command** in someone's launcher. This change adds *content*, never a capability.
- **No absolute path may enter a `.tinycast`.** A clip's `imagePath` names a file on the Mac that wrote
  it, so `BackupClipboardItem` carries a bundle-relative `imageName` instead. `backup-archive-test`
  asserts the produced file contains neither `/Users` nor `/Library` — the analogue of
  `settings-backup-test`'s `snippetsEnabled` check, and for the same reason: this file gets sent to
  people.
- **The file carries a format version and a reader accepts only its own.** That is a guard, not a
  migration: the comparison is `==`, so an older and a newer file fail identically and by the same
  statement. Writing it any other way is the first line of a migration, and the project has none.
  The fork's `full/` tree leaves that number at 1, so an upstream build still reads the categories,
  and versions its own sections apart with skip rules ([version tolerance](#version-tolerance)).
- **Upstream's categories never carry extensions, AI chat history, Keychain material or anything in
  `Caches`.** An extension is third-party code and third-party data; chat history and API keys stay on
  the Mac that had them; a cache regenerates on its own. The fork's [full backup](#full-backup-fork)
  carries the extension list, the chat history and the Keychain items under its own rules below: the
  first as a list to reinstall from, the second only when ticked, the third only sealed with a
  passphrase. Nothing ever carries `Caches`. The fork's AI usage log (`ai-usage.tsv`) is usage data
  like chat history and travels in no category either, nor does its Dictation History
  (`dictation-history.jsonl`), which is private text, nor the failed dictations' recordings it keeps
  to retry (`dictation-failed-audio/`), which is private audio and excluded from Time Machine too.
- **`BackupCategory` names every category, and its `descriptor` switch is exhaustive.** A new case
  fails to build until it names a label, a symbol, a bundle subpath and a count noun — the same
  bargain `AppEntry.Kind` makes, and why the bundle layout is never spelled out twice.

## Layout

| File | Role |
| --- | --- |
| `Model/BackupCategory.swift` | The categories and the descriptor every one of them must name |
| `Model/BackupManifest.swift` | The table of contents, the format constant and its guard |
| `Model/BackupBundle.swift` | The payload directory's layout and part-by-part encode/decode |
| `Model/BackupArchive.swift` | Directory ⇄ `.tinycast`; the only file importing `AppleArchive` |
| `Model/BackupClipboardItem.swift` | The portable clip, with no path in it |
| `Model/SettingsBackup.swift` | The settings, fixed/per-item hotkey payloads, and their `Codable` shape |
| `Model/SettingsBackupCoverage.swift` | The coverage declaration the harness checks |
| `Model/RaycastImport.swift` | The importable categories, the `Result` and its per-category trim |
| `Model/RaycastImportError.swift` | The three failures an import reports |
| `Service/BackupStaging.swift` | One scratch tree, created on init and removed on discard |
| `Service/BackupComposer.swift` | Stores → staging; `plan` on main, `write` off it |
| `Service/BackupApplier.swift` | Staging → stores, returning a per-category summary |
| `Service/BackupActions.swift` | The effectful half: file pickers, the archive calls, dialogs, the settings-file switch |
| `Service/RaycastDecoder.swift` | Container recognition, decrypt and decode |
| `Service/RaycastImportReader.swift` | Raycast → Tinycast field mapping |
| `Service/Scrypt.swift`, `Platform/Compression/Zlib.swift` | The crypto and decompression primitives |
| `Settings/BackupCategorySelection.swift` | The category checkboxes, on both halves of the pane |
| `Settings/BackupSettingsView.swift` | The pane, which also holds the [settings file](settings-file.md) switch |

## Inside the file

```
manifest.json              format, app version, createdAt, per-category counts
settings.json              SettingsBackup, exactly as it encoded before
clipboard/items.jsonl      one clip per line
clipboard/images/<uuid>.png
snippets/<name>.md         copied verbatim
notes/<name>.md            copied verbatim
learning/{ranking,emoji,calculator}.json
```

A category the user didn't tick has no key in `counts` and no files in the archive, which is how the
import picker greys a row out instead of importing nothing and saying nothing.

**Clipboard history is JSONL, everything else is JSON.** A single JSON array of 200,000 clips has to be
built in memory to encode and again to decode; a line per clip is one small encode through an open
`FileHandle` on the way out and one mapped read on the way back. Splitting on `\n` is legal precisely
because a newline inside a clip is escaped as `\n` by the encoder and can never appear raw —
`backup-archive-test` asserts the line count equals the clip count for exactly that reason.

**AppleArchive, LZFSE, and a deliberately narrow keyset.** `"TYP,PAT,DAT,MOD,MTM"` rather than
`.defaultForArchive`: no `UID`/`GID`, which would restore another Mac's numeric owner, and no `IDX`,
whose hardlink dedup would record a link to a blob outside the staged tree. `MTM` stays because the
note list sorts on modification date. LZFSE rather than LZMA because clipboard PNGs dominate the
payload and are already compressed.

**Extraction is filtered, not trusted.** `BackupArchive.open` passes an `ArchiveHeader.EntryFilter`
that returns `.skip` for any entry whose path is absolute or contains `..`, and then refuses an extract
holding a symbolic link — a link entry names no `..` at all, so the path filter passes it, and reading
through one would leave the tree the caller chose. Composing resolves a link for the same reason, so a
symlinked note travels as a file. `backup-archive-test` builds both hostile archives header-by-header
and asserts nothing escapes.

**Staging lives in `Caches`, not `temporaryDirectory`.** It has to sit on the same volume as
Application Support for a clipboard PNG to cross into the bundle as a hardlink rather than a copy.
Leaving the Settings pane discards a tree the user opened but never imported; `BackupStaging` sweeps
anything a day old on the next run, since a run killed mid-flight leaves its tree behind.

## Coverage, and why it is spelled out

`SettingsBackupCoverage` holds three tables:

- `mirrored` — each `SettingsData` field paired with the `AppSettings` key it carries.
- `externallySourced` — fields no `AppSettings` key stands behind, each saying what it reads instead.
  `launchAtLogin` comes from `LaunchAtLogin`, which owns the login item.
- `deliberatelyExcluded` — keys kept out on purpose, each with its reason as a string.

`settings-backup-test` asserts that every `AppSettingsKey` appears in exactly one table, that no field
claims a key twice, that every exclusion names a real key and carries a non-empty reason, and that each
capability-granting key — `snippetsEnabled`, `extensionsEnabled`, `extensionsAIEnabled`,
`extensionsAIGrants`, `extensionsAIHonorsModels`, `calendarEnabled`, `autoJoinMeetings`, `cameraPreview`,
`quickActionsEnabled` — is named individually as excluded. The
duplication between `AppSettings` and this file is the point: it forces a decision about every new
setting rather than defaulting it into a backup.

## Importing

Applying an import writes through `AppSettings` like any other change, so feature switches reproject into
the launcher through the normal observation path. An import reports a summary of what it applied — it is
not silent, because a settings file that quietly changes hotkeys is hostile.

Per category:

- **Settings** merge field by field, and a file carrying custom commands or their shortcuts still hits
  `confirmExecutableImport` first.
- **Clipboard** streams through `ClipboardStore.importStoredItems`, off the main actor and on its own
  connection: a restored history runs past the memory window and must never sit in memory or freeze the
  UI. A row is deduped on its text, or on the path its image takes; the blob keeps the name the bundle
  gave it, so importing one file twice lands on the same path and adds nothing. Only a file inside
  `imagesDir` is one retention can ever reclaim, which is why the blob moves there before the row lands.
- **Snippets** merge through `importSnippets`, deduped on name and body so importing the same file
  twice doesn't leave a second copy of everything. Importing snippets does not enable snippets.
- **Notes** land as new files through `NotesRepository.importNotes`, which suffixes a title that is
  already taken rather than overwriting it.
- **Learning** replaces. Merging two Macs' frecency tables produces a table describing neither.

An `id` never travels with a clip: `items.id` is `UNIQUE`, so a re-import minting fresh identities is
what keeps a second pass from silently failing its inserts. Same reasoning as `QuicklinkArchive.merge`.

The old flat `Tinycast-Settings-*.json` export is gone rather than deprecated, and nothing reads it.

Raycast import is documented separately in [raycast-import.md](raycast-import.md).

## Full backup (fork)

The owner's ask: a backup complete enough to move to another Mac or keep, where every configuration
comes back. Fork code in `Features/FullBackup/`; upstream's pane, export and import call into it in a
few `Fork:` lines, and the launcher's Export and Import commands carry it too.

A `.tinycast` keeps upstream's five categories and adds eight sections, ticked on export and again
on import beside them: **Agents**, **MCP Servers**, **AI Connections**, **Voice & Dictation**,
**Quick Actions**, **Extensions**, **More Shortcuts & Settings** and, unticked by default, **AI Chat
History**. One opt-in, **Include API keys and tokens**, seals the app's secrets with a passphrase.

### Invariants

- **Every persisted store has a decision, and a harness finds new ones.** `FullBackupCoverage` names
  every `UserDefaults` key, every Application Support name and every Keychain scope the app writes,
  with the section that carries it, or why it stays (with a reason). `full-backup-coverage-test`
  scans `Tinycast/` for files that persist anything (`UserDefaults`, `defaults.set(`,
  `applicationSupport`, `KeychainSecretStore(scope:`, `sqlite3_open`, `.write(to:`), pulls their literal keys
  (`forKey: "…"`, `…Key = "…"`) and path names (`appendingPathComponent("…")`,
  `appending(path: "…")`), and fails on any it has no decision for, on any `AppSettingsKey` neither
  upstream nor the fork decides, and on any decision whose literal no source spells any more. A key
  built at run time (`hotkey.<action>`) is decided as its family. A store that names its key in a
  variable the scan can't read escapes it, so spell keys as `…Key = "…"` or `forKey: "…"`.
- **A switch that grants a capability is recorded, never applied.** AI, MCP, Quick Actions, cloud
  dictation, Ask by Voice, Dictation, Screen Awareness and its screenshots, extensions and AI for
  them, calendar access, auto-join, camera preview, snippets' keystroke listening, OCR of clipboard
  images, installed AI tools and AI Chat's finish notifications (which ask macOS for permission)
  travel as `FullBackupConsent` names. The import leaves each as this
  Mac has it and lists those still off: "Still off here, turn on in Settings if you want them".
  `extensionsAIGrants` never travels at all.
- **What runs code or reaches out lands off or paused.** Every imported MCP server is off and every
  imported schedule paused, named in the summary; a server or schedule this Mac already runs keeps
  running, since it was consented here. Extensions are a list to reinstall from the Store, never code;
  their background and menu-bar commands are named, never switched on. Fallbacks can only be switched
  off, so an import never re-arms Run Shell Command. A screen context level wider than this Mac's
  (screenshots for cloud dictation) is kept back.
- **Commands a file can launch are shown before anything applies.** An ACP agent's command, a stdio
  MCP server's command and an installed AI tool's path are listed in one dialog; Cancel applies
  nothing. Upstream's own custom-command dialog still runs for the Settings category.
- **A ChatGPT sign-in never travels.** A Codex (ChatGPT) connection is backed up as an entry, but its
  OAuth tokens, its `ext_agent_host_id` registration (`codex-plan-credentials`) and its limits snapshot
  (`CodexPlan/limits.json`) stay out, sealed secrets included: the registration is bound to the Mac
  that made it. The summary names those connections: "Sign in with ChatGPT again on this Mac".
- **Secrets travel only sealed, and are read only to seal them.** With the opt-in off the app never
  reads its Keychain for a backup; with it on, it reads its own items at export, seals them, and on
  import writes back only those whose connection, server, tool or extension exists on this Mac. A
  wrong passphrase applies nothing.
- **No home path enters the file either.** Upstream's rule holds for the fork's sections:
  `FullBackupPaths` writes a path under the home folder as `~/…` (an agent's folder and ACP command, a
  stdio server's command and arguments, an installed tool's path, an extension's text and app
  preferences) and the import puts it under this Mac's home. A path elsewhere is kept as it is.
  Chat history, which the reader ticks, is the one section that carries whatever the chats said.
- **No section restates a schema.** Payloads reuse the stores' own `Codable` types; the chat database
  travels as a `VACUUM INTO` copy and merges back by the columns both sides have.

### Inside `full/`

```
full/contents.json         format, each section's version and count, the secrets header
full/<section>.json        one payload per section: agents, mcpServers, ai, voice, quickActions,
                           extensions, more, chatHistory
full/ai-chat-folders.json  AI Chat's folders and which chat is in each, in the workspace file's format
full/chats/ai-chat-workspace.json  each chat's instructions, creativity, archive and deletion state
full/chats/ai-chats.sqlite3      the chat database, with its images
full/chats/summaries/<id>.json   agent chats' summaries
full/secrets.sealed        AES-GCM sealed JSON of every secret, only with the opt-in
```

| File | Role |
| --- | --- |
| `Model/FullBackupSection.swift` | The sections, their version, label, symbol, Replace support and default |
| `Model/FullBackupContents.swift` | `contents.json`, the secrets header and the preview an opened file offers |
| `Model/FullBackupLayout.swift` | The `full/` tree and its coding |
| `Model/FullBackupPayloads.swift` | One payload per section, every field optional, and the secrets payload |
| `Model/FullBackupPaths.swift` | Home paths as `~/…` on the way out and back under this Mac's home |
| `Model/FullBackupList.swift` | An array that drops a record it can't read, and an extension preference value |
| `Model/FullBackupConsent.swift` | The capability switches a file records and never applies |
| `Model/FullBackupImportPolicy.swift` | Pausing, switching off, launch lists, merge and replace |
| `Model/FullBackupCoverage.swift` | Every store's decision, which the coverage harness checks |
| `Model/FullBackupAutoExportPolicy.swift` | When a quit exports, the file name and what is pruned |
| `Model/FullBackupReport.swift` | The import summary, one sentence per thing it applied or left |
| `Service/FullBackupCipher.swift` | PBKDF2 and AES-GCM; the only file importing CommonCrypto and CryptoKit |
| `Service/FullBackupGather.swift`, `FullBackupComposer.swift` | Stores → payloads → `full/` |
| `Service/FullBackupRestore.swift` | Payloads → stores, through each store's own API |
| `Service/FullBackupChatArchive.swift` | The chat database's snapshot and merge |
| `Service/FullBackupActions.swift`, `FullBackupSettings.swift` | Export, import, the launcher commands, export on quit |
| `Settings/FullBackupDraft.swift`, `FullBackupOptions.swift` | The pane's choices and its rows |

### Restore choices

Opening a file previews what it holds: upstream's categories with their counts, then each section
with its count, the sealed secrets with theirs, and the names of any section this build can't read.
Agents, MCP Servers, AI Connections and Quick Actions offer **Merge** (adds what's new and updates
what matches, by id) or **Replace** (also removes what the file lacks, with a removed connection's
keys). Voice, Extensions and More overwrite the settings the file has and keep the rest. Chat history
only merges: a conversation this Mac has is kept as it is, and a second import adds nothing.
AI Chat's folders (name, colour, icon, instructions, agent) come with AI Connections and follow its
Merge or Replace by id; Archive inactive chats and Keep Window on Top come with it too. A chat is
filed in its folder only if this Mac has the chat and has not filed, archived or deleted it itself,
and a chat's own instructions, creativity, archive and Recently Deleted state land, with the history,
only on a chat this Mac says nothing of yet. An
agent's memory is written only where this Mac has none, or always with Replace. Agents whose folder
this Mac lacks are named. Retention still applies, so a chat older than AI's history setting is
pruned by it.

### Encryption

Key derivation is PBKDF2-HMAC-SHA256 through CommonCrypto at 600,000 iterations (OWASP's 2023 figure;
well under a second on Apple silicon) over a 16-byte random salt, into a 256-bit key for CryptoKit's
AES-GCM with a random nonce. scrypt would be stronger against GPUs, but neither CryptoKit nor
CommonCrypto offers it, and the `Scrypt.swift` beside the Raycast decoder is a reader for Raycast's
files, not a reviewed primitive. The header in `contents.json` holds the KDF, the iterations, the
salt and the cipher, and is the AES-GCM associated data, so lowering the iterations or swapping the
salt fails authentication like a wrong passphrase. A reader refuses fewer than 100,000 or more than
10,000,000 iterations, and an unknown KDF or cipher. Passphrases are at least 8 characters, entered
twice, NFC-normalised, cleared after the export, and never stored.

Sealed: AI connections' API keys and custom headers, OpenRouter management keys, each MCP server's
Keychain item verbatim (header, environment, OAuth client ID and secret, registration and token),
web search keys, installed AI tools' environment values, and each extension's password preferences
and OAuth tokens, which the extension runtime keeps in plain JSON rather than the Keychain.

### Version tolerance

`contents.json` has its own `format` (1) and a version per section. A file from before the fork's
sections has no `contents.json`, so only upstream's categories are offered and import as they did. A
newer `format` skips every section; an unknown section name, or a known one at a newer version, is
skipped and named in the preview and the summary. Inside a section every field is optional, an
array drops a record it can't decode and counts it ("records from a newer version skipped"), and an
unknown consent name is dropped. The upstream manifest guard stays as it is.

### Export on quit

Settings › Backup › Automatic Backup: **Export when Tinycast quits** writes
`Tinycast-Auto-<yyyy-MM-dd-HHmmss>.tinycast` into the chosen folder when the last export (by hand or
on quit) is older than 1, 3, 7, 14 or 30 days, then deletes all but the newest 3, 5, 10 or 20 files
of that name pattern, never another file. It carries Settings & Shortcuts, Snippets, Notes, Launcher
Learning and every section except chat history, never the clipboard or secrets. It runs inside the
quit, after notes flush, so there is no timer and nothing runs while the app is open. The folder,
the switch and the last export date live in `FullBackupSettings`, per Mac.

### Coverage

Every store the app persists and its decision, as `FullBackupCoverage` states it.

| Store | Where | Full backup |
| --- | --- | --- |
| The 65 keys `SettingsBackupCoverage.mirrored` names (theme, Colorful Icons, interface size, hyper key, launcher, clipboard, file search, notes, window management, quicklinks with their tags, calendar display and more) | UserDefaults | Upstream category: Settings & Shortcuts |
| `launchAtLogin` | `SMAppService` | Upstream category: Settings & Shortcuts |
| `Notes/*.md` (or the chosen folder) | Application Support | Upstream category: Notes |
| `dictationEnabled` | UserDefaults (`AppSettingsKey.dictationEnabled`) | Voice & Dictation: recorded, never applied |
| `dictationMode` | UserDefaults (`AppSettingsKey.dictationMode`) | Voice & Dictation |
| `dictationModel` | UserDefaults (`AppSettingsKey.dictationModel`) | Excluded: Names an on-device model this Mac downloaded; another fetches its own. |
| `dictationLanguage` | UserDefaults (`AppSettingsKey.dictationLanguage`) | Voice & Dictation |
| `dictationMicrophone` | UserDefaults (`AppSettingsKey.dictationMicrophone`) | Excluded: Names a microphone attached to this Mac. |
| `dictationDestination` | UserDefaults (`AppSettingsKey.dictationDestination`) | Excluded: An import must not change where dictated text is sent. |
| `dictationAdaptsCapitalization` | UserDefaults (`AppSettingsKey.dictationAdaptsCapitalization`) | Voice & Dictation |
| `dictationLiveInsertion` | UserDefaults (`AppSettingsKey.dictationLiveInsertion`) | Voice & Dictation |
| `dictationIdleReleaseMinutes` | UserDefaults (`AppSettingsKey.dictationIdleRelease`) | Voice & Dictation |
| `dictationHistoryRetentionDays` | UserDefaults (`AppSettingsKey.dictationHistoryRetention`) | Excluded: An import must never carry an instruction to delete text. |
| `dictationHistoryKeepsVoiceReplies` | UserDefaults (`AppSettingsKey.dictationHistoryVoiceReplies`) | Excluded: An import must never start keeping voice replies. |
| `dictationHistoryKeepsFailedRecordings` | UserDefaults (`AppSettingsKey.dictationHistoryFailedRecordings`) | Excluded: An import must never start keeping recordings. |
| `clipboardTextSearchEnabled` | UserDefaults (`AppSettingsKey.clipboardTextSearchEnabled`) | More Shortcuts & Settings: recorded, never applied |
| `snippetsEnabled` | UserDefaults (`AppSettingsKey.snippetsEnabled`) | More Shortcuts & Settings: recorded, never applied |
| `extensionPackageManager` | UserDefaults (`AppSettingsKey.extensionPackageManager`) | Excluded: Names a tool on this Mac; another may not have it. |
| `extensionCustomSearchPaths` | UserDefaults (`AppSettingsKey.extensionCustomSearchPaths`) | Excluded: Machine-local toolchain paths. |
| `extensionsEnabled` | UserDefaults (`AppSettingsKey.extensionsEnabled`) | Extensions: recorded, never applied |
| `extensionsAIEnabled` | UserDefaults (`AppSettingsKey.extensionsAIEnabled`) | Extensions: recorded, never applied |
| `extensionsAIModel` | UserDefaults (`AppSettingsKey.extensionsAIModel`) | Extensions |
| `extensionsAIGrants` | UserDefaults (`AppSettingsKey.extensionsAIGrants`) | Excluded: Grants third-party code a model; a grant is never imported. |
| `extensionsAIHonorsModels` | UserDefaults (`AppSettingsKey.extensionsAIHonorsModels`) | Extensions: recorded, never applied |
| `palettePosition` | UserDefaults (`AppSettingsKey.palettePosition`) | Excluded: Names displays this Mac has. |
| `paletteExpandedCenterDisplays` | UserDefaults (`AppSettingsKey.paletteExpandedCenterDisplays`) | Excluded: Names displays this Mac has. |
| `autoSwitchInputSource` | UserDefaults (`AppSettingsKey.autoSwitchInputSource`) | Excluded: Names an input source installed on this Mac. |
| `meetingBrowser` | UserDefaults (`AppSettingsKey.meetingBrowser`) | More Shortcuts & Settings |
| `calendarEnabled` | UserDefaults (`AppSettingsKey.calendarEnabled`) | More Shortcuts & Settings: recorded, never applied |
| `autoJoinMeetings` | UserDefaults (`AppSettingsKey.autoJoinMeetings`) | More Shortcuts & Settings: recorded, never applied |
| `cameraPreview` | UserDefaults (`AppSettingsKey.cameraPreview`) | More Shortcuts & Settings: recorded, never applied |
| `aiEnabled` | UserDefaults (`AppSettingsKey.aiEnabled`) | AI Connections: recorded, never applied |
| `aiInstalledProviders` | UserDefaults (`AppSettingsKey.aiInstalledProviders`) | AI Connections: recorded, never applied |
| `aiConnections` | UserDefaults (`AppSettingsKey.aiConnections`) | AI Connections |
| `aiDefaultModel` | UserDefaults (`AppSettingsKey.aiDefaultModel`) | AI Connections |
| `aiWebSearch` | UserDefaults (`AppSettingsKey.aiWebSearch`) | AI Connections |
| `aiWebSearchEngines` | UserDefaults (`AppSettingsKey.aiWebSearchEngines`) | AI Connections |
| `aiChoices` | UserDefaults (`AppSettingsKey.aiChoices`) | AI Connections |
| `aiSystemPrompt` | UserDefaults (`AppSettingsKey.aiSystemPrompt`) | AI Connections |
| `aiSystemPromptEnabled` | UserDefaults (`AppSettingsKey.aiSystemPromptEnabled`) | AI Connections |
| `aiRetentionDays` | UserDefaults (`AppSettingsKey.aiRetention`) | AI Connections |
| `aiOpensTo` | UserDefaults (`AppSettingsKey.aiOpensTo`) | AI Connections |
| `aiNewChatAfterMinutes` | UserDefaults (`AppSettingsKey.aiNewChatAfter`) | AI Connections |
| `aiToolRounds` | UserDefaults (`AppSettingsKey.aiToolRounds`) | AI Connections |
| `aiShownModels` | UserDefaults (`AppSettingsKey.aiShownModels`) | AI Connections |
| `aiDisabledRoutes` | UserDefaults (`AppSettingsKey.aiDisabledRoutes`) | AI Connections |
| `aiInstalledOverrides` | UserDefaults (`AppSettingsKey.aiInstalledOverrides`) | AI Connections |
| `aiQuickAIAgent` | UserDefaults (`AppSettingsKey.aiQuickAIAgent`) | Agents |
| `aiChatAgent` | UserDefaults (`AppSettingsKey.aiChatAgent`) | Agents |
| `aiChatAutoArchiveDays` | UserDefaults (`AppSettingsKey.aiChatAutoArchive`) | AI Connections |
| `aiChatFinishNotifications` | UserDefaults (`AppSettingsKey.aiChatFinishNotifications`) | AI Connections: recorded, never applied |
| `mcpEnabled` | UserDefaults (`AppSettingsKey.mcpEnabled`) | MCP Servers: recorded, never applied |
| `mcpServers` | UserDefaults (`AppSettingsKey.mcpServers`) | MCP Servers |
| `quickActionsEnabled` | UserDefaults (`AppSettingsKey.quickActionsEnabled`) | Quick Actions: recorded, never applied |
| `screenAwarenessEnabled` | UserDefaults (`AppSettingsKey.screenAwarenessEnabled`) | More Shortcuts & Settings: recorded, never applied |
| `screenAwarenessScreenshot` | UserDefaults (`AppSettingsKey.screenAwarenessScreenshot`) | More Shortcuts & Settings: recorded, never applied |
| `screenAwarenessDestination` | UserDefaults (`AppSettingsKey.screenAwarenessDestination`) | More Shortcuts & Settings |
| `screenAwarenessShortcutOffered` | UserDefaults (`AppSettingsKey.screenAwarenessShortcutOffered`) | Excluded: Records that this Mac was offered the gesture. |
| `voiceCloudDictation` | UserDefaults (`AppSettingsKey.voiceCloudDictation`) | Voice & Dictation: recorded, never applied |
| `voiceDictationModel` | UserDefaults (`AppSettingsKey.voiceDictationModel`) | Voice & Dictation |
| `voiceDictationCleanup` | UserDefaults (`AppSettingsKey.voiceDictationCleanup`) | Voice & Dictation |
| `voiceVocabulary` | UserDefaults (`AppSettingsKey.voiceVocabulary`) | Voice & Dictation |
| `voiceDictationModes` | UserDefaults (`AppSettingsKey.voiceDictationModes`) | Voice & Dictation |
| `voiceDictationLanguages` | UserDefaults (`AppSettingsKey.voiceDictationLanguages`) | Voice & Dictation |
| `voiceDictationAppContext` | UserDefaults (`AppSettingsKey.voiceDictationAppContext`) | Voice & Dictation |
| `voiceAskEnabled` | UserDefaults (`AppSettingsKey.voiceAskEnabled`) | Voice & Dictation: recorded, never applied |
| `voiceAskMode` | UserDefaults (`AppSettingsKey.voiceAskMode`) | Voice & Dictation |
| `voiceAskModel` | UserDefaults (`AppSettingsKey.voiceAskModel`) | Voice & Dictation |
| `voiceAskAgent` | UserDefaults (`AppSettingsKey.voiceAskAgent`) | Voice & Dictation |
| `agentSessionsEnabled` | UserDefaults (`AppSettingsKey.agentSessionsEnabled`) | More Shortcuts & Settings |
| `agentSessionsTerminal` | UserDefaults (`AppSettingsKey.agentSessionsTerminal`) | More Shortcuts & Settings |
| `agentStatusMenuBar` | UserDefaults (`AppSettingsKey.agentStatusMenuBar`) | More Shortcuts & Settings |
| `agentSessionsClaudeFolder` | UserDefaults (`AppSettingsKey.agentSessionsClaudeFolder`) | Excluded: Names a folder on this Mac. |
| `agentSessionsCodexFolder` | UserDefaults (`AppSettingsKey.agentSessionsCodexFolder`) | Excluded: Names a folder on this Mac. |
| `quickActionModel` | UserDefaults (`AppSettingsKey.quickActionModel`) | Quick Actions |
| `quickActionModelOverrides` | UserDefaults (`AppSettingsKey.quickActionModelOverrides`) | Quick Actions |
| `quickActionPreviews` | UserDefaults (`AppSettingsKey.quickActionPreviews`) | Quick Actions |
| `quickActionInstructions` | UserDefaults (`AppSettingsKey.quickActionInstructions`) | Quick Actions |
| `quickActionLanguage` | UserDefaults (`AppSettingsKey.quickActionLanguage`) | Quick Actions |
| `snippetsFolder` | UserDefaults (`AppSettingsKey.snippetsFolder`) | Excluded: Names a folder on this Mac; the snippets themselves travel. |
| `notesFolder` | UserDefaults (`AppSettingsKey.notesFolder`) | Excluded: Names a folder on this Mac; the notes themselves travel. |
| `settingsFileEnabled` | UserDefaults (`AppSettingsKey.settingsFileEnabled`) | Excluded: Lets a file on this Mac change its settings. |
| `favoriteApps` | UserDefaults | Upstream category |
| `hiddenLauncherItems` | UserDefaults | Upstream category |
| `hiddenLauncherKinds` | UserDefaults | Upstream category |
| `launcherAliases` | UserDefaults | Upstream category |
| `customCommands` | UserDefaults | Upstream category |
| `windowLayouts` | UserDefaults | Upstream category |
| `windowRooms` | UserDefaults | Upstream category |
| `customWindowSizes` | UserDefaults | Upstream category |
| `hotkey.*` | UserDefaults | More Shortcuts & Settings |
| `boundAppBundleIDs` | UserDefaults | Not app state: An index of hotkey.* keys that setBinding rebuilds. |
| `boundPaneBundleIDs` | UserDefaults | Not app state: An index of hotkey.* keys that setBinding rebuilds. |
| `boundCustomCommandIDs` | UserDefaults | Not app state: An index of hotkey.* keys that setBinding rebuilds. |
| `boundQuicklinkIDs` | UserDefaults | Not app state: An index of hotkey.* keys that setBinding rebuilds. |
| `boundQuickActionIDs` | UserDefaults | Not app state: An index of hotkey.* keys that setBinding rebuilds. |
| `boundWindowLayoutIDs` | UserDefaults | Not app state: An index of hotkey.* keys that setBinding rebuilds. |
| `boundWindowRoomIDs` | UserDefaults | Not app state: An index of hotkey.* keys that setBinding rebuilds. |
| `boundCustomWindowSizeIDs` | UserDefaults | Not app state: An index of hotkey.* keys that setBinding rebuilds. |
| `boundAppleShortcutIDs` | UserDefaults | Not app state: An index of hotkey.* keys that setBinding rebuilds. |
| `boundSnippetIDs` | UserDefaults | Not app state: An index of hotkey.* keys that setBinding rebuilds. |
| `boundExtensionCommandEntryIDs` | UserDefaults | Not app state: An index of hotkey.* keys that setBinding rebuilds. |
| `boundAgentIDs` | UserDefaults | Not app state: An index of hotkey.* keys that setBinding rebuilds. |
| `fallbackOrder` | UserDefaults | More Shortcuts & Settings |
| `disabledFallbacks` | UserDefaults | More Shortcuts & Settings |
| `hiddenMeetingCalendars` | UserDefaults | More Shortcuts & Settings |
| `extensionAppearances` | UserDefaults | Extensions |
| `roomMinimumWindowSizes` | UserDefaults | Excluded: Learned from this Mac's own windows and displays. |
| `hyperKeyKeyboardMappings` | UserDefaults | Excluded: Crash recovery for this boot's key remap. |
| `notesActiveFileName` | UserDefaults | Excluded: Window state: the note that was open. |
| `notesFormattingBarExpanded` | UserDefaults | Excluded: Window state. |
| `AIChatFloatsOnTop` | UserDefaults | AI Connections |
| `AIChatShowsSettingsSidebar` | UserDefaults | Excluded: Window layout, remembered like the split view's widths. |
| `fullBackupAutoExport` | UserDefaults | Excluded: Names a folder on this Mac and when it last exported. |
| `fullBackupAutoExportDays` | UserDefaults | Excluded: Names a folder on this Mac and when it last exported. |
| `fullBackupAutoExportKeep` | UserDefaults | Excluded: Names a folder on this Mac and when it last exported. |
| `fullBackupAutoExportFolder` | UserDefaults | Excluded: Names a folder on this Mac and when it last exported. |
| `fullBackupLastExport` | UserDefaults | Excluded: Names a folder on this Mac and when it last exported. |
| `AppleShowScrollBars` | UserDefaults | Not app state: AppKit's own preference, set at every launch. |
| `NSFileViewer` | UserDefaults | Not app state: Read from the system: the user's file viewer. |
| `com.apple.swipescrolldirection` | UserDefaults | Not app state: Read from the system. |
| `WarnOnEmptyTrash` | UserDefaults | Not app state: Read from Finder's preferences. |
| `AppleSymbolicHotKeys` | UserDefaults | Not app state: Read from macOS: the shortcuts the system keeps. |
| `hyperKeyPhysicalKey` | UserDefaults | Upstream category |
| `quicklinks.sqlite3` | Application Support | Upstream category |
| `clipboard.sqlite3` | Application Support | Upstream category |
| `images` | Application Support | Upstream category |
| `Snippets` | Application Support | Upstream category |
| `emoji-pinned.json` | Application Support | Upstream category |
| `launcher-ranking.json` | Application Support | Upstream category |
| `emoji-frequency.json` | Application Support | Upstream category |
| `calculator-history.json` | Application Support | Upstream category |
| `agents.json` | Application Support | Agents |
| `agent-colors.json` | Application Support | Agents |
| `agent-newer-tools.json` | Application Support | Agents |
| `agent-schedules.json` | Application Support | Agents |
| `agent-schedule-spend.json` | Application Support | Agents |
| `agents` | Application Support | Agents |
| `memory.md` | Application Support | Agents |
| `agent-schedule-runs.json` | Application Support | Excluded: Run baselines; an imported schedule starts counting anew. |
| `agent-acp-sessions.json` | Application Support | Excluded: Sessions of a CLI on this Mac, which another can't resume. |
| `agent-acp-choices.json` | Application Support | Excluded: Belongs to the ACP sessions beside it. |
| `agent-chats.json` | Application Support | AI Chat History |
| `agent-personal-chats.json` | Application Support | AI Chat History |
| `agent-summaries` | Application Support | AI Chat History |
| `ai-chats.sqlite3` | Application Support | AI Chat History (opt-in), the whole database merged row by row |
| `ai-chat-workspace.json` | Application Support | AI Connections: folders (name, colour, icon, instructions, agent) and which chat is filed where, applied to chats this Mac has; each chat's instructions, creativity, archive and Recently Deleted state travel with AI Chat History |
| `CodexPlan/limits.json` | Application Support | Excluded: The last limits a ChatGPT plan reported; the next reply reports them anew. |
| `quick-actions.json` | Application Support | Quick Actions |
| `extensions` | Application Support | Extensions: the list (name, author, Store commit) to reinstall from; the code never travels |
| `extension-data` | Application Support | Extensions: non-secret preferences and the appearance; password preferences and OAuth tokens only in the sealed secrets; LocalStorage and caches never |
| `extension-commands.json` | Application Support | Extensions: which commands refreshed in the background or drew in the menu bar, recorded and never switched on |
| `extension-versions.json` | Application Support | Extensions |
| `extension-support` | Application Support | Excluded: An extension's own scratch files. |
| `\(ExtensionCatalog.safeName(name)).json` | Application Support | Extensions |
| `build` | Application Support | Not app state: Scratch space of an extension install. |
| `expanded` | Application Support | Not app state: Scratch space of an extension install. |
| `source` | Application Support | Not app state: Scratch space of an extension install. |
| `node_modules/.bin/ray` | Application Support | Not app state: A tool inside an extension being built. |
| `extension.zip` | Application Support | Not app state: A download on its way to an extension install. |
| `body` | Application Support | Not app state: A download on its way to an extension install. |
| `currency-rates.json` | Application Support | Excluded: A cache in Caches, fetched again when it is needed. |
| `update-check.json` | Application Support | Excluded: A cache in Caches, fetched again when it is needed. |
| `extension-store.json` | Application Support | Excluded: A cache in Caches, fetched again when it is needed. |
| `chats` | Application Support | Not app state: Read from another tool's own history folder. |
| `.project_root` | Application Support | Not app state: Read from another tool's own history folder. |
| `\(target.rawValue)-\(stamp).json` | Application Support | Excluded: Backups of hook files in this Mac's own CLIs. |
| `resume-\(UUID().uuidString).command` | Application Support | Not app state: A temporary script that resumes a session. |
| `.\(destination.lastPathComponent).\(UUID().uuidString).tmp` | Application Support | Not app state: A temporary write. |
| `\(base)\(suffixText).md` | Application Support | Upstream category |
| `\(name).unreadable-\(UUID().uuidString).json` | Application Support | Excluded: An unreadable file set aside for a person. |
| `room-parking.json` | Application Support | Excluded: Window ids of this session. |
| `InstalledAI/Codex` | Application Support | Excluded: Scratch space for an installed CLI. |
| `InstalledAI/Workspace` | Application Support | Excluded: Scratch space for an installed CLI. |
| `Workspace` | Application Support | Excluded: Scratch space for an installed CLI. |
| `agent-sessions` | Application Support | Excluded: Live status hooks installed into this Mac's own CLIs. |
| `hook-backups` | Application Support | Excluded: Live status hooks installed into this Mac's own CLIs. |
| `live-status.json` | Application Support | Excluded: Live status hooks installed into this Mac's own CLIs. |
| `dictation-volume.json` | Application Support | Excluded: Crash recovery for the volume a dictation lowered. |
| `dictation-history.jsonl` | Application Support | Excluded: Private transcripts never leave this Mac. |
| `dictation-failed-audio` | Application Support | Excluded: Private recordings never leave this Mac. |
| `FileIndex` | Application Support | Excluded: Rebuilt from the disk it indexes. |
| `onboarded` | Application Support | Excluded: Records that this Mac saw onboarding. |
| `support-reminder.json` | Application Support | Excluded: When this Mac last showed a reminder. |
| `ai-usage.tsv` | Application Support | Excluded: Usage data, like chat history, but never exported. |
| `settings.json` | Application Support | Excluded: The settings file mirror, which this Mac opts into. |
| `.config` | Application Support | Not app state: The settings file's folder. |
| `.config/\($0)/extensions` | Application Support | Not app state: Where Raycast's own extensions are read from. |
| `Contents/Helpers/FileIndexHelper` | Application Support | Not app state: A path inside the app bundle. |
| `assets` | Application Support | Not app state: A folder inside an installed extension. |
| `package.json` | Application Support | Not app state: A file inside an installed extension. |
| `node_modules` | Application Support | Not app state: A folder inside an installed extension. |
| `\($0.name).js` | Application Support | Not app state: A file inside an installed extension. |
| `\(command.name).js` | Application Support | Not app state: A file inside an installed extension. |
| `.\(fileURL.lastPathComponent).\(UUID().uuidString).tmp` | Application Support | Not app state: A temporary write. |
| `.Trash` | Application Support | Not app state: The user's Trash. |
| `<bundle id>.ai-api-keys` | Keychain | Sealed secrets (opt-in) |
| `<bundle id>.ai-request-headers` | Keychain | Sealed secrets (opt-in) |
| `<bundle id>.mcp-secrets` | Keychain | Sealed secrets (opt-in) |
| `<bundle id>.installed-ai-environment` | Keychain | Sealed secrets (opt-in) |
| `<bundle id>.web-search-keys` | Keychain | Sealed secrets (opt-in) |
| `<bundle id>.openrouter-management-keys` | Keychain | Sealed secrets (opt-in) |
| `<bundle id>.codex-plan-credentials` | Keychain | Excluded: A ChatGPT sign-in registered to this host (ext_agent_host_id); the new Mac signs in again. |

### Testing

`full-backup-test` round-trips every section's payload through a sealed `.tinycast` and a fresh
extract, snapshots and merges a chat database twice (an extra column on one side), reads an old
upstream-only file, skips unknown and newer sections, drops a record it can't read, checks every
import rule (paused schedules, servers off, kept consent here, the launch list, a wider screen
context, background commands, fallbacks only switched off, the consent review, merge and replace),
seals and opens secrets with the right and a wrong passphrase, refuses an edited or weakened header,
asserts no extracted file holds a secret in the clear, writes home paths as `~/…` and puts them
back under another home, and covers the export-on-quit policy.
`full-backup-coverage-test` is the guard above. The adapters to the live stores need the app, so
they are the manual sweep's.

### Manual sweep

- On a Mac with agents (one with a schedule on), MCP servers (one stdio, one on), two AI connections
  with keys, a custom voice mode, a custom Quick Action with a hotkey, an extension with a password
  preference and a menu-bar command, an agent hotkey and a snippet hotkey: export everything with
  **Include API keys and tokens** and a passphrase. The status names every section and "sealed API
  keys and tokens".
- Extract a copy with `aa extract -i <file> -d /tmp/x`: no key appears in any file, and
  `full/secrets.sealed` is binary.
- In a second macOS user account (or on another Mac), import the file: the preview lists every section and the
  sealed items; the launch dialog lists the ACP command, the stdio server and any tool path; Cancel
  applies nothing.
- Import with the passphrase: agents with their skills, folders and colours; the schedule paused and
  named; MCP servers present and off; AI connections answering with their keys; voice modes, Quick
  Actions and their hotkeys; the extension's preferences once it is installed, its menu-bar command
  off and named; the summary lists AI, MCP and other switches still off.
- Import again with a wrong passphrase: refused, nothing changed. Import with Replace on Agents: an
  agent made after the export is gone.
- Tick AI Chat History, export and import into a Mac with chats: the old chats join, none is
  duplicated by a second import.
- Turn on Export when Tinycast quits with a folder and 1 day; quit: a file appears. Quit again at
  once: no second file. With Keep at 3 and older auto files present, only the newest three remain,
  and a file of another name is untouched.
- Import an upstream Tinycast `.tinycast`: only its categories are offered and import as before.
- With two AI Chat folders (one with instructions and an agent), a chat filed in each, one with its
  own instructions and one archived: export with AI Connections and AI Chat History, import into a Mac
  without them. The folders arrive; the chats land filed, archived and instructed as they were. Import
  AI Connections alone elsewhere: the folders arrive and only chats that Mac has are filed.
- Export a Codex (ChatGPT) connection with keys sealed and import it: the connection is listed, signed
  out, and the summary says to sign in with ChatGPT again.
