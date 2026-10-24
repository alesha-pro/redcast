# Extension Store

**Extension Store** (Russian «Магазин расширений») is a launcher command that browses the Raycast
Store in the palette, the way Clipboard History or Agent Sessions list their own things. With
nothing typed it opens on shelves, **Featured**, **Popular**, **Recently Updated** and **New**,
and then every **category**; typing searches the whole catalog. Each row shows the extension's
icon, title, author, downloads and last update, with an **Installed** or **Update** badge, and the
preview beside the list has its description, commands, categories, author, downloads, dates and a
link to its store page. ↵ installs, updates or opens it through the same install and uninstall
paths Settings uses. It is the fork's own, kept to `Features/ExtensionStore/` plus the `Fork:`
lines listed under [Upstream touches](#upstream-touches); Settings' **Search extensions** panel
keeps working as it was, with an **Open Extension Store** button beside Done.

## Invariants

- **Nothing at launch, nothing in the background.** `AppCore.start()` only shows or hides the
  command, from `extensionsEnabled`. There is no timer, poll or watcher: the cache is read and the
  store is fetched only when the screen opens, and again only on **Refresh Store** (⌘R).
- **One day of cache, in Caches.** A whole catalog is trimmed to the fields the screen shows and
  written to `extension-store.json` in the bundle id's Caches folder (about 2.3 MB for 3,400
  extensions, against some 15 MB of raw pages). An open reads it off-main; younger than 24 hours
  it is all the open costs, older (or stamped in the future) it shows at once while the store is
  fetched behind it, with a spinner beside the search field. A partial fetch is never cached, and
  never replaces a whole catalog already listed. The system may purge the file; the next open
  simply fetches.
- **Freed when the screen closes.** `ExtensionStoreIndex.close()` runs from the screen's
  `onDisappear` and drops the catalog, its search keys, remote results and the list being browsed,
  and the fetch still running is cancelled. A palette hidden over the screen keeps it until the pop
  to root, as Agent Sessions does. Only an install's progress line outlives the screen, since the
  install does.
- **Someone else's endpoints, decoded softly.** Every field is optional; an entry that fails to
  decode, a field of the wrong type, a number spelled as a string, an `http` icon and an unknown key
  are each skipped or defaulted rather than failing the page. An entry is listed only when it is
  `active`, not kill-listed, and macOS is among its platforms (none listed means macOS-only).
- **A private ephemeral session.** `ExtensionStoreFetcher` fetches on its own `.ephemeral`,
  `urlCache = nil` session, as `ExtensionStoreClient` does, so the trimmed cache is the only copy
  on disk. Icons go through `ExtensionIconCache.loadRemoteAsync`, the extensions' own in-memory
  icon cache and cacheless session, and only for rows that are drawn.
- **Installs go through the existing paths.** Install and Update look the extension up again with
  `ExtensionStoreClient.lookup` (the store signs each download URL, so a cached one is never used)
  and hand the listing to `ExtensionManager.install`, which records its commit exactly as Settings'
  panel does. Uninstall is `ExtensionCoordinator.confirmUninstall`, Tinycast's own dialog first. The
  command is listed only while extensions are enabled, since enabling them is the consent to run
  third-party code; turning them off closes the screen.
- **Update means a newer commit.** A row says Update when the install came from the store and the
  commit it recorded differs from the store's, or when Settings' update check already found it
  behind. A folder or GitHub install, or an import whose commit is not known yet, says Installed.
- **No settings, no backup.** The feature adds no preference key; the command's alias, shortcut and
  visibility are the launcher's own, set in Settings › Extensions › Install. The cache is
  regenerable and travels in no backup.

## Layout

| File | Holds |
| --- | --- |
| `Model/ExtensionStoreEntry.swift` | One trimmed entry, and the lossy decoder every endpoint's page goes through |
| `Model/ExtensionStoreEndpoint.swift` | The three endpoints' URLs and how many catalog pages follow the first |
| `Model/ExtensionStoreCatalog.swift` | The catalog with its featured order and fetch date, freshness, and the cache file's format |
| `Model/ExtensionStoreShelves.swift` | Browse lists, sections and rows; the shelves, each full list and the category counts |
| `Model/ExtensionStoreQuery.swift` | Folded search keys and the ranking |
| `Model/ExtensionStoreInstallState.swift` | Available, Installed or Update, from the installed set and recorded commits |
| `Service/ExtensionStoreFetcher.swift` | The ephemeral session: catalog pages four at a time, the listing, popular pages, search |
| `Service/ExtensionStoreCache.swift` | `extension-store.json` in Caches: read, and write only a whole catalog |
| `UI/ExtensionStoreCoordinator.swift` | The command, open and close, the fetch, remote search, browse, install, open, uninstall |
| `UI/ExtensionStoreIndex.swift` | The open screen's catalog, keys, phase, remote results and install progress |
| `UI/ExtensionStoreScreen.swift` | The palette screen, its header chip and its ⌘K menu |
| `UI/ExtensionStoreList.swift`, `UI/ExtensionStorePreview.swift`, `UI/ExtensionStoreIcon.swift` | Rows under section headers, the preview with its Information block, the artwork |

