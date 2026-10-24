# Chat files

An agent's reply names what it made — "the assets are in `posts/gpu-unlock-ada/assets/`", then
`card-1-ada.png` — and every one of those names that exists on disk is a link. A click opens the
file in its default app or the folder in Finder; anything that would run is shown in Finder instead.
Under the finished reply a **Files** strip lists what it named or wrote, with a thumbnail for an image
and the Finder icon for anything else. It works in AI Chat's window, in Quick AI, in background agent
runs (they are AI Chat chats) and in Agent Sessions' preview. The feature is this fork's, in
`Features/ChatFiles/` plus marked lines in `ChatMarkdownRenderer`, `ChatMarkdownText`
(`ChatSelectableTextView`) and `ChatTranscriptView`, the session cwd in `AgentSessionPreview`, and
one bullet in the native agent's How to work (`AgentSkill`).

## Invariants

- **Only what exists is a link, and nothing else changes look.** A mention becomes a link only when
  `ChatFileResolver` found an item at the path it resolves to; a name that resolves nowhere, a path
  in a fenced code block, a command in backticks and every web link render exactly as before. The
  link takes the accent ink web links take, keeps the code span's monospace and fill, and is led by
  a small accent icon of what it is (folder, image, document, script, app).
- **A click never runs anything.** `ChatFileActions.activate` re-reads the item at the click and goes
  through `ChatFileOpenPolicy`: a folder opens in Finder; an image or document opens with its default
  app; an app or other code bundle (`.app`, `.bundle`, `.prefPane`, `.workflow`, …), a script or
  installer by extension (`.sh`, `.command`, `.tool`, `.py`, `.pkg`, `.dmg`, `.webloc`,
  `.mobileconfig`, …), and any `+x` file whose extension is not a known document's are revealed in
  Finder. So is a file whose default app is one that runs what it is handed (Terminal, iTerm,
  Installer, Script Editor, Shortcuts, Python Launcher, System Settings, Keychain Access, …) or that no
  app claims. Open With lists only apps outside that set. A file link is only ever a `file:` URL the
  renderer set from a resolved item: the reply's own `file:` and app-scheme links stay plain text, as
  upstream keeps them, and `ChatSelectableTextView.clicked(onLink:at:)` hands every `file:` link to
  `ChatFileActions` before AppKit could open it.
- **Resolution is per finished reply, never per token.** `chatFiles(for:)` builds a
  `ChatFileRequest` only once the message is no longer streaming, and `.task(id:)` resolves it off the
  main actor (`ChatFileSystem.resolve`, `@concurrent`) when the reply finishes or its transcript comes
  into view. The result lives in the reply view's `@State` and goes with it. Nothing runs at launch;
  there are no watchers, timers or caches of its own.
- **A few lookups per reply.** At most 48 mentions are read; each path is looked up once per
  resolution (memoised), a bare name in at most four named folders, the chat's folder and the calls'
  matching paths; at most 16 written files are added. A lookup is one `fileExists` plus an
  `isExecutableFile` or `isPackage` read.
- **`Features/ChatFiles/Model/` is Foundation-only and filesystem-free.** Scanning, resolution and
  the open policy take `stat`, the home folder and the chat's folder as parameters;
  `Tests/chat-files-test.swift` runs them against a temp folder.

## How a mention is found

`ChatFileMentions.scan` reads the reply text with fenced blocks blanked out and keeps, in reply order
and each text once:

- **Markdown links** whose target is a `file:` URL or has no scheme (`[report](out/report.pdf)`,
  `[it](<~/My Notes/plan.md>)`); the target is percent-decoded and loses `#anchor` and `?query`.
