# Alias actions

Two launcher behaviours upstream chose not to have. **Alias + Space** is Raycast's alias jump, which
upstream declined ([#1128](https://github.com/abue-ammar/tinycast/issues/1128) and five more,
[not planned](https://github.com/abue-ammar/tinycast/blob/main/docs/not-planned.md)): type an entry's alias exactly, press Space, and the entry opens or
its first field takes the caret. **Change Alias / Change Shortcut** edit an entry's alias and global
shortcut from its ⌘K menu, where upstream keeps both in Settings only. Fork code in
`Features/AliasActions/`, plus one-line hooks in the palette and the shared menu row. Upstream's own
alias ranking, Tab-after-alias and Settings editing are unchanged; see
[launcher](launcher.md#user-aliases).

## Invariants

- **Only an exact alias, typed to the end.** The query must equal one entry's alias, case-sensitively
  (`cc` jumps, `CC` searches), with the caret at the end of the field and nothing selected. Anything
  else, including two entries sharing the alias, types a space.
- **Apps and settings panes keep searching.** `tg something` is more often a query than a jump, so
  their aliases never jump; they still rank first by upstream's rule.
- **`\` then Space always types a space.** The backslash is replaced, so an alias never traps a
  query. That escape is the whole configuration: no setting, no toggle, nothing persisted.
- **No state.** One `onKeyPress(.space)` handler asks the pure `AliasJump` (`Model/`, covered by
  `alias-actions-test`) and applies its answer; it reads the alias dictionary only on Space with a
  non-empty query, and adds no observer, timer or store.
- **⌘K editing writes through the existing stores only.** A committed alias goes through
  `AliasStore.setAlias` and a recorded chord through `HotKeyManager`, so Settings, backups and
  `settings.json` see exactly what they see for an edit made in Settings. Nothing here persists.
- **`AppCore` owns the editor, and the menu ends it.** `InlineEntryEditor` is one `@Observable` object
  on `AppCore`, never a singleton. Closing the menu ends an alias edit and stops a recording the menu
  started — and only that one, so a recording in Settings is never cut short.
- **The menu draws its own recording state.** Settings shows the prompt, the keys held and a conflict
  in a callout over the pane. The menu is a window of its own, clipped to its rows, so the shortcut
  box shows the same three states from the one `ShortcutCaptureSession` instead.

## Alias + Space

The handler acts only in root search with the search field focused, no argument field focused, no
menu or control list open, no marked text, the palette expanded, and no modifier but Caps Lock.
`AliasJump.decide` answers one of three things: ignore, escape the space, or jump to the entry the
alias names. The row is found in the launcher's own rows, so a hidden entry never jumps.
`AliasJump.target` then says what the jump does:

| Entry | Space |
| --- | --- |
| Application, System Settings pane | types a space |
| Extension view command whose arguments are all optional | opens it, so the next typing searches inside (Search Homebrew) |
| Quicklink, custom command or extension command with arguments | selects it; the caret moves to its first unanswered field once the fields are built, or the first field when all are optional |
| Any row whose header fields are already built (a Quick Action with placeholders) | selects it and focuses its first field |
| Anything else | runs it |

The pending-argument path is the one quicklinks' and shortcuts' `{argument}` prompts already use
(`PaletteState.pendingArgumentEntryID`); its focus falls back to the first field so a row whose
arguments are all optional still takes the caret.

## Change Alias / Change Shortcut

A launcher entry's ⌘K menu gains two rows after Hide from Search, for every entry that is not a
query-driven row (those have no preference to own):

- **Change Alias** draws the saved alias, or "Add Alias", in a box at the row's end. Activating the row
  keeps the menu open and edits the alias in place: the box shows the draft with a caret, every plain
  key goes to it ahead of the menu's search field, Return commits it trimmed (a blank commit clears the
  alias), Delete removes a character and Escape drops the edit. A ⌘ or ⌃ chord still reaches the menu.
- **Change Shortcut** draws the entry's shortcut, or "Record Hotkey", in a box like the alias's.
  Activating the row records through the same `HotKeyManager` capture Settings uses. The box is
  outlined and says "Type a shortcut", then shows the keys held. A chord another action owns is
  refused, and for a moment the box names that action in orange. Escape stops recording, and Delete
  clears the shortcut. A click anywhere stops it too, and a click on the row records again.
  Extension commands have one too: `AppEntry.hotKeyAction` leaves them out, so the row keys them by
  entry id as Settings does.

Both rows are `PopoverMenuItem`s with a `trailingAccessory` and `keepsMenuOpen`. `PaletteMenuContent`
carries `keepsOpen`, so `activateMenuItem` runs such a row without closing the menu, and
`handleMenuPanelKey` hands every key to `InlineEntryEditor.handleMenuKey` first. The rows are built only
when the menu opens. This departs from upstream's "editing lives in Settings only" on purpose: the
moment you notice you want an alias is the moment you are looking at the row.

## Layout

| File | Holds |
| --- | --- |
| `Model/AliasJump.swift` | `decide` (query, caret, aliases → ignore / escape / jump) and `target` (entry → field, arguments, run or nothing) |
| `Model/InlineAliasDraft.swift` | the alias being typed into a ⌘K row: keys in, editing / cancelled / committed out |
| `UI/InlineEntryEditor.swift` | the two menu rows, the key handling while an alias is edited, and the alias and shortcut boxes |
| `Palette/RootPaletteView.swift` | the Space handler and an extension at the end that maps a row to `AliasJump.Entry` and applies the answer (it reads the view's private focus and scroll state, which is why it lives there); one line each in `closeMenus`, `activateMenuItem` and `handleMenuPanelKey` |
| `DesignSystem/PopoverMenu.swift`, `Palette/PaletteScreen.swift` | `trailingAccessory` and `keepsMenuOpen` on the shared row, `keepsOpen` on the menu content |
| `Launcher/UI/AppActionsMenu.swift`, `App/AppCore.swift` | the line that adds the rows, and the line that owns the editor |

## Manual sweep

- Give Search Homebrew the alias `brew`. `brew␣` opens it and the next typing searches inside;
  `Brew␣` just searches; `brew\␣` types `brew `.
- Give a quicklink with `{argument}` the alias `gh`. `gh␣` puts the caret in its argument field.
- Give Safari the alias `sf`. `sf␣` types a space: apps keep searching.
- Two entries with the alias `x`: `x␣` types a space.
- Move the caret inside `brew` and press Space: a space is typed.
- Tab after an alias still fills a quicklink's arguments, as upstream does.
- ⌘K on any entry → Change Alias. Type, Delete, Return: the chip on the row updates. ⌘K → Change
  Alias, Escape: unchanged, and a second Escape closes the menu. Blank, then Return, clears the alias.
- ⌘K → Change Shortcut, press ⌥⌘J: the box fills and the shortcut works globally. Close the
  menu mid-recording: recording stops. A recording started in Settings is not stopped by the palette.
- ⌘K → Change Shortcut on an entry that already has one: the box is outlined and says "Type a
  shortcut", and holding ⌘⌥ shows ⌥⌘. Press the launcher's own shortcut: the box names App Launcher
  in orange, then asks again, and nothing is rebound. Escape keeps the old shortcut; Delete clears it.
- An extension command's ⌘K menu offers Change Shortcut too, and Settings › Extensions shows it.
- Settings shows the same alias and shortcut, and `settings.json` mirrors both when it is on.