## The endpoints

All three are unofficial and answer pages of the same entry shape (`id`, `name`, `title`,
`description`, `author`, `owner`, `icons`, `commands`, `categories`, `download_count`, `created_at`
and `updated_at` in unix seconds, `is_new`, `commit_sha`, `platforms`, `status`, `kill_listed_at`,
`store_url` and more, which are ignored).

| Endpoint | Used for |
| --- | --- |
| `www.raycast.com/frontend_api/extensions/search?q=&page=N&platform=macOS&per_page=200` | The whole macOS catalog, unordered (about 3,400 entries, 18 pages); with a query, the search a cold open falls back to |
| `www.raycast.com/frontend_api/extensions?page=N` | Every platform's extensions by downloads, ten a page; pages 1 and 2 are a cold open's first Popular shelf. `sort`, `category` and `per_page` are ignored |
| `backend.raycast.com/api/v1/store_listings?per_page=100&page=1` | Raycast's own curated order: the Featured shelf |
| `www.raycast.com/api/v1/extensions/<owner>/<name>` | The lookup an install makes, through `ExtensionStoreClient` |

A fetch asks for the catalog's first page, reads `total_results`, then the rest four at a time (at
most 40 pages), alongside the listing; a cold open with nothing cached first shows the listing and
two popular pages as Featured and Popular, then the whole catalog. A later page that fails leaves
the catalog partial: it is listed, says "Part of the store didn't load.", and is not cached.

## The screen

```
┌─ 🏬 Search extensions…                         [Developer Tools ✕]  ⟳ ─┐
│ Featured                       │  [icon] Google Translate          ✓   │
│  [icon] Google Translate   ✓   │         gebeto                        │
│  [icon] Spotify Player         │  Simple translation using Google…     │
│  …                             │  Commands                             │
│ Popular                        │   Translate · Translate Form · …      │
│  [icon] Kill Process  Roland L…│  Information                          │
│  …                             │   Author · Downloads · Categories ·   │
│  ≡ Show All            3,411   │   Published · Updated · Store page    │
│ Recently Updated · New         │                                       │
│ Categories                     │                                       │
│  ▦ Productivity        1,479   │                                       │
└────────────────────────────────┴───────────────────────────────────────┘
```

- **Shelves.** Featured is the store listing's order; Popular, Recently Updated and New (published
  in the last 14 days, or flagged `is_new`) are the catalog's own orderings. Each shows six rows,
  skipping any a shelf above already showed, and ends in a **Show All** row with the full count; a
  shelf left with nothing is dropped. While the catalog is partial only Featured and Popular show.
- **Categories** follow, largest first, each with its count. ↵ on a category or a Show All row
  lists all of it under its own header, with its name in a chip beside the search field; typing
  then searches inside it. Escape or Backspace on an empty query, the chip's ✕, or ⌘K's **Show
  All Lists** goes back to the shelves before Escape leaves the screen.
- **Search.** Once the whole catalog is loaded, typing ranks it locally: the title's exact, prefix,
  word-start and substring matches, then the slug (`kill-process` is found by "kill process"), then
  every word somewhere in the title, author, handle, categories, command titles or description;
  downloads break ties. Before that, a query waits 300 ms and asks the search endpoint for 50.
- **Rows** show the icon, title, author, ↓ downloads and the day of the last update, and on the
  right Installed, Update, or the install's progress. The preview adds the description, the
  commands with their descriptions, and Author, Downloads, Categories, Published, Updated and a
  Store page link; a failed install says why there.

