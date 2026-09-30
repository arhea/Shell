# Shell integration

Shell's native prompt, completions, command blocks and notifications depend on a small zsh integration. It's loaded automatically and doesn't modify your dotfiles.

zsh is the only shell with the integration. Other shells (set in Settings › Advanced) work as plain terminals without the native prompt, completions or command tracking.

## How it loads

1. Shell starts zsh with `ZDOTDIR` pointing at `Shell.app/Contents/Resources/shell/zsh`.
2. That directory's `.zshenv` restores your real `ZDOTDIR` (saved in `SHELL_APP_ORIG_ZDOTDIR`) and sources your own `.zshenv`.
3. It loads Ghostty's zsh integration (prompt marks, titles, ssh `TERM` handling), then Shell's [`shell-integration.zsh`](../Resources/shell/zsh/shell-integration.zsh).
4. Setup is deferred to the first prompt, so it runs **after** your `.zshrc`, themes and plugins.

To load it in shells that Shell didn't start directly (tmux, `exec zsh`), add this to your `.zshrc`:

```zsh
[[ -n $SHELL_APP_RUNTIME ]] && source "${SHELL_APP_CTL:h:h}/shell/zsh/shell-integration.zsh"
```

## What it does

- **Reports state** over the control socket using `zsocket` (no forks per prompt): prompt shown, command started, exit status, working directory and git branch.
- **Installs three zle widgets**, triggered by private key sequences the app writes to the PTY:

| Sequence | Widget | Reads |
| --- | --- | --- |
| `ESC [ 9001 ~` | Run the command the editor wrote | `$SHELL_APP_RUNTIME/<id>.cmd` |
| `ESC [ 9002 ~` | Capture completions for a buffer | `<id>.req` |
| `ESC [ 9003 ~` | Apply settings live (for example prompt style) | `<id>.cfg` |

- **Hides zsh's prompt while idle** when the native prompt is on, and records each command in scrollback as a `header ❯ command` block.
- **Wraps `claude`** so Shell can offer the native Claude Code view (see [Claude Code and Codex](claude-code.md)).

## Control socket protocol

`ControlServer` listens on a Unix-domain socket (`$SHELL_APP_SOCKET`, mode `0600`, inside a `0700` directory). Each connection carries one batch of messages, and the client writes and then closes.

- Records are separated by newlines. Fields are separated by tabs.
- `\`, newline and tab are escaped inside fields as `\\`, `\n` and `\t`.
- Field 1 is the message type. Field 2 is the session ID.

| Type | Sent by | Meaning |
| --- | --- | --- |
| `init` | integration | Integration is ready in this session |
| `prompt` | integration | A prompt was shown (exit status, cwd, branch) |
| `exec` | integration | A command started |
| `comp` | integration | Completion results |
| `agent` | `shellctl` | Agent status: `claude`, `codex` or `other` × `working`, `needs-input`, `finished` or `ended` |
| `claude` | integration | `claude` was typed; asks the app which UI to open |
| `notify` | `shellctl` | Post a notification tied to this tab |
| `debug` | `shellctl debug` | Development commands (see [Development](development.md)) |

The socket is only reachable by your user (it has the same trust boundary as your shell). Note that the `debug` messages can drive the UI, including typing into the focused pane. See [Development](development.md).

## shellctl

`shellctl` (`$SHELL_APP_CTL`) is a small zsh script that speaks the protocol above:

```
shellctl notify [-t TITLE] MESSAGE...   Post a notification tied to this tab
shellctl agent KIND EVENT [MESSAGE]     KIND: claude|codex|other
                                        EVENT: working|needs-input|finished|ended
shellctl claude-hook EVENT              Claude Code hook (reads hook JSON on stdin)
shellctl codex-notify JSON              Codex `notify` program
shellctl debug ...                      Development commands
```

Outside Shell (no `$SHELL_APP_SOCKET`) every command exits silently.
