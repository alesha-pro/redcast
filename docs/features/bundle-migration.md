# Bundle id migration (fork)

Redcast builds now use their own bundle id, `io.redcast.app`. Until October 2026 the fork shipped as
`com.tinycast.app.fork`, and everything it stores is keyed by the bundle id: settings
(UserDefaults), Application Support, the `settings.json` mirror's folder, and Keychain items. A copy
installed under the old id moves all of that over on its first launch under the new one.

## What moves, and when

`LegacyBundleMigration.runIfNeeded()` is the first line of `TinycastLaunch.main()`, before anything
reads a setting. It runs once, only for `io.redcast.app`, and records the run in
`legacyBundleMigrationDone`.

| Store | How |
|---|---|
| Settings | The old domain's keys are copied into the new domain. Keys the new id already wrote win. The old domain stays as it was. |
| Application Support | `~/Library/Application Support/com.tinycast.app.fork` is moved to `…/io.redcast.app`, and the old path becomes a symbolic link to it. |
| settings.json | `~/.config/tinycast-fork` is moved to `~/.config/redcast`, and a link is left at the old path. |
| Keychain | Lazily. When `KeychainSecretStore` misses an item under `io.redcast.app.<scope>`, it reads `com.tinycast.app.fork.<scope>`, copies it under the new service and returns it. macOS may ask once to allow the read. A presence check never reads the secret. Removing a key removes both items. |
| Caches | Not moved; they are rebuilt. |

## What does not move

- Privacy grants (Accessibility, Input Monitoring, Screen Recording, Automation, and the Dictation
  helper's Microphone and Speech Recognition) follow the bundle id, so macOS asks for each once more.
- The login item: switch Settings › General › Launch at login off and on.
- Agent Sessions' live status hooks name the bundle id. With live status on, Settings shows them as
  outdated until they are updated there.

## Invariants

- A folder moves only when the old one is a real folder (not a link) and the new one does not exist,
  so a second launch, a half-finished run or newer data is never overwritten.
- The old paths stay valid as links. A rolled-back build (`install.sh --rollback`) and absolute paths
  stored in settings still resolve.
- Upstream's ids and Debug builds never migrate.
- `install.sh` treats an installed copy under `com.tinycast.app.fork` as this fork. It quits that copy
  by its own id, replaces it, unregisters both ids' stale LaunchServices entries, and prints the
  re-grant steps.

## Tests

`bundle-migration-test` covers:
- which ids migrate, and the old Keychain service name;
- which folders move (never into an existing folder, never from a link);
- merging defaults (new keys win);
- a real run in a temporary home: the data moves, the link is left, and a second run does nothing.

## Manual sweep

1. With Redcast installed under the old id, run `Scripts/fork/install.sh`. It reports
   `bundle id com.tinycast.app.fork → io.redcast.app` and the re-grant steps.
2. After the launch, check that chats, notes, the clipboard, agents, hotkeys and settings are all
   there.
3. Check the old Application Support path: `ls -l "~/Library/Application Support/com.tinycast.app.fork"`
   shows a link to `io.redcast.app`.
4. Use an AI connection. macOS may ask to allow the old Keychain item once; after Allow, it never asks
   again.
5. Re-grant the privacy services, then switch Launch at login off and on.
