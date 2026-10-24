# Contributing to Redcast

Redcast is a personal fork of [Tinycast](https://github.com/abue-ammar/tinycast). It is developed
here for its owner's own use, so it does not take outside pull requests or issues. You are welcome
to fork it in turn under the [AGPL-3.0](LICENSE). A fix that belongs to Tinycast itself is best sent
upstream.

What follows is the bar every change in this repository meets, by hand or by an agent.

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
