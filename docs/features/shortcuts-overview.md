# Shortcuts overview

Settings › Shortcuts («Сочетания клавиш») lists every hotkey and alias the app knows in one place:
the launcher's own shortcut and Dictation's, every built-in command and Quick Action, custom
commands, quicklinks, snippets with their keywords, agents, custom Quick Actions, extension commands,
Apple Shortcuts, window commands, custom sizes, layouts and rooms, system actions, and any app or
Settings pane that has a hotkey or an alias. Fork code in `Features/ShortcutsOverview/`; upstream's
Settings gets the tab, its anchors and search entries in `Fork:` lines.

## Invariants

- **No second source of truth.** Every row is read from the store that owns it on each render:
  `HotKeyManager` for bindings, `AliasStore` for aliases, the snippet for its keyword, and each
  feature's own store or catalog for the entries. Nothing here persists.
- **Edits go through the existing controls.** The alias column is `AliasField` and the hotkey column
  `ShortcutRecorder`, the ones every pane uses, so a change here is the same write, with the same
  conflict check, as a change in that feature's pane, and shows there at once.
- **The audit only reports.** Conflicts are flagged with what they collide with; nothing is unbound
  or renamed for the reader.
- **System shortcuts are read, never changed.** The chords macOS ships, with the reader's own changes
  from `com.apple.symbolichotkeys`, are read once each time the pane opens.

## The list

| Column | From |
| --- | --- |
| Icon | `AppIconView` for an entry, a symbol for the two global actions |
| Name | The entry's name |
| Kind | `AppEntry.kindLabel` (an extension command shows its extension), or Global |
| Alias | `AliasField`, keyed by the entry's `preferenceKey`; a snippet's keyword shows under its name |
| Hotkey | `ShortcutRecorder` for the entry's `HotKeyAction`, `InlineEntryEditor.hotKeyAction(for:)` |

Filters: **All**, **With Hotkey**, **With Alias** (a snippet keyword counts), **Conflicts** and
**Disabled**, on a `SteadySegmentedPicker`. Search matches every word against the name, the kind,
the alias, the keyword and the keycaps, ignoring case and accents, so "⌥⌘" finds what uses it. The
list grows 60 rows at a time, since a `Form` realizes every row it holds. A Hyper Key row says which
physical key is the ✦ in the keycaps; it is changed in General.

A row is **disabled** when its feature or the item itself is off (a command whose feature hides it,
a disabled custom command or quicklink, snippets, agents while AI is off, extensions while they are
off, window commands while window management is off, Quick Actions while they are off), or when the
runtime gate (`HotKeyManager.allowsAction`, which follows the launcher's category switches) refuses
its hotkey. Apps and Settings panes are listed only once they have a hotkey or an alias.

## The conflict audit

`ShortcutAudit` (pure, `Model/`) flags, on both sides:

- **The same shortcut twice**, by `HotKeyBinding.conflicts(with:)`, so a double tap of ⌘ and a double
  tap of right ⌘ collide as they do at run time. The recorder refuses these, so this mostly catches a
  backup, `settings.json` edit or hold-mode change that slipped one through.
- **The same alias twice**, trimmed and case-folded: Alias + Space falls through to search when two
  entries share one ([alias actions](alias-actions.md)).
- **The same snippet keyword twice**, case-folded as expansion matches it.
- **A chord macOS keeps**: Spotlight and Finder search, input sources, the screenshot chords, Mission
  Control, application windows, moving between Spaces, Show Desktop, Dock hiding and the next-window
  chord, as macOS ships them unless `AppleSymbolicHotKeys` says the reader turned one off or moved it,
  plus the app switcher, Force Quit, Lock Screen and Log Out, which no setting moves. Another app's
  global shortcut is not detectable: Carbon's registration only logs a refusal.

Each issue becomes the row's subtitle and an orange mark with the same text as its help.

## Layout

| File | Role |
| --- | --- |
| `Model/ShortcutEntry.swift` | One row's facts, and the filters with the search |
| `Model/ShortcutAudit.swift` | The conflict audit and the system shortcuts, with `AppleSymbolicHotKeys` parsing |
| `Service/ShortcutsInventory.swift` | Rows from the live stores, and the system shortcuts read |
| `Settings/ShortcutsSettingsView.swift` | The pane |

## Testing

`shortcuts-overview-test` covers a shared chord, a shared alias with different case and spaces, a
shared keyword, a chord macOS keeps, a double tap against a side's double tap, a row without issues,
the system list with a shortcut turned off, moved, and an arrow chord's function flag, and every
filter with search by name, accent-free name, keycaps, kind and keyword, alone and combined.

## Manual sweep

- Settings › Shortcuts lists the launcher's shortcut, Dictation, commands, your custom entries,
  extension commands and agents; `сочетания` in Settings search finds the pane in Russian.
- Record a hotkey on a row: it shows in that feature's own pane at once; clear it there and the row
  empties. Edit an alias here, then use Alias + Space in the launcher.
- Give two entries the same alias: both are flagged under Conflicts. Bind a command to ⌘Space: it is
  flagged "Taken by macOS: Spotlight". Turn Spotlight's shortcut off in System Settings, reopen the
  pane: the flag goes.
- Turn off window management: its commands are listed under Disabled, dimmed.
- Type `⌥⌘` or a keyword in the search field: the rows that use it remain.
