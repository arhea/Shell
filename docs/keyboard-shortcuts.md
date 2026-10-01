# Keyboard shortcuts

The defaults follow iTerm2, so muscle memory carries over. Every action can be rebound or unbound in Settings › Keyboard Shortcuts. Overrides are saved to `shortcuts` in `settings.json` (see [Configuration](configuration.md)).

The source of truth is `ShortcutAction.defaultShortcut` in [`Sources/Shell/Settings/ShortcutAction.swift`](../Sources/Shell/Settings/ShortcutAction.swift). Update this page when that changes.

## Application

| Action | Shortcut |
| --- | --- |
| Settings… | ⌘, |
| Command Palette… | ⇧⌘P |
| Reload Configuration | ⇧⌘, |
| Agent Activity | ⌥⌘A |
| Homebrew Packages…, Node.js Versions…, Zsh & Oh My Zsh…, MCP Servers…, Check for Updates… | unbound (menu or palette) |

## Windows and tabs

| Action | Shortcut |
| --- | --- |
| New Window | ⌘N |
| New Tab | ⌘T |
| Claude in New Worktree… | ⌥⌘N |
| Close Tab | ⌥⌘W |
| Close Window | ⇧⌘W |
| Show Next / Previous Tab | ⇧⌘] / ⇧⌘[ |
| Move Tab Left / Right | ⌃⇧⌘← / ⌃⇧⌘→ |
| Select Tab 1–8 | ⌘1 – ⌘8 |
| Select Last Tab | ⌘9 |
| Rename Tab… | ⇧⌘I |
| New Tab Group… | ⌃⌘G |
| Toggle Vertical Tabs | ⌃⌘T |
| Show or Hide Tab Sidebar | ⌃⌘S |
| Move Tab to New Window | unbound |

## Split panes

| Action | Shortcut |
| --- | --- |
| Split Right | ⌘D |
| Split Down | ⇧⌘D |
| Close Pane | ⌘W |
| Select Pane Left / Right / Above / Below | ⌥⌘← / ⌥⌘→ / ⌥⌘↑ / ⌥⌘↓ |
| Next / Previous Pane | ⌘] / ⌘[ |
| Maximize Pane | ⇧⌘↩ |
| Broadcast Input to All Panes | ⌥⌘I |
| Equalize Pane Sizes | unbound |

## Terminal

| Action | Shortcut |
| --- | --- |
| Copy / Paste / Select All | ⌘C / ⌘V / ⌘A |
| Copy Last Command | ⇧⌘C |
| Copy Last Output | ⌥⇧⌘C |
| Clear Buffer | ⌘K |
| Find… / Find Next / Find Previous | ⌘F / ⌘G / ⇧⌘G |
| Jump to Previous / Next Command | ⇧⌘↑ / ⇧⌘↓ |
| Scroll to Top / Bottom | ⌘Home / ⌘End |
| Scroll Page Up / Down | ⌘PageUp / ⌘PageDown |

## View

| Action | Shortcut |
| --- | --- |
| Make Text Bigger / Smaller / Normal Size | ⌘= / ⌘- / ⌘0 |
| Toggle Native Prompt | ⌃⌘E |
| Toggle Input Position (Top/Bottom) | ⌃⌘P |
| Focus Native Prompt | ⌥⌘L |
| Toggle Files & Worktrees Sidebar | ⌃⌘B |
| Claude Dashboard | ⌃⌘A |
| Open GitHub (pull request board) | ⌃⌘H |
| Toggle Full Screen | ⌘↩ |

## Other keys

| Where | Key | Does |
| --- | --- | --- |
| Anywhere (when enabled) | ⌥\` | Show or hide the hotkey window. Set it in Settings › General. |
| Native prompt | ⌃R | History search |
| Native prompt | → / ⌘→ / End at the end of the line | Accept the whole ghost-text suggestion |
| Native prompt | ⌥→ | Accept the next word of the suggestion |
| Native prompt | ↑ / ↓ | Step through history |
| Native prompt | Tab | Completions |
| Claude view | ⇧⇥ | Cycle permission mode |
| Claude view | Esc | Interrupt, or dismiss a prompt |
| Claude view | 1 / 2 / 3, Return | Answer a permission prompt |
| Claude view | ⌃D | Return to the shell |
| Terminal | ⌘-click | Open a URL, or reveal a path in Finder |
| File explorer | Space | Quick Look the selected file |