| Key | Does |
| --- | --- |
| ↵ | Install; **Update** when the store has a newer commit; **Open Extension** once it is current. On a list row, show it |
| ⌘↵, ⌘O | Open the store page in the browser |
| ⇧⌘C | Copy the store link |
| ⌃X | Uninstall…, after Tinycast's own dialog |
| ⌘R | Refresh Store: the whole catalog again, whatever the cache's age |
| ⌘K | All of the above, plus Show in Settings, Browse Category for each of the extension's categories, and Show All Lists |
| ⎋ / ⌫ | Leave the list being browsed, then the screen |

**Open Extension** runs the extension's command when it has one; with several it returns to root
search seeded with the extension's title, where its commands are listed by their owner, or, when
extensions are kept out of the launcher, it shows the extension in Settings › Extensions.

## Upstream touches

Every one carries a one-line `Fork:` comment.

- `CommandID` — `extensionStore` (`command:extension-store`), its name, `storefront` glyph and
  keywords: store, extensions, raycast store, install extensions, and "store" and "extensions" in
  the interface's language (магазин, расширения).
- `CommandCatalog` — `.extensions` owns it, so its row is in Settings › Extensions › Install.
- `GlyphCategory` — the `app` family.
- `PaletteMode` — `extensionStore`, its symbol and prompt; `RootPaletteView` builds the screen and
  lets Escape on an empty query leave the list being browsed; `PaletteWindowController` does the
  same for a bare Backspace.
- `LauncherCoordinator` — the command shows the screen.
- `AppCore` — the lazy coordinator, its `applyEnabled()` in `start()`, and a `track` of
  `extensionsEnabled`.
- `ExtensionManager.storeCommits` and `ExtensionVersionStore.commits` — the recorded commit per
  store install, read for the Update badge.
- `ExtensionsSettingsView` — the command's row under Install; `ExtensionStorePanel` — the **Open
  Extension Store** button; `SettingsSearchCatalog` — its entry.

## Tests

`extension-store-test` compiles `ExtensionStore/Model/*`, `ExtensionStoreCache`,
`SearchRelevance`, `ExtensionListing`, `ExtensionStoreResponse` and `AppPaths`, and runs offline on
`Tests/extension-store-fixtures/`: trimmed pages of all three endpoints as probed on 2026-10-24
(download URLs replaced) and a hand-written hostile page. It covers decoding each endpoint,
the entries a hostile page keeps and drops, what is not a page, the endpoint URLs and page count,
the catalog's dedupe, the cache's round trip, a later build's and a broken cache, writing only a
whole catalog, freshness, the shelves and their dedupe and Show All rows, a partial catalog, every
full list's order, category counts and the filter, search ranking and every-word search, and the
install state from recorded commits.

## Manual sweep

- With extensions enabled, type "store", "Extension Store" or "магазин" in a Russian interface: the
  command is found. Disable extensions: it leaves the launcher, and an open store closes.
- Remove `~/Library/Caches/<bundle id>/extension-store.json` and open the store: "Loading the
  Raycast Store…", then Featured and Popular, then every shelf and category, with the spinner
  beside the search field until the file is written. Close and reopen: the shelves are there at
  once, with no spinner and no request (a proxy or Little Snitch shows none).
- Set the file's `fetchedAt` back two days (or the clock forward), reopen: the old catalog shows at
  once and refreshes behind the spinner. ⌘R refreshes on demand.
- Turn Wi-Fi off with no cache: "Couldn't reach the Raycast Store" with the error; ⌘R after
  reconnecting loads it. With a cache, offline, the catalog shows and the preview names the failed
  refresh.
- Type "github" while the catalog is still loading: "Searching…", then the search endpoint's
  results; once loaded, results are local and instant.
- ↵ on Developer Tools: its extensions by downloads under its own header, the chip beside the
  field; type to search inside it; Escape returns to the shelves, a second Escape leaves the store.
- Install an extension with ↵: the row shows Downloading… and Installing…, a HUD says it is
  installed, the badge reads Installed and ↵ now opens it. Its commands are in the launcher.
- Uninstall it with ⌃X: Tinycast's dialog asks first; Cancel keeps it.
- Install an older build of a store extension by hand (or edit `extension-versions.json` to an old
  commit): the row says Update, ↵ updates it, and preferences survive.
- ⌘↵ opens the store page; ⇧⌘C copies `https://www.raycast.com/<owner>/<name>`.
- Settings › Extensions: the Extension Store row binds an alias and a shortcut; the shortcut opens
  the store from any app. Search extensions… still searches and installs, and its Open Extension
  Store button closes the panel and opens the palette on the store.
- Close the palette and pop to root, then check Activity Monitor: no thread, timer or network
  activity remains, and memory returns to where it was before the store opened.
