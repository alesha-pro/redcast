# Alias actions

Raycast's alias jump, which upstream declined
([#1128](https://github.com/abue-ammar/tinycast/issues/1128) and five more,
[not planned](../not-planned.md)): type an entry's alias exactly, press Space, and the entry opens
or its first field takes the caret. Fork code in `Features/AliasActions/`, plus the few lines in
`RootPaletteView` that wire it in. Upstream's own alias ranking and Tab-after-alias are unchanged; see
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

## Layout

| File | Holds |
| --- | --- |
| `Model/AliasJump.swift` | `decide` (query, caret, aliases → ignore / escape / jump) and `target` (entry → field, arguments, run or nothing) |
| `Palette/RootPaletteView.swift` | the Space handler and an extension at the end that maps a row to `AliasJump.Entry` and applies the answer; it reads the view's private focus and scroll state, which is why it lives there |

## Manual sweep

- Give Search Homebrew the alias `brew`. `brew␣` opens it and the next typing searches inside;
  `Brew␣` just searches; `brew\␣` types `brew `.
- Give a quicklink with `{argument}` the alias `gh`. `gh␣` puts the caret in its argument field.
- Give Safari the alias `sf`. `sf␣` types a space: apps keep searching.
- Two entries with the alias `x`: `x␣` types a space.
- Move the caret inside `brew` and press Space: a space is typed.
- Tab after an alias still fills a quicklink's arguments, as upstream does.
