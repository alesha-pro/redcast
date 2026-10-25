<p align="center">
  <a href="https://redcast.io"><img src="docs/brand/redcast-banner.jpg" alt="Redcast: the palette with “sttngs” typed, System Settings found and the ⌘K action menu open" width="100%"></a>
</p>

<p align="center">
  <strong>An agent-native, Raycast-style launcher for macOS.</strong><br>
  Fast, native and local-first, with your own models and agents.
</p>

<p align="center">
  <a href="https://redcast.io"><img alt="Website: redcast.io" src="https://img.shields.io/badge/website-redcast.io-F23D32?style=flat"></a>
  <a href="LICENSE"><img alt="License: AGPL-3.0" src="https://img.shields.io/badge/license-AGPL--3.0-F23D32?style=flat"></a>
  <img alt="macOS 26 or later" src="https://img.shields.io/badge/macOS-26%2B-F23D32?style=flat&logo=apple&logoColor=white">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F23D32?style=flat&logo=swift&logoColor=white">
  <a href="https://github.com/abue-ammar/tinycast"><img alt="Fork of Tinycast" src="https://img.shields.io/badge/fork%20of-Tinycast-F23D32?style=flat"></a>
</p>

<p align="center"><a href="https://redcast.io"><b>redcast.io</b></a> · <a href="#install">Install</a> · <a href="docs/README.md">Docs</a> · <a href="FORK.md">What's new in the fork</a></p>

