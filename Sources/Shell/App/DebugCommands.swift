import AppKit
import SwiftUI

/// Development hooks reachable over the control socket (`shellctl debug …`).
/// They let scripts drive and inspect the app without Screen Recording access.
extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type, where predicate: (T) -> Bool = { _ in true }) -> T? {
        for sub in subviews {
            if let t = sub as? T, predicate(t) { return t }
            if let found = sub.firstDescendant(of: type, where: predicate) { return found }
        }
        return nil
    }
}

@MainActor
enum DebugCommands {
    private(set) static var events: [String] = []

    static func trace(_ s: String) {
        events.append(String(format: "%.3f ", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)) + s)
        if events.count > 200 { events.removeFirst(events.count - 200) }
    }

    static func handle(_ fields: [String]) {
        guard fields.count >= 3 else { return }
        let command = fields[2]
        let arg = fields.count > 3 ? fields[3] : ""
        let controller = AppDelegate.shared.activeController
        switch command {
        case "snapshot":
            snapshot(to: arg.isEmpty ? NSTemporaryDirectory() : arg)
        case "action":
            if let action = ShortcutAction(rawValue: arg) {
                if let controller { controller.perform(action) } else { AppDelegate.shared.perform(action) }
            }
        case "github-select":
            // Opens a PR's detail pane in the GitHub tab ("" closes it).
            controller?.workspace.githubBoard?.selection = Int(arg).map { .init(number: $0) }
        case "type":
            controller?.focusedPane?.editor.insert(arg)
        case "submit":
            controller?.focusedPane?.editor.submit()
        case "complete":
            controller?.focusedPane?.editor.requestCompletionsNow(fromTab: true)
        case "key":
            // Sends raw text to the focused terminal (e.g. "q" to quit a pager).
            controller?.focusedSession?.surfaceView.writeRaw(arg.replacingOccurrences(of: "\\r", with: "\r"))
        case "set":
            // set key=value for a handful of settings used in testing.
            let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            var s = SettingsStore.shared.settings
            switch parts[0] {
            case "tabBarStyle": s.tabBarStyle = TabBarStyle(rawValue: parts[1]) ?? s.tabBarStyle
            case "inputPosition": s.inputPosition = InputPosition(rawValue: parts[1]) ?? s.inputPosition
            case "appearance": s.appearance = AppearanceMode(rawValue: parts[1]) ?? s.appearance
            case "promptStyle": s.promptStyle = PromptStyle(rawValue: parts[1]) ?? s.promptStyle
            case "inputEditor": s.inputEditor = parts[1] == "true"
            case "darkTheme": s.darkTheme = parts[1]
            case "lightTheme": s.lightTheme = parts[1]
            case "brewAutoUpdate": s.brewAutoUpdate = AutoUpdateSchedule(rawValue: parts[1]) ?? s.brewAutoUpdate
            case "nodeAutoUpdate": s.nodeAutoUpdate = AutoUpdateSchedule(rawValue: parts[1]) ?? s.nodeAutoUpdate
            case "nodeTrack": s.nodeTrack = parts[1]
            case "sidebarTab": s.sidebarTab = SidebarTab(rawValue: parts[1]) ?? s.sidebarTab
            case "worktreeRoot": s.worktreeRoot = parts[1]
            case "githubSection": s.githubSection = GitHubSection(rawValue: parts[1]) ?? s.githubSection
            case "goCacheWarningGB": s.goCacheWarningGB = Int(parts[1]) ?? s.goCacheWarningGB
            default: return
            }
            SettingsStore.shared.settings = s
        case "settings":
            SettingsWindowController.shared.show(pane: SettingsPane(rawValue: arg) ?? .general)
        case "sheet":
            // Completes a pending sheet (e.g. a rename prompt) with text.
            if let w = controller?.window, let sheet = w.attachedSheet {
                if let field = sheet.contentView?.firstDescendant(of: NSTextField.self, where: { $0.isEditable }) {
                    field.stringValue = arg
                }
                // "button:Title" clicks that button (NSAlert ignores endSheet's return code).
                if arg.hasPrefix("button:"), let b = sheet.contentView?.firstDescendant(of: NSButton.self, where: { $0.title == String(arg.dropFirst(7)) }) {
                    b.performClick(nil)
                } else {
                    w.endSheet(sheet, returnCode: .alertFirstButtonReturn)
                }
            }
        case "tree":
            var lines: [String] = []
            func walk(_ v: NSView, _ depth: Int) {
                guard depth < 14 else { return }
                let name = String(describing: type(of: v)).prefix(60)
                var extra = ""
                if let t = v as? NSTextField { extra = " \"\(t.stringValue.prefix(40))\"" }
                if let b = v as? NSButton { extra = " [\(b.title.prefix(30))]" }
                let ax = v.accessibilityLabel().map { " ax=\($0.prefix(40))" } ?? ""
                lines.append(String(repeating: "  ", count: depth) + "\(name) \(Int(v.frame.width))x\(Int(v.frame.height))\(v.isHidden ? " hidden" : "")\(extra)\(ax)")
                for sub in v.subviews { walk(sub, depth + 1) }
            }
            if let w = NSApp.windows.first(where: { $0.title == arg || ($0.isKeyWindow && arg.isEmpty) }), let root = w.contentView {
                walk(root, 0)
            }
            try? lines.joined(separator: "\n").write(toFile: NSTemporaryDirectory() + "shell-tree.txt", atomically: true, encoding: .utf8)
        case "brew-run":
            Task { await ScheduledMaintenance.homebrew.run() }
        case "node-run":
            Task { await ScheduledMaintenance.node.run() }
        case "node-refresh":
            Task {
                await NodeService.shared.refresh()
                DebugCommands.trace("node: " + NodeService.shared.debugSummary)
            }
        case "hover-link":
            if let pane = controller?.focusedPane {
                pane.refreshLinks()
                pane.debugHover(pane.debugLinks.first { $0.text.contains(arg) })
            }
        case "copy":
            let kind: InputEditorView.CopyKind = arg == "output" ? .lastOutput : arg == "last" ? .lastCommand : .command
            controller?.focusedPane?.editor.copy(kind)
            trace("copy \(arg): \(controller?.focusedPane?.editor.barState.flashMessage ?? "-") | \(NSPasteboard.general.string(forType: .string)?.prefix(300) ?? "")")
        case "claude-type":
            controller?.focusedPane?.claudeComposer.insert(arg)
        case "claude-submit":
            (controller?.focusedPane?.claudeComposer.textView?.delegate as? ClaudeComposerField.Coordinator)?.submit()
        case "claude-key":
            // Simulates a composer key: shift-tab, esc, up, down, tab, return.
            if let tv = controller?.focusedPane?.claudeComposer.textView {
                let (code, flags): (UInt16, NSEvent.ModifierFlags) = switch arg {
                case "shift-tab": (48, .shift)
                case "tab": (48, [])
                case "esc": (53, [])
                case "up": (126, [])
                case "down": (125, [])
                default: (36, [])
                }
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: tv.window?.windowNumber ?? 0,
                                            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) {
                    tv.keyDown(with: e)
                }
            }
        case "claude-set":
            // model=…, effort=…, mode=…, explorer=on|off, close
            guard let claude = controller?.focusedSession?.nativeClaude else { return }
            let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
            switch (parts.first ?? "", parts.count > 1 ? parts[1] : "") {
            case ("model", let v): claude.setModel(v)
            case ("effort", let v): claude.setEffort(v)
            case ("mode", let v): if let m = ClaudePermissionMode(rawValue: v) { claude.setPermissionMode(m) }
            case ("explorer", let v): claude.showExplorer = v == "on"
            case ("close", _): controller?.focusedSession?.endNativeClaude()
            case ("terminal", _): controller?.focusedSession?.continueClaudeInTerminal()
            case ("allow", _): if let r = claude.pending.first { claude.respond(r, allow: true) }
            default: break
            }
        case "mcp":
            // mcp open [DIR] | select NAME | tools NAME | signin NAME
            let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
            let rest = parts.count > 1 ? parts[1] : ""
            switch parts.first ?? "" {
            case "open":
                if rest.isEmpty { MCPManagerWindowController.show(for: controller?.focusedSession) } else { MCPManagerWindowController.show(directory: rest) }
            case "select":
                (NSApp.windows.compactMap { $0.windowController as? MCPManagerWindowController }.first)?.selection.name = rest
            case "tools":
                if let c = NSApp.windows.compactMap({ $0.windowController as? MCPManagerWindowController }).first, let s = c.manager.server(rest) {
                    c.manager.loadToolDetails(s)
                }
            case "dump":
                if let c = NSApp.windows.compactMap({ $0.windowController as? MCPManagerWindowController }).first {
                    trace("mcp dir=\(c.manager.directory) loading=\(c.manager.isLoading) err=\(c.manager.lastError ?? "-") servers=\(c.manager.servers.count)")
                    for s in c.manager.servers {
                        trace("  [\(s.group)] \(s.name) \(s.status.rawValue) tools=\(s.tools.count) details=\(c.manager.toolDetails[s.name]?.count ?? -1) toolErr=\(c.manager.toolErrors[s.name] ?? "-")")
                    }
                }
            default: break
            }
        case "pr-create":
            // pr-create REPO NUMBER: creates a worktree for that PR (tests the PRs tab flow).
            let parts = arg.split(separator: " ").map(String.init)
            guard parts.count == 2, let n = Int(parts[1]) else { return }
            let model = PullRequestsModel(repoRoot: parts[0], environment: MCPManager.defaultEnvironment())
            model.refresh()
            Task {
                for _ in 0..<60 where model.pullRequests.isEmpty && model.error == nil { try? await Task.sleep(for: .milliseconds(500)) }
                guard let pr = model.pullRequests.first(where: { $0.number == n }) else {
                    trace("pr-create: #\(n) not found (\(model.error ?? "no error"))")
                    return
                }
                let path = await model.createWorktree(for: pr, repoName: (parts[0] as NSString).lastPathComponent)
                trace("pr-create: path=\(path ?? "nil") msg=\(model.lastMessage ?? "-")")
            }
        case "render-storage":
            // Hosts the Agent Storage pane in a plain window so `snapshot` can capture it.
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 1100), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Agent Storage (debug)"
            w.isReleasedWhenClosed = false
            w.contentView = arg == "go"
                ? NSHostingView(rootView: AnyView(GoSettingsPane().frame(width: 700, height: 1100)))
                : NSHostingView(rootView: AnyView(AgentStoragePane().frame(width: 700, height: 1100)))
            w.center()
            w.makeKeyAndOrderFront(nil)
        case "storage":
            // Read-only: measures every category and traces sizes.
            let m = AgentStorageModel.shared
            m.measure()
            Task {
                while m.isMeasuring || m.measured.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
                trace("storage total=\(WorktreeService.formatBytes(m.total))")
                for c in m.categories {
                    let r = m.removable(c)
                    trace("  \(c.id) \(WorktreeService.formatBytes(m.measured[c.id]?.total ?? 0)) items=\(m.measured[c.id]?.items.count ?? 0) removable=\(r.count)/\(WorktreeService.formatBytes(r.map(\.bytes).reduce(0, +)))")
                }
            }
        case "worktree-cleanup":
            WorktreeCleanupJob.pathsOverride = [arg]
            Task {
                await ScheduledMaintenance.worktrees.run()
                WorktreeCleanupJob.pathsOverride = nil
                let r = ScheduledMaintenance.worktrees.lastRun
                trace("cleanup: \(r?.outcome.rawValue ?? "-") removed=\(r?.changes ?? []) \(r?.summary ?? "") warnings=\(r?.warnings ?? []) log=\(r?.logPath ?? "-")")
            }
        case "quit":
            NSApp.terminate(nil)
        default:
            break
        }
    }

    /// Writes each window as PNG (AppKit/SwiftUI chrome only — Metal
    /// terminal content isn't captured) plus a text dump of every visible pane.
    static func snapshot(to dir: String) {
        let url = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var report: [String] = []
        for (i, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView else { continue }
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: url.appendingPathComponent("window-\(i).png"))
                }
            }
            if let layer = view.layer {
                let scale = window.backingScaleFactor
                let size = view.bounds.size
                if let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                       bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    ctx.scaleBy(x: scale, y: scale)
                    if !view.isFlipped {
                        ctx.translateBy(x: 0, y: size.height)
                        ctx.scaleBy(x: 1, y: -1)
                    }
                    layer.render(in: ctx)
                    if let img = ctx.makeImage() {
                        let rep = NSBitmapImageRep(cgImage: img)
                        try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("window-\(i)-layer.png"))
                    }
                }
            }
            report.append("== window \(i): \(window.title) frame=\(window.frame) key=\(window.isKeyWindow)")
            report.append("   firstResponder=\(String(describing: window.firstResponder.map { type(of: $0) }))")
            if let c = window.windowController as? TerminalWindowController {
                for (ti, tab) in c.workspace.tabs.enumerated() {
                    let sel = tab.id == c.workspace.selectedTabID ? "*" : " "
                    report.append("  \(sel)tab \(ti): \(tab.title) group=\(c.workspace.group(tab.groupID)?.name ?? "-") panes=\(tab.sessions.count)")
                    for s in tab.orderedSessions {
                        let pv = c.paneView(for: s)
                        report.append("     dim=\(pv.map { !$0.isActivePane && $0.showsDimming } ?? false) focused=\(tab.focusedSessionID == s.id)")
                        report.append("     pane \(s.id.uuidString.prefix(8)) state=\(s.state) cwd=\(s.workingDirectory ?? "?") branch=\(s.gitBranch ?? "-") exit=\(s.lastExitCode.map(String.init) ?? "-") agent=\(String(describing: s.agent))")
                        if tab.id == c.workspace.selectedTabID {
                            let text = s.surfaceView.readText()
                            let lines = text.components(separatedBy: "\n")
                            let trimmed = lines.reversed().drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }.reversed()
                            report.append(contentsOf: trimmed.suffix(30).map { "       | " + $0 })
                            if let pv = c.paneView(for: s), !pv.debugLinks.isEmpty {
                                for l in pv.debugLinks {
                                    report.append("       link[\(l.isFile ? "file" : "url")]: \(l.text) -> \(l.target) rects=\(l.rects.map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height)))" }.joined(separator: " "))")
                                }
                            }
                            if let claude = s.nativeClaude {
                                report.append("       claude: running=\(claude.isRunning) exited=\(claude.hasExited) model=\(claude.model)/\(claude.resolvedModel ?? "-") effort=\(claude.effort) mode=\(claude.permissionMode.rawValue) session=\(claude.sessionID ?? "-") rc=\(claude.remoteControlURL?.absoluteString ?? "off")\(claude.remoteControlError.map { " rcErr=" + $0 } ?? "")")
                                report.append("       claude: repo=\(claude.repository?.root.path ?? "-") branch=\(claude.repository?.branchLabel ?? "-") worktree=\(claude.repository?.isLinkedWorktree ?? false) changes=\(claude.repository?.status.changes.count ?? 0) explorer=\(claude.showExplorer) models=\(claude.models.count) commands=\(claude.commands.count) mcp=\(claude.mcpServers.count) pending=\(claude.pending.map(\.toolName))")
                                if let pane = c.paneView(for: s) {
                                    report.append("       composer: suggestions=\(pane.claudeComposer.suggestions.prefix(8).map(\.title)) text=\"\(pane.claudeComposer.textView?.string ?? "")\"")
                                }
                                for item in claude.items.suffix(12) {
                                    let text = item.kind == .tool ? "\(item.toolName) \(item.summary) running=\(item.isRunning) err=\(item.isError)" : item.text
                                    report.append("       [\(item.kind)] " + text.replacingOccurrences(of: "\n", with: "⏎").prefix(200))
                                }
                            }
                            if let pane = c.focusedPane, pane.session === s {
                                report.append("       editor: \"\(pane.editor.text)\" completions=\(pane.editor.completion.isVisible ? pane.editor.completion.items.prefix(12).map(\.display).joined(separator: ", ") : "hidden")")
                            }
                        }
                    }
                }
            }
        }
        report.append("== trace")
        report.append(contentsOf: events.suffix(40))
        try? report.joined(separator: "\n").write(to: url.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }
}
