import AppKit
import SwiftUI

struct GeneralSettingsPane: View {
    var body: some View {
        let s = SettingsStore.shared.settings
        Form {
            Section("Appearance") {
                Picker("Mode", selection: setting(\.appearance)) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Shell uses separate light and dark themes and switches with the system. Pick them in Themes & Colors.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Startup & Quit") {
                Toggle("Restore windows, tabs and splits on launch", isOn: setting(\.restoreSession))
                Toggle("Confirm before quitting with running processes", isOn: setting(\.confirmQuitWithRunningProcesses))
            }
            Section("New Tabs") {
                Picker("Working directory", selection: setting(\.newTabDirectory)) {
                    ForEach(NewTabDirectory.allCases) { Text($0.title).tag($0) }
                }
                if s.newTabDirectory == .custom {
                    HStack {
                        TextField("Folder", text: setting(\.customDirectory))
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            if panel.runModal() == .OK, let url = panel.url {
                                SettingsStore.shared.settings.customDirectory = url.path
                            }
                        }
                    }
                }
                Picker("Position", selection: setting(\.newTabPlacement)) {
                    ForEach(NewTabPlacement.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Notifications") {
                Toggle("Notify when a long-running command finishes", isOn: setting(\.notifyCommandFinished))
                if s.notifyCommandFinished {
                    Stepper(value: setting(\.commandFinishedThreshold), in: 1...600, step: 5) {
                        Text("After \(Int(s.commandFinishedThreshold)) seconds")
                    }
                }
                Toggle("Only when Shell or the pane isn't focused", isOn: setting(\.notifyOnlyWhenInactive))
                Toggle("Play sound", isOn: setting(\.notificationSound))
                Button("Send Test Notification") {
                    NotificationManager.shared.post(title: "Shell", body: "Notifications are working.", session: nil, force: true)
                }
            }
            SoftwareUpdateSection()
            SettingsSyncSection()
            Section("Hotkey Window") {
                Toggle("Show a terminal from anywhere with a global shortcut", isOn: setting(\.hotkeyWindow))
                if s.hotkeyWindow {
                    LabeledContent("Shortcut") {
                        ShortcutRecorder(shortcut: Binding(
                            get: { SettingsStore.shared.settings.hotkey },
                            set: { SettingsStore.shared.settings.hotkey = $0 }))
                    }
                    Text("The window slides down from the top of the screen, like iTerm2's hotkey window.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct TextSettingsPane: View {
    @State private var families: [String] = []

    var body: some View {
        let s = SettingsStore.shared.settings
        Form {
            Section("Font") {
                Picker("Family", selection: setting(\.fontFamily)) {
                    Text("JetBrains Mono (built in)").tag("")
                    Divider()
                    ForEach(families, id: \.self) { Text($0).tag($0) }
                }
                Stepper(value: setting(\.fontSize), in: 6...48, step: 0.5) {
                    LabeledContent("Size", value: String(format: "%.1f pt", s.fontSize))
                }
                LabeledContent("Line height") {
                    Slider(value: setting(\.lineHeight), in: 0.8...1.8, step: 0.05) { EmptyView() }
                    Text(String(format: "%.2f×", s.lineHeight)).monospacedDigit().frame(width: 48)
                }
                LabeledContent("Letter spacing") {
                    Slider(value: setting(\.letterSpacing), in: 0.8...1.4, step: 0.02) { EmptyView() }
                    Text(String(format: "%.2f×", s.letterSpacing)).monospacedDigit().frame(width: 48)
                }
                Toggle("Ligatures", isOn: setting(\.ligatures))
                Toggle("Thicken strokes (better on low-DPI displays)", isOn: setting(\.fontThicken))
            }
            Section("Cursor") {
                Picker("Style", selection: setting(\.cursorStyle)) {
                    ForEach(CursorStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Blink", isOn: setting(\.cursorBlink))
            }
            Section("Preview") {
                FontPreview()
            }
        }
        .formStyle(.grouped)
        .task {
            families = await Task.detached {
                NSFontManager.shared.availableFontFamilies.filter { family in
                    guard let font = NSFont(name: family, size: 12) ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12) else { return false }
                    return font.isFixedPitch || family.localizedCaseInsensitiveContains("mono") || family.localizedCaseInsensitiveContains("code")
                }.sorted()
            }.value
        }
    }
}

struct FontPreview: View {
    var body: some View {
        let s = SettingsStore.shared.settings
        let t = ConfigController.shared.theme
        let font = InputEditorView.font(family: s.fontFamily, size: CGFloat(s.fontSize))
        VStack(alignment: .leading, spacing: CGFloat(s.lineHeight - 1) * CGFloat(s.fontSize) + 2) {
            Text("~/code/shell ").foregroundColor(Color(nsColor: t.palette[4].nsColor))
                + Text("main ").foregroundColor(Color(nsColor: t.palette[5].nsColor))
                + Text("❯ ").foregroundColor(Color(nsColor: t.palette[2].nsColor))
                + Text("git log --oneline -3").foregroundColor(Color(nsColor: t.foreground.nsColor))
            Text("a1b2c3d ").foregroundColor(Color(nsColor: t.palette[3].nsColor))
                + Text("Add vertical tabs => != === -> ").foregroundColor(Color(nsColor: t.foreground.nsColor))
            Text("0O1lI {}[]() <= >= fi fl").foregroundColor(Color(nsColor: t.foreground.nsColor))
        }
        .font(Font(font))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: t.background.nsColor)))
    }
}

struct TerminalSettingsPane: View {
    var body: some View {
        let s = SettingsStore.shared.settings
        Form {
            Section("Keyboard") {
                Picker("Option key", selection: setting(\.optionKey)) {
                    ForEach(OptionKeyMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Natural text editing (⌥←/→ by word, ⌘←/→ line start/end, ⌘⌫ delete line)", isOn: setting(\.naturalTextEditing))
            }
            Section("Selection & Clipboard") {
                Toggle("Copy selected text automatically", isOn: setting(\.copyOnSelect))
                Toggle("Warn before pasting text that could run commands", isOn: setting(\.pasteProtection))
            }
            Section("Links") {
                Toggle("Underline web links and file paths", isOn: setting(\.highlightLinks))
                Text("⌘-click a web link to open it, or a file or folder path to show it in Finder. Paths are underlined only if they exist (relative paths use the pane's current directory).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Mouse") {
                Toggle("Hide the pointer while typing", isOn: setting(\.hideMouseWhileTyping))
                Toggle("Focus follows mouse between split panes", isOn: setting(\.focusFollowsMouse))
            }
            Section("Layout") {
                Stepper(value: setting(\.paddingX), in: 0...60) { LabeledContent("Horizontal padding", value: "\(s.paddingX) pt") }
                Stepper(value: setting(\.paddingY), in: 0...60) { LabeledContent("Vertical padding", value: "\(s.paddingY) pt") }
                Toggle("Dim inactive split panes", isOn: setting(\.dimUnfocusedSplits))
            }
            Section("Scrollback") {
                Stepper(value: setting(\.scrollbackMB), in: 1...2000, step: 10) {
                    LabeledContent("Memory per pane", value: "\(s.scrollbackMB) MB")
                }
            }
            Section("Bell") {
                Toggle("Play a sound", isOn: setting(\.bellSound))
                Toggle("Bounce the Dock icon when Shell is in the background", isOn: setting(\.bounceDockOnBell))
            }
        }
        .formStyle(.grouped)
    }
}

struct InputSettingsPane: View {
    var body: some View {
        let s = SettingsStore.shared.settings
        Form {
            Section {
                Toggle("Native prompt (Warp-style)", isOn: setting(\.inputEditor))
                Text(SettingsStore.shared.settings.inputEditor
                     ? "You type commands in a native editor (mouse selection, multi-line editing, syntax highlighting, history suggestions, zsh completions). The terminal shows output only, as command blocks. Programs you run (vim, ssh, REPLs) still get the terminal directly. Toggle anytime with ⌃⌘E."
                     : "Off: you type straight into the terminal at your zsh prompt, like iTerm2. Turn on for Warp-style editing and completions. Toggle anytime with ⌃⌘E.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if s.inputEditor {
                Section("Layout") {
                    Picker("Position", selection: setting(\.inputPosition)) {
                        ForEach(InputPosition.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Command header in scrollback", selection: setting(\.promptStyle)) {
                        ForEach(PromptStyle.allCases) { Text($0.title).tag($0) }
                    }
                    Text("You type only in the editor; the terminal shows output. Each command you run is recorded above its output with this header.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Show context chips (directory, git branch, last exit status)", isOn: setting(\.showContextBar))
                    Stepper(value: setting(\.editorFontSize), in: 0...40, step: 1) {
                        LabeledContent("Editor font size", value: s.editorFontSize == 0 ? "Same as terminal" : "\(Int(s.editorFontSize)) pt")
                    }
                }
                Section("Completions") {
                    Toggle("zsh completions", isOn: setting(\.completions))
                    Toggle("Show suggestions while typing (otherwise press Tab)", isOn: setting(\.completionsWhileTyping))
                        .disabled(!s.completions)
                    Toggle("Preview files, folders and commands", isOn: setting(\.completionPreview))
                        .disabled(!s.completions)
                    Toggle("Suggest from history as ghost text (→ to accept)", isOn: setting(\.historySuggestions))
                    Toggle("Syntax highlighting", isOn: setting(\.syntaxHighlighting))
                }
                Section("Keys") {
                    keyRow("⏎", "Run command (Tab/⏎ accept a highlighted completion)")
                    keyRow("⇧⏎ / ⌥⏎", "New line")
                    keyRow("⇥", "Complete (inserts common prefix, opens menu)")
                    keyRow("↑ ↓", "History (prefix search) or navigate menu")
                    keyRow("→ / ⌥→", "Accept suggestion / next word of suggestion")
                    keyRow("⌃R", "Search history")
                    keyRow("⌃C", "Clear input, or interrupt when empty")
                    keyRow("⌃L", "Clear the screen")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func keyRow(_ key: String, _ text: String) -> some View {
        LabeledContent { Text(text).foregroundStyle(.secondary) } label: { Text(key).font(.system(.body, design: .monospaced)) }
    }
}

struct TabsSettingsPane: View {
    var body: some View {
        let s = SettingsStore.shared.settings
        Form {
            Section("Tab Bar") {
                Picker("Style", selection: setting(\.tabBarStyle)) {
                    ForEach(TabBarStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if s.tabBarStyle == .vertical {
                    LabeledContent("Sidebar width") {
                        Slider(value: setting(\.sidebarWidth), in: 180...420, step: 10) { EmptyView() }
                        Text("\(Int(s.sidebarWidth)) pt").monospacedDigit().frame(width: 52)
                    }
                }
                Picker("New tab position", selection: setting(\.newTabPlacement)) {
                    ForEach(NewTabPlacement.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Tab Groups") {
                Text("Right-click a tab › Add Tab to Group, or press ⌃⌘G. Click a group's label to collapse it; drag tabs onto a group to add them. Groups are saved with your session.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Splits") {
                Text("⌘D splits right and ⇧⌘D splits down. Move between panes with ⌥⌘ + arrows, maximize with ⇧⌘⏎, and drag dividers to resize (double-click to even them out).")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AdvancedSettingsPane: View {
    @State private var extra = SettingsStore.shared.settings.extraGhosttyConfig

    var body: some View {
        Form {
            Section {
                TextEditor(text: $extra)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)
                HStack {
                    Button("Apply") { SettingsStore.shared.settings.extraGhosttyConfig = extra }
                    Link("Ghostty option reference", destination: URL(string: "https://ghostty.org/docs/config/reference")!)
                    Spacer()
                }
            } header: {
                Text("Extra Ghostty configuration")
            } footer: {
                Text("Appended to the generated config. Any libghostty option works here, e.g. `font-feature = +ss01` or `window-padding-color = background`.")
            }
            if !GhosttyRuntime.shared.configDiagnostics.isEmpty {
                Section("Configuration warnings") {
                    ForEach(GhosttyRuntime.shared.configDiagnostics, id: \.self) { Text($0).font(.caption) }
                }
            }
            Section("Files") {
                LabeledContent("Settings") {
                    Button("Reveal settings.json") { NSWorkspace.shared.activateFileViewerSelecting([SettingsStore.fileURL]) }
                }
                LabeledContent("Generated terminal config") {
                    Button("Reveal ghostty.conf") { NSWorkspace.shared.activateFileViewerSelecting([ConfigController.configURL]) }
                }
                LabeledContent("Shell integration") {
                    Button("Reveal scripts") {
                        if let dir = ShellIntegration.bundleShellDirectory {
                            NSWorkspace.shared.activateFileViewerSelecting([dir.appendingPathComponent("shell-integration.zsh")])
                        }
                    }
                }
            }
            Section("Shell Integration") {
                Toggle("Enable zsh integration (input editor, completions, prompt tracking)", isOn: setting(\.shellIntegration))
                TextField("Shell (empty = your login shell)", text: setting(\.shellPath))
            }
            Section {
                Button("Reset All Settings…", role: .destructive) {
                    let alert = NSAlert()
                    alert.messageText = "Reset all settings to defaults?"
                    alert.addButton(withTitle: "Reset")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        SettingsStore.shared.reset()
                        extra = ""
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings › General › Sync: optional iCloud Drive sync of portable settings.
struct SettingsSyncSection: View {
    @State private var confirm: ConfirmEnable?

    struct ConfirmEnable: Identifiable {
        let id = UUID()
        var device: String?
        var modified: Date?
    }

    var body: some View {
        let s = SettingsStore.shared.settings
        Section("Sync") {
            Toggle("Sync settings with iCloud Drive", isOn: Binding(
                get: { s.iCloudSync },
                set: { on in on ? requestEnable() : (SettingsStore.shared.settings.iCloudSync = false) }))
                .disabled(!s.iCloudSync && !SettingsSync.isAvailable)
            if !SettingsSync.isAvailable {
                Text("Turn on iCloud Drive in System Settings › Apple Account › iCloud to use sync.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Off by default. Themes, fonts, prompt, shortcuts, notification and Claude preferences sync through iCloud Drive/Shell/settings.json. Your shell path, environment variables, worktree and maintenance settings and command history stay on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if s.iCloudSync {
                HStack {
                    if let last = SettingsSync.shared.lastSynced {
                        Text("Last synced \(last.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sync Now") {
                        if !SettingsSync.shared.pullIfNewer() { SettingsSync.shared.pushNow() }
                    }
                }
            }
        }
        .alert("Settings are already in iCloud Drive", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
               presenting: confirm) { _ in
            Button("Use iCloud Settings") { SettingsSync.shared.enable(useRemote: true) }
            Button("Use This Mac's Settings") { SettingsSync.shared.enable(useRemote: false) }
            Button("Cancel", role: .cancel) {}
        } message: { c in
            let from = c.device.map { " from \($0)" } ?? ""
            let when = c.modified.map { ", saved \($0.formatted(.relative(presentation: .named)))" } ?? ""
            Text("Found synced settings\(from)\(when). Which should Shell keep? The other copy is replaced.")
        }
    }

    private func requestEnable() {
        switch SettingsSync.shared.remoteState() {
        case .exists(let device, let modified): confirm = ConfirmEnable(device: device, modified: modified)
        case .none: SettingsSync.shared.enable(useRemote: false)
        }
    }
}
