import AppKit
import SwiftUI

struct ShortcutsSettingsPane: View {
    @State private var filter = ""

    var body: some View {
        let overrides = SettingsStore.shared.settings.shortcuts
        Form {
            Section {
                HStack {
                    TextField("Filter commands", text: $filter).textFieldStyle(.roundedBorder)
                    Button("Restore iTerm2 Defaults") { SettingsStore.shared.settings.shortcuts = [:] }
                        .disabled(overrides.isEmpty)
                }
                Text("Click a shortcut to record a new one. Press ⌫ while recording to clear it, or Esc to cancel. Defaults match iTerm2.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(ShortcutAction.Category.allCases, id: \.self) { category in
                let actions = ShortcutAction.allCases.filter {
                    $0.category == category && (filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter))
                }
                if !actions.isEmpty {
                    Section(category.rawValue) {
                        ForEach(actions) { action in row(action) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ action: ShortcutAction) -> some View {
        let current = action.shortcut
        let conflict = current.flatMap { sc in ShortcutAction.allCases.first { $0 != action && $0.shortcut == sc } }
        return LabeledContent {
            HStack(spacing: 8) {
                if let conflict {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .help("Also assigned to “\(conflict.title)”")
                }
                ShortcutRecorder(shortcut: Binding(
                    get: { action.shortcut },
                    set: { SettingsStore.shared.settings.shortcuts[action.rawValue] = .some($0) }))
                if SettingsStore.shared.settings.shortcuts[action.rawValue] != nil {
                    Button {
                        SettingsStore.shared.settings.shortcuts.removeValue(forKey: action.rawValue)
                    } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .help("Restore default (\(action.defaultShortcut?.displayString ?? "none"))")
                }
            }
        } label: {
            Text(action.title.replacingOccurrences(of: "…", with: ""))
        }
    }
}

/// Click-to-record shortcut field.
struct ShortcutRecorder: View {
    @Binding var shortcut: KeyShortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Type shortcut…" : (shortcut?.displayString ?? "None"))
                .font(.system(size: 12, design: .rounded))
                .frame(minWidth: 96)
                .foregroundStyle(recording ? Color.accentColor : shortcut == nil ? .secondary : .primary)
        }
        .buttonStyle(.bordered)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 0x35 && mods.isEmpty { // Esc
                stop()
                return nil
            }
            if (event.keyCode == 0x33 || event.keyCode == 0x75) && mods.isEmpty { // ⌫ clears
                shortcut = nil
                stop()
                return nil
            }
            // Require a modifier unless it's a function key.
            let isFunctionKey = (0x60...0x7A).contains(Int(event.keyCode))
            guard !mods.isEmpty || isFunctionKey, let sc = KeyShortcut(event: event) else { return nil }
            shortcut = sc
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

struct IntegrationsSettingsPane: View {
    /// App-wide model (observed through property access; not state this view owns).
    private let agents = AgentIntegrations.shared

    var body: some View {
        Form {
            Section {
                Text("Shell tracks Claude Code and Codex running in any tab: a spinner while they work, a badge when they need you, and a native notification when they finish. Click a notification to jump to the pane.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Default agent", selection: setting(\.defaultAgent)) {
                    ForEach(CodingAgent.allCases) { Text($0.displayName).tag($0) }
                }
                Text("Started by the launch button above the prompt: in the current folder, or in a new worktree branched from the default branch (in git repositories).")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Notify me about agent events", isOn: setting(\.agentNotifications))
                if SettingsStore.shared.settings.agentNotifications {
                    Toggle("Make \"needs your input\" alerts Time Sensitive", isOn: setting(\.timeSensitiveAgentAlerts))
                    Text("Time Sensitive alerts can break through Focus when you allow them for Shell in System Settings › Notifications. \"Finished\" alerts stay normal.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Claude Code") {
                Picker("Typing `claude` opens", selection: setting(\.claudeLaunchMode)) {
                    ForEach(ClaudeLaunchMode.allCases) { Text($0.title).tag($0) }
                }
                Text("The native view has a chat transcript with markdown, model, effort and permission-mode pickers, the current directory, branch and worktree, and a file explorer with git status. `claude -p`, subcommands (`claude mcp`, `claude doctor`…) and pickers always use the terminal UI.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Default permission mode", selection: setting(\.claudePermissionMode)) {
                    Text("Claude Code's default").tag("")
                    Divider()
                    ForEach(ClaudePermissionMode.allCases.filter { $0 != .bypassPermissions }) { Text($0.title).tag($0.rawValue) }
                }
                Text("Used by the native view and by sessions started from the Claude button. A --permission-mode you type wins. Claude Code falls back to its default when auto mode isn't available for your plan or model. \"Claude Code's default\" uses permissions.defaultMode from its settings.json.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Chat text") {
                    Button("Fonts & Spacing…") { SettingsWindowController.shared.show(pane: .chatText) }
                }
                Picker("Edit diffs", selection: setting(\.claudeDiffStyle)) {
                    ForEach(DiffStyle.allCases) { Text($0.title).tag($0) }
                }
                Picker("Tool calls", selection: setting(\.claudeToolCalls)) {
                    ForEach(ToolCallDisplay.allCases) { Text($0.title).tag($0) }
                }
                Text("In the native view, collapsed tool calls fold into one row per run (for example \"6 tool calls · Read 3 · Edit 2\"); click it to expand. Questions, plans and to-do lists always show.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show the file explorer in git repositories", isOn: setting(\.claudeFileExplorer))
                Toggle("Trust worktrees of repositories I already trust", isOn: setting(\.claudeTrustWorktrees))
                Text("A worktree of a trusted repository starts in the native view without asking, and is marked trusted in ~/.claude.json. Turn this off if you check out untrusted code (such as pull requests from forks) in worktrees.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Pin a Claude dashboard to the tabs while Claude is running", isOn: setting(\.claudeDashboard))
                Text("Tiles every Claude Code session across your windows with its status, directory, branch and a live preview. Open it with ⌃⌘A.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Turn on Remote Control for every session", isOn: setting(\.claudeRemoteControl))
                Text("Continue any Claude Code session from the Claude app on your phone or claude.ai/code. Applies to the native view and to interactive `claude` launches in the terminal UI (adds `--remote-control`).")
                    .font(.caption).foregroundStyle(.secondary)
                statusRow(agents.claude)
                Text("Adds UserPromptSubmit, Notification, Stop and SessionEnd hooks to ~/.claude/settings.json. A backup is written next to it. Hooks do nothing outside Shell.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if agents.claude == .installed {
                        Button("Remove Hooks") { agents.uninstallClaude() }
                    } else {
                        Button("Install Hooks") { agents.installClaude() }.buttonStyle(.borderedProminent)
                    }
                    Button("Open settings.json") { NSWorkspace.shared.open(agents.claudeSettingsURL) }
                        .disabled(!FileManager.default.fileExists(atPath: agents.claudeSettingsURL.path))
                }
            }
            Section("Codex") {
                statusRow(agents.codex)
                if case .conflict(let line) = agents.codex {
                    Text("config.toml already has: \(line)").font(.caption.monospaced()).foregroundStyle(.orange)
                }
                Text("Sets the top-level `notify` program in ~/.codex/config.toml (backup written). Codex calls it when a turn completes.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    switch agents.codex {
                    case .installed:
                        Button("Remove") { agents.uninstallCodex() }
                    case .conflict:
                        Button("Replace Existing notify") { agents.installCodex(replace: true) }
                    default:
                        Button("Install") { agents.installCodex(replace: false) }.buttonStyle(.borderedProminent)
                    }
                    Button("Open config.toml") { NSWorkspace.shared.open(agents.codexConfigURL) }
                        .disabled(!FileManager.default.fileExists(atPath: agents.codexConfigURL.path))
                }
            }
            if let err = agents.lastError {
                Section { Text(err).foregroundStyle(.red).font(.caption) }
            }
            Section("Other tools") {
                Text("Any script can notify through Shell. Inside a Shell tab:")
                    .font(.callout)
                Text("shellctl notify -t \"Build\" \"Finished in 42s\"\nshellctl agent other needs-input \"Waiting for approval\"")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
                Text("`shellctl` is available as $SHELL_APP_CTL. Programs that emit OSC 9 / OSC 777 notifications are also shown natively.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { agents.refresh() }
    }

    private func statusRow(_ status: AgentIntegrations.Status) -> some View {
        LabeledContent("Status") {
            switch status {
            case .installed: Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .notInstalled: Label("Not installed", systemImage: "circle").foregroundStyle(.secondary)
            case .conflict: Label("Another notify program is set", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .unavailable(let why): Label(why, systemImage: "xmark.circle").foregroundStyle(.secondary)
            }
        }
    }
}
