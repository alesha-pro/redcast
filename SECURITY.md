# Security Policy

Redcast is a personal fork of [Tinycast](https://github.com/abue-ammar/tinycast), built from source on
its owner's Mac. There are no releases or downloads to patch.

## Reporting a vulnerability

Report privately through GitHub: **Security** tab → **Report a vulnerability**. Include your macOS
version, the Redcast commit (Settings → About shows it), reproduction steps and the impact. Please
don't disclose it publicly until it's fixed.

A vulnerability that also affects Tinycast belongs upstream too.

## Scope

Of particular interest:

- **Accessibility (TCC)** — anything that widens what the paste or Screen Awareness grants enable.
- **Agents** — a tool call that runs, writes or fetches without the consent its agent's permissions
  require, or reaches outside the agent's folder or access level.
- **Clipboard history and dictation history** — text and images on disk; unintended exposure.
- **Network** — every networked feature is consent-gated. A path that reaches the network without
  consent, or survives consent being withdrawn, is high severity.
- **Keys** — API keys live in the Keychain; anything that sends one to a host other than its own.
- **Hotkeys** — the in-house hotkey stack and the Input Monitoring grant.

Out of scope: anything that needs existing code execution or admin rights on the machine.