- **Inline code** that reads as a path: a slash in it, or a name with an extension, with no shell
  characters (`` ` $ | ; & < > * ? { } = ``), not a flag; a `:line` or `:line:column` suffix is
  dropped (`Sources/App.swift:42`).
- **Bare absolute and `~/` paths in prose** that start a word, so `km/s`, `and/or` and the path of an
  `https://` URL are not paths; trailing punctuation is left off.

The renderer meets each of these again run by run (`ChatFileLinker.link` reads a run's link, its
code intent or its text with the same three functions), so the key a mention resolved under is the
key its run looks up.

## How a mention resolves

`ChatFileRequest` carries the reply, the chat's folder — the agent's `directory`, which is the cwd its
tools and an ACP agent's `session/new` run in, or a session's own `directory` in Agent Sessions'
preview (`chatFilesDirectory`) — the home folder, every call's row title, and the paths of an ACP
call's diffs. A plain chat has no folder.

1. `~` and `~/…` expand into the injected home; absolute paths stand; a path with a slash resolves in
   the chat's folder. `.`, `..` and repeated slashes fold away.
2. Folders found that way are the reply's **named folders**.
3. A relative path that did not resolve is tried inside each named folder.
4. A **bare name** (`card-1-ada.png`) is tried in each named folder, then in the chat's folder, then
   among the paths the calls touched with that last component (`write_file: assets/card.png`,
   `run_command: make --out out/report.pdf`, `Write /tmp/card.png`).

The Files strip lists what the reply named, in its order, then what its calls wrote — an ACP diff's
path, or the first path of a `write_file`, `edit_file`, `Write`, `Edit`, `MultiEdit`, `Create` row —
each item once. A strip of more than six shows five and a `+N` chip that expands it and turns into
Show Less.

## What a link and a chip do

| | Inline link | Files chip |
| --- | --- | --- |
| Click | open, or reveal what would run | the same |
| Right click | Open, Open With ▸, Show in Finder, Quick Look, Copy Path | the same menu |
| Quick Look | from the menu | the eye that fades in on hover, Space on a focused chip, or the menu |
| Full path | tooltip | tooltip |

Open is left out of the menu for anything the policy reveals, and Open With for folders and revealed
items. Quick Look shows `ChatQuickLookPanel`, Tinycast's own panel around a `QLPreviewView`, centred
over the chat as its child window: the same item again, Space or Escape (when it has the keyboard),
its close button, or its chat closing closes it, and the preview closes with it. Over Quick AI it
never takes the keyboard, since the palette hides when it loses it; there, and in the window, it is
ordered out with its parent. One panel shows at a time.

A link's icon is an attachment that copies as nothing (it carries `ChatMarkdownRenderer.mathSource`
`""`), so a copied path reads as the reply wrote it. A chip's picture comes from
`FilePreviewThumbnail` for an image and `IconCache` for anything else, loaded when the chip appears.

## Agents cite exactly

The native agent's How to work (`AgentContext.method`) asks it to name every file or folder it creates
or changes by its absolute path, in backticks or as a Markdown link, so its links resolve without a
guess. ACP agents get no such line; their replies resolve through the chat's folder, named folders and
their calls' titles and diffs alone.

## Files

| File | Holds |
| --- | --- |
| `Model/ChatFileMentions.swift` | finding links, code spans and bare paths in a reply; a call row's paths |
| `Model/ChatFileResolver.swift` | `ChatFileRequest`, `ChatFileLinks`, resolution and the strip's cap |
| `Model/ChatFileOpenPolicy.swift` | `ChatFileItem`, its kind, and what a click may open |
| `Service/ChatFileSystem.swift` | the real `stat` and the off-main resolve |
| `UI/ChatFileLinker.swift` | the renderer's file links and their icons |
| `UI/ChatFileActions.swift` | open, reveal, Quick Look, copy, and the menu |
| `UI/ChatQuickLookPanel.swift` | the preview panel |
| `UI/ChatFilesStrip.swift` | `chatFiles(for:)`, the environment keys and the Files strip |

## Manual sweep

- An agent chat whose folder holds `posts/x/assets/` with images and an HTML file: ask it to list
  them as the screenshot reply did (folder in backticks, then bare names). The folder and each name
  are accent links with icons; the strip shows the folder and the files, images as thumbnails.
- Click an image: it opens in Preview. Click the folder: Finder opens it. Click the HTML file: it
  opens in the browser.
- Ask for a `.sh` or `.command` file, or name an app (`/Applications/Calculator.app`): the click and
  the chip reveal it in Finder; Open is missing from its menu.
- Right-click a link and a chip: Open, Open With (apps listed, no Terminal), Show in Finder, Quick
  Look, Copy Path; Copy Path pastes the absolute path.
- Quick Look from a chip's eye: the panel opens over the chat; Space closes it; the eye on another
  chip replaces the preview; closing the chat window closes it.
- Quick AI with an agent: the same reply links and strips; Quick Look stays over the palette without
  hiding it, and the palette hiding takes the panel with it; opening a file hides the palette.
- A plain chat that writes `~/Desktop/x.txt` or an absolute path links it; a relative path in a
  plain chat stays plain.
- Mentions of missing files, `npm run build` in backticks and paths inside a fenced block stay plain;
  web links and citations still open in the browser.
- Select text across a link and copy: the paste has the path and no stray character.
- A reply naming ten files shows five chips and `+5`; `+5` expands to all and Show Less folds back.
- While a reply streams nothing is linked; the links and strip appear once it finishes, and a
  reopened chat shows them again.
- Agent Sessions: a Claude Code session's preview links paths relative to its project folder.