Redcast is a launcher for the Mac: one hotkey, a palette, and the apps, text, windows and commands you
reach for all day. It is a fork of [Tinycast](https://github.com/abue-ammar/tinycast), a native SwiftUI
and AppKit launcher that runs real Raycast extensions, and it keeps all of that. What it adds is built
around agents: AI that sees the window in front of you, voice, agents that live in a folder, and the
coding agents you already run (Claude Code, Codex, Gemini CLI, OpenCode, Goose, Hermes), all on your
own keys, logins and machines.

## What Redcast adds

### Agents

- **[Native agents](docs/features/agents.md)**: a chat that lives in a folder, reads its `AGENTS.md`,
  skills and notes, and works there with built-in tools for files, terminal, web and memory, on any
  tool-calling API model. Every change and command is asked first unless the agent's permissions say
  otherwise.
- **[ACP agents](docs/features/agents.md#acp-agents)**: Claude Code, Codex, Gemini CLI, OpenCode,
  Goose, Hermes or any other command runs as its own CLI over the Agent Client Protocol, on your own
  logins, with its diffs, plans, slash commands and model pickers in AI Chat.
- **[Background and scheduled runs](docs/features/background-agents.md)**: `@agent do X` in the
  launcher runs with no window and ends as a chat. Schedules run an agent daily, on working days or
  every few hours while Redcast is open, with an optional daily spend cap.
- **[Agent Sessions](docs/features/agent-sessions.md)**: every past Claude Code, Codex, Gemini CLI,
  OpenCode and Redcast session, searchable from the launcher and resumed in its folder and terminal
  with one key. Opt-in live status shows which agent is waiting for you.

### AI

- **[Web search](docs/features/web-search.md)**: Exa, Parallel or DuckDuckGo with no key, or your
  SearXNG, Brave or Tavily, for agents and every API model in AI Chat and Quick AI; with it on, a chat
  also reads a page you linked or a search found.
- **[Quick AI with tools](docs/features/quick-ai-tools.md)**: web search from Quick AI's ⌘K, and an
  agent of your choice answering there with its tools, folder and permissions.
- **[Screen Awareness](docs/features/screen-awareness.md)**: double-tap right ⌘ and the window in front
  (title, URL, selection, focused field, readable text and, if you allow it, a screenshot) is attached
  to a chat.
- **[Quick Action placeholders](docs/features/quick-actions.md#placeholders)**: `{clipboard}`,
  `{date}` and `{argument}` in your own actions, and ⌘J to continue a result in AI Chat.
- **[Notes and AI](docs/features/notes-ai.md)**: attach a note with `@note`. Agents with the Notes tools
  search, read and append to your notes, and ask before every addition.
- **[Raycast extensions with AI](docs/features/extension-ai.md)**: `AI.ask` and `useAI` are answered by
  your own model, once you allow each extension.
- **[Usage](docs/features/usage-dashboard.md)**: tokens and cost per model or agent for a day, a week
  or a month, counted from what is on this Mac, and your OpenRouter balance on request.

### Voice

- **[Cloud dictation](docs/features/voice-ai.md)**: Gemini Flash on your own OpenRouter, Gemini or
  OpenAI-compatible connection, with spoken punctuation, lists and corrections, the languages you
  speak, your own spellings, and modes (Translate to English, Polish, As a message, or your own) that
  Tab switches mid-dictation.
- **[Ask and Edit by Voice](docs/features/voice-ai.md#ask-by-voice)**: ask about the window in front
  and get the answer beside it or typed into the field, hand the request to an agent, or say how to
  change the selected text.
- **[Dictation History](docs/features/dictation-history.md)**: every transcript kept as text, never
  audio, searchable from the launcher and pasted again with ↵.

### Look and feel

- **[Raycast look](docs/ui.md#colour-the-raycast-palette-fork)**: Raycast's palette and red accent,
  command tiles coloured by family, and a colour for every agent. Settings → General → Appearance →
  Colorful icons brings back Tinycast's tiles.
- **[Alias + Space](docs/features/alias-actions.md)**: type an entry's alias and press Space to open it.
  Change an alias or a shortcut right from ⌘K.

## Kept from Tinycast

The launcher Tinycast built is all here:

- **Launch:** apps, files and folders, Apple Shortcuts, custom shell commands, global and per-app hotkeys
- **Text:** clipboard history with images, snippets with keyword expansion, quicklinks, a calculator
  with units and currencies, the dictionary, an emoji picker
- **Windows:** 35 Rectangle-style actions, saved layouts and rooms, a window switcher, menu bar search
- **Your day:** Markdown notes, your calendar with one-key meeting join, a camera preview
- **System:** lock, sleep, restart, empty the Trash, appearance, Bluetooth and more; uninstall an app
  with everything it left behind
- **AI:** Quick AI and AI Chat on your own keys or installed accounts, MCP servers, Quick Actions on
  selected text, on-device dictation
- **Raycast:** real Raycast extensions rendered as native SwiftUI, import from Raycast, backups and a
  `settings.json` mirror

Each one has its own page in [docs/](docs/README.md#features).

## Light by design

- **Native and small.** SwiftUI and AppKit, no Electron, no third-party dependencies and no
  telemetry, built to Tinycast's 100 MB memory budget.
- **Quiet when idle.** The fork's features wait for you: ACP agents stop after two idle minutes, voice
  keeps no timer or process between presses (a single-key hold shares the one listen-only key tap),
  schedules wait as one sleeping task, and histories and sessions are read when you open them.
- **The network on your terms.** AI requests go to the providers you connect, with your keys and
  logins, when you ask. A Redcast build never checks for updates. Timed requests are the ones you set
  up (a schedule, an extension's background refresh) and the calculator's daily exchange rates.
- **Local data.** Chats, notes, clipboard, dictation history and usage stay on this Mac, and AI is off
  until you connect a provider in Settings → AI.

## Install

Redcast is built from source on your Mac. There are no release downloads, no Homebrew cask and no
auto-updates: to update, pull and run the installer again.

**You need** macOS 26 or later, Xcode 26, and one Apple Development signing identity in your keychain.
Xcode makes one in Settings → Accounts → Manage Certificates, and a free Apple ID is enough; with
several, name yours in `TINYCAST_SIGN_IDENTITY`.

```sh
git clone https://github.com/alesha-pro/redcast.git && cd redcast
git remote add upstream https://github.com/abue-ammar/tinycast.git
git fetch upstream --tags              # About's version counts from upstream's tags
Scripts/fork/install.sh --self-check   # what an install would do; builds nothing
Scripts/fork/install.sh                # build, install /Applications/Redcast.app, relaunch
```

`install.sh` builds a Release for this Mac, signs it with your identity, verifies it, quits the running
Redcast gracefully and swaps the new copy in by rename, so an app is always installed.

- `--self-check` resolves the identity, version and paths and lists the steps; it builds, quits, moves
  and registers nothing.
- `--rollback` puts back the copy the last install replaced, and a second `--rollback` undoes it.
- Privacy grants survive a reinstall: they follow the bundle id and your certificate. A build whose
  code requirement would change is refused; `--accept-new-identity` installs it anyway and prints the
  `tccutil` lines to run.
- Redcast has its own bundle id, `io.redcast.app`, so it keeps its own settings and can sit beside Tinycast.
  A copy installed under the fork's old id (`com.tinycast.app.fork`) moves its settings, data and keys over on
  its first launch ([bundle-migration](docs/features/bundle-migration.md)); macOS asks for privacy grants once more.

Then open Settings → General, record a hotkey and press it anywhere.

## Permissions

Each permission is asked for the first time a feature needs it, and lives in System Settings → Privacy
& Security.

| Permission | Asked when you first |
| :-- | :-- |
| Accessibility | paste from clipboard history, expand a snippet, run a Quick Action, move a window, or read the window in front |
| Microphone | dictate, or ask or edit by voice |
| Screen Recording | turn on a window screenshot for Screen Awareness or voice |
| Calendars | use the calendar and meeting join |
| Automation | run a system action that scripts another app (such as Empty Trash), use Show Info in Uninstall, or resume an agent session in Terminal, iTerm2 or Ghostty |
| Camera, Bluetooth, Reminders | open the camera, toggle Bluetooth, or run an extension that uses reminders |

Full Disk Access is never requested: Search Files needs it and Uninstall uses it for protected
leftovers. Grant it in System Settings → Privacy & Security → Full Disk Access.

Snippets ship off; with them on, what you type is matched against their keywords on your Mac and is
never stored or sent anywhere. Voice audio goes only to the connection you approved and is saved
only when a dictation fails, on this Mac, for at most a week, so Dictation History can retry it.

## Documentation

- [FORK.md](FORK.md): everything the fork ships, its roadmap, and how it lives with upstream
- [docs/](docs/README.md): architecture, standards, testing, the design system and a page per feature
- [docs/fork-tooling.md](docs/fork-tooling.md): `install.sh`, `sync-upstream.sh` and the rebrand script
- [AGENTS.md](AGENTS.md): the short version, for coding agents working on this repository

## Staying in sync with Tinycast

Redcast follows Tinycast's `main`, which lands almost daily. Fork features live in folders of their own
and touch shared files in as few lines as possible, so a sync stays mechanical. `sync-upstream.sh`
merges upstream into a branch of its own, regenerates the Xcode project, merges the string catalogs
key by key, keeps this README as it is, and runs the build, harness and lint gates before anything
lands. How it works is in [docs/fork-tooling.md](docs/fork-tooling.md#scriptsforksync-upstreamsh).

## Credits and license

Redcast is an unofficial fork of [Tinycast](https://github.com/abue-ammar/tinycast) by Abue Ammar. The
launcher and most of its code come from Tinycast, Copyright © 2026 Abue Ammar, and Redcast is
distributed under the same [GNU Affero General Public License v3.0](LICENSE). The app's About window
says so too. Redcast's changes, made from October 2026 on and listed in [FORK.md](FORK.md) and the git
history, are Copyright © 2026 [alesha-pro](https://github.com/alesha-pro) under the same licence.

Ported from other Tinycast forks under the same licence: alias + Space and the extension-runtime fixes
from [sermelipharo/tinycast-space](https://github.com/sermelipharo/tinycast-space), ⌘K alias and
shortcut editing from [jhasubhash/tinycast](https://github.com/jhasubhash/tinycast), and the alias +
Space idea from [mSarheed/pipcast](https://github.com/mSarheed/pipcast). The commits are listed in
[FORK.md](FORK.md#credits).

Third-party work keeps its own licence, recorded in [NOTICE.md](NOTICE.md): window rooms adapted from
[Rooms](https://github.com/saragordic/rooms) by Sara Gordić and the file index after
[fsearch](https://github.com/noahdunnagan/fsearch) by Noah Dunnagan (both MIT), the model brand marks
from Simple Icons, Lobe Icons and OpenCode, and the optional dictation models (NVIDIA Parakeet, CC BY
4.0; Qwen3-ASR, Apache 2.0).

Raycast is a trademark of its owner. Redcast is not affiliated with Raycast, and not endorsed by
Tinycast's author.
