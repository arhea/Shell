# Security policy

## Supported versions

Security fixes go into the latest release. Please update before reporting, and confirm the issue still reproduces.

| Version | Supported |
| --- | --- |
| Latest release | Yes |
| `main` | Yes (fixes land here first) |
| Older releases | No |

## Reporting a vulnerability

Report security issues privately through GitHub's [private vulnerability reporting](../../security/advisories/new) (the repository's **Security** tab › **Report a vulnerability**). **Don't open a public issue, discussion or pull request.**

Include:

- the Shell version and macOS version;
- the steps to reproduce, and the impact you observed;
- a proof of concept, if you have one.

What to expect:

1. An acknowledgement within a few days.
2. An initial assessment, and updates as we work on a fix.
3. Credit in the release notes and the published advisory, unless you'd rather stay anonymous.

Please give us a reasonable chance to fix the issue before disclosing it publicly. We'll coordinate the disclosure date with you.

## Scope

In scope:

- Shell's own code: the control socket, the zsh integration, `shellctl`, the agent hooks it installs, the App Intents it exposes, and the files it writes.
- Shell's build and release scripts, and the signing and entitlements of released builds.

Out of scope (please report upstream):

- issues in libghostty (report to [Ghostty](https://github.com/ghostty-org/ghostty/security));
- issues in Claude Code, Codex, `gh`, Homebrew and other tools Shell drives;
- attacks that require an attacker who already runs code as your user account. The control socket, like your shell, trusts your user.

## Security model

- **Local control channel.** The control socket (`$SHELL_APP_SOCKET`) is a Unix-domain socket, mode `0600`, inside a `0700` directory. It's reachable only by your user account, the same boundary as your shell. Its `debug` messages can drive the UI, including typing into the focused pane.
- **No telemetry.** Shell sends no telemetry or analytics.
- **Minimal network access.** Shell's own network requests are read-only metadata fetches for features you open. The Node.js manager reads `nodejs.org/dist/index.json`, the Node release schedule, and the latest `nvm` release. Everything else goes through tools you run or enable: `gh`, `git`, `brew`, `n`/`nvm`, `npm`, Claude Code, and the official install scripts for Homebrew, Oh My Zsh, `n`, `nvm` and bun (only when you click Install).
- **No stored credentials.** Sign-in flows (MCP OAuth, `gh`, Claude) are handled by the tools themselves. Shell never reads your Claude credentials.
- **On-device AI only.** The optional Apple Intelligence features use Apple's on-device model. Nothing is sent off the Mac, each feature is off by default, and no suggestion runs by itself.
- **Automation.** Shortcuts actions can type into panes, run commands and read terminal output, the same trust level as Shortcuts' own *Run Shell Script*. See [Automation › Security](docs/automation.md#security).
- **Signed releases.** Release builds are Developer ID-signed with the hardened runtime and notarized by Apple. The entitlements, and why each is needed, are listed in [Releasing › Entitlements](docs/releasing.md#entitlements).
