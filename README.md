# Shell

**A fast, native macOS terminal for people who live in zsh and work alongside coding agents.**

Shell is built in Swift on [libghostty](https://ghostty.org). It combines the parts of Warp and iTerm2 people use most: a real native prompt, zsh completions with previews, iTerm2 keybindings, and flexible tabs and splits. On top of that come first-class tools for Claude Code, Codex, git worktrees and GitHub. There are no accounts, no telemetry and no cloud AI. Optional Apple Intelligence features run on your Mac and stay off until you turn them on.

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black) ![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-black) ![Swift](https://img.shields.io/badge/Swift-AppKit%20%2B%20SwiftUI-orange) ![License: MIT](https://img.shields.io/badge/license-MIT-blue) [![Tests](https://github.com/arhea/Shell/actions/workflows/test.yml/badge.svg)](https://github.com/arhea/Shell/actions/workflows/test.yml)

## Highlights

- **Fast.** Rendering, VT parsing and the PTY come from libghostty: GPU-accelerated Metal, and the same terminal core as Ghostty. The chrome is native AppKit plus SwiftUI.
- **A Warp-style native prompt.** It supports mouse selection, multi-line editing, syntax highlighting, ghost-text history suggestions and ⌃R search. Commands are recorded in scrollback as clean blocks. Turn it off (⌃⌘E) to type straight into zsh.
- **Completions from your real zsh.** Your aliases, functions, plugins and cwd all apply. Results appear in a menu with descriptions and file previews.
- **Tabs your way.** Horizontal or vertical tabs, Chrome-style tab groups, splits, zoom, broadcast input, multiple windows and session restore.
- **iTerm2 shortcuts by default**, all rebindable. About 600 themes, with separate light and dark themes that follow the system.
- **Built for coding agents.**
  - Per-tab spinners, badges and notifications for Claude Code and Codex.
  - A Claude dashboard pinned to the tabs that tiles every running session with its status, directory and branch.
  - A native Claude Code view that drives your own `claude` binary.
  - An MCP server manager.
  - Agent disk-usage cleanup.
- **Git and GitHub in the sidebar.** A file tree with git status. Worktrees with PR state and stale detection. Pull requests and Actions runs through `gh`, with one-click review worktrees.
- **Optional on-device Apple Intelligence** (macOS 26+). It can suggest branch names, tab names and fixes for failed commands, match plain-English commands in the palette, and summarize Claude sessions. Every feature is off until you turn it on, and nothing leaves your Mac.
- **At home on macOS.** Scriptable Shortcuts and Spotlight actions, Finder *New Shell Tab Here*, a Dock menu of waiting agents and recent folders, Quick Look previews, opt-in Time Sensitive agent alerts, and optional iCloud settings sync.
- **Toolchain housekeeping.** Managers for Homebrew, Node.js (`n` / `nvm`, npm, pnpm, yarn, bun), Zsh and Oh My Zsh, and Go caches, with optional scheduled updates.
- **Your dotfiles stay yours.** The zsh integration is injected at launch, not installed. Anything that edits a config file is opt-in, minimal and reversible.

See **[Features](docs/features.md)** for the full tour.

## Install

Shell requires **macOS 15 or later on Apple Silicon**.

Download `Shell-<version>.dmg` from the latest release on the [Releases page](../../releases), open it, and drag Shell to Applications. It's signed with a Developer ID and notarized by Apple. Shell then keeps itself up to date from GitHub releases (Settings › General › Software Update).

To build from source:

```bash
brew install zig xcodegen
```

```bash
make bootstrap
```

```bash
make run
```

`make bootstrap` builds libghostty from a pinned Ghostty commit. It takes about 3 minutes the first time and needs Xcode 26 or later. See [Building from source](docs/building.md) for details and troubleshooting.

New to Shell? **[Getting started](docs/getting-started.md)** walks through the first ten minutes: the native prompt, tabs and splits, agent setup, GitHub and customization.

## Quick start

| Do this | How |
| --- | --- |
| New tab / split right / split down | ⌘T / ⌘D / ⇧⌘D |
| Command palette | ⇧⌘P |
| Toggle the native prompt | ⌃⌘E |
| Toggle vertical tabs | ⌃⌘T |
| Files, worktrees and GitHub sidebar | ⌃⌘B |
| Copy last command / last output | ⇧⌘C / ⌥⇧⌘C |
| Agent notifications | Settings › Claude & Codex › Install |
| Settings | ⌘, |

All bindings are listed in [Keyboard shortcuts](docs/keyboard-shortcuts.md).

## Documentation

| Guide | |
| --- | --- |
| [Getting started](docs/getting-started.md) | Install, first launch, agent and GitHub setup, updating and uninstalling |
| [Features](docs/features.md) | Everything Shell does |
| [Claude Code and Codex](docs/claude-code.md) | Agent hooks, the native Claude view, MCP manager, agent storage |
| [Keyboard shortcuts](docs/keyboard-shortcuts.md) | Default bindings |
| [Configuration](docs/configuration.md) | `settings.json`, Ghostty passthrough, environment variables |
| [Automation](docs/automation.md) | Shortcuts actions for tabs, commands, output and agents |
| [Shell integration](docs/shell-integration.md) | How the zsh integration works, and the control-socket protocol |
| [Architecture](docs/architecture.md) | How the code is organized |
| [Building from source](docs/building.md) | Requirements, make targets, updating Ghostty |
| [Development](docs/development.md) | Debug tooling and code conventions |
| [Troubleshooting and FAQ](docs/troubleshooting.md) | Diagnostics, common problems and answers |
| [Releasing](docs/releasing.md) | Signing and notarization (maintainers) |

## Getting help

Check [Troubleshooting and FAQ](docs/troubleshooting.md) first, then see [SUPPORT.md](SUPPORT.md) for where to ask. Report security issues privately, as described in [SECURITY.md](SECURITY.md).

## Contributing

Contributions are welcome: bug reports, fixes, docs and focused features. Read [CONTRIBUTING.md](CONTRIBUTING.md) to get set up, and follow the [Code of Conduct](CODE_OF_CONDUCT.md). Notable changes are listed in the [changelog](CHANGELOG.md).

## Support Shell

Shell is free and open source, built and maintained in spare time. If it saves you time, you can support its development through [GitHub Sponsors](https://github.com/sponsors/arhea). Sponsorships help cover the Apple Developer Program membership that signing and notarizing releases requires, and the time that goes into new features and fixes.

Not in a position to sponsor? Starring the repo, reporting bugs and telling a friend help too.

## Acknowledgements

Shell includes code from these open-source projects. Thank you to everyone who builds and maintains them.

- **[Ghostty](https://github.com/ghostty-org/ghostty)** by Mitchell Hashimoto and the Ghostty contributors (MIT). libghostty is the engine of Shell: terminal emulation, the Metal renderer, font handling, shell integration and terminfo. Shell wouldn't exist without it.
- **[Zig](https://ziglang.org)** (MIT). libghostty is written in Zig and includes its standard library.
- **[iTerm2-Color-Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes)** by Mark Badolato and contributors (MIT). The roughly 600 bundled themes, via Ghostty.
- **[JetBrains Mono](https://github.com/JetBrains/JetBrainsMono)** (OFL 1.1) and **[Nerd Fonts](https://github.com/ryanoasis/nerd-fonts)** (MIT). The default font and its icon glyphs.
- **[Kitty](https://github.com/kovidgoyal/kitty)** by Kovid Goyal (GPLv3). Its shell integration is the basis for Ghostty's zsh integration, which Shell bundles.
- Libraries built into libghostty: **[Oniguruma](https://github.com/kkos/oniguruma)**, **[simdutf](https://github.com/simdutf/simdutf)**, **[Highway](https://github.com/google/highway)**, **[Wuffs](https://github.com/google/wuffs)**, **[glslang](https://github.com/KhronosGroup/glslang)**, **[SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross)**, **[FreeType](https://freetype.org)**, **[libpng](http://www.libpng.org)**, **[zlib](https://zlib.net)**, and Zig packages including **[libxev](https://github.com/mitchellh/libxev)** and **[z2d](https://github.com/vancluever/z2d)**.

Full license details for every component are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

Shell is released under the [MIT License](LICENSE).

Bundled third-party components keep their own licenses. Notably, Ghostty's shell integration scripts are GPLv3; they ship as separate script files and aren't linked into the app. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
