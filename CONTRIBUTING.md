# Contributing to Redcast

Redcast is a fork of [Tinycast](https://github.com/abue-ammar/tinycast) maintained by
[@alesha-pro](https://github.com/alesha-pro). Issues and pull requests are welcome; what gets merged,
and when, is the maintainer's call. For anything bigger than a fix, open an issue first so the idea
can be settled before you build it. A fix that belongs to Tinycast itself is best sent upstream too.

What follows is the bar every change meets, yours included, whether written by hand or by an agent.

## Non-negotiables

- **Light.** Nothing runs while idle: no resident process, timer, poll or observer that a feature
  does not need right now. The network is used only on the user's action or a schedule they set.
  Memory stays under 100 MB and returns to baseline after the palette closes.
- **No leaks.** No retain cycles; every spawned process is fully torn down.
- **Design.** New UI uses the existing tokens in [`docs/ui.md`](docs/ui.md) and looks like it shipped
  with the app.
- **Upstream stays mergeable.** Fork code lives in its own `Tinycast/Features/<Name>/` folders and
  touches upstream files in as few, commented (`Fork:`) lines as possible. See
  [`FORK.md`](FORK.md#living-with-upstream).
- **The rules in [`AGENTS.md`](AGENTS.md)** hold for every change.

## Setup

- macOS 26+, Xcode 26, an Apple Development signing identity in the keychain.
- After editing `project.yml`: `xcodegen generate`, and commit the result. No SwiftPM.
- Install a build with [`Scripts/fork/install.sh`](docs/fork-tooling.md#scriptsforkinstallsh).
- Details: [`docs/development.md`](docs/development.md). Start at [`docs/`](docs/README.md).

## Done means

- The whole bar in [`docs/testing.md`](docs/testing.md#definition-of-done) passes:
  `./Scripts/run-tests.sh`, `./Scripts/lint.sh`, the purity check and a clean build with no new
  warnings.
- Every user-facing string is in all eight languages, and `node Scripts/fork/rebrand.mjs --check`
  passes.
- The feature's doc in [`docs/features/`](docs/features/) and [`FORK.md`](FORK.md) change in the same
  commit.
- Commits are small and say why.

## Pull requests

- Say what changed and why, what you tested, and anything you are unsure about.
- A visual change comes with before and after screenshots or a short clip.
- Include idle and peak memory if the change touches what runs in the background.
