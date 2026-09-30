import AppKit
import SwiftUI

/// ⇧⌘P palette: run any action, jump to a tab, switch theme, or rerun history.
@MainActor
enum CommandPalette {
    private static var panel: NSPanel?

    static func show(for controller: TerminalWindowController) {
        close()
        guard let window = controller.window else { return }
        let p = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 420),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        let model = PaletteModel(controller: controller)
        let host = NSHostingView(rootView: PaletteView(model: model))
        host.frame = p.contentRect(forFrameRect: p.frame)
        p.contentView = host
        let frame = window.frame
        p.setFrameOrigin(NSPoint(x: frame.midX - 300, y: frame.maxY - 110 - 420))
        window.addChildWindow(p, ordered: .above)
        p.makeKey()
        panel = p
    }

    static func close() {
        guard let p = panel else { return }
        p.parent?.removeChildWindow(p)
        p.orderOut(nil)
        panel = nil
    }
}

final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func resignKey() {
        super.resignKey()
        DispatchQueue.main.async { MainActor.assumeIsolated { CommandPalette.close() } }
    }
}

@MainActor
@Observable
final class PaletteModel {
    struct Item: Identifiable {
        /// Stable across queries, so the list diffs instead of rebuilding.
        var id: String
        var title: String
        var subtitle: String
        var symbol: String
        var shortcut: String?
        var run: () -> Void
    }

    let controller: TerminalWindowController
    var query = "" {
        didSet {
            selected = 0
            items = computeItems()
            scheduleIntent()
        }
    }
    var selected = 0
    /// Recomputed when the query changes, not on every render (arrow keys
    /// re-render the list; recomputing would fuzzy-search history each time).
    private(set) var items: [Item] = []
    /// The command Apple Intelligence matched to a plain-English query.
    @ObservationIgnored private var intent: (query: String, item: Item)?
    @ObservationIgnored private var intentTask: Task<Void, Never>?

    init(controller: TerminalWindowController) {
        self.controller = controller
        items = computeItems()
        Intelligence.prewarm(for: .paletteIntents)
    }

    /// Commands the model may pick from: every action except the ones that
    /// only make sense as keys, plus each Settings pane.
    private func intentChoices() -> [(choice: IntelligencePrompts.Choice, item: Item)] {
        let c = controller
        let skipped: Set<ShortcutAction> = [.commandPalette, .copy, .paste, .selectAll, .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8]
        var list: [(IntelligencePrompts.Choice, Item)] = []
        for action in ShortcutAction.allCases where !skipped.contains(action) {
            let title = action.title.replacingOccurrences(of: "…", with: "")
            list.append((IntelligencePrompts.Choice(id: action.rawValue, title: title),
                         Item(id: "intent:\(action.rawValue)", title: title, subtitle: "Suggested · \(action.category.rawValue)",
                              symbol: "sparkles", shortcut: action.shortcut?.displayString) { c.perform(action) }))
        }
        for pane in SettingsPane.allCases {
            list.append((IntelligencePrompts.Choice(id: "settings." + pane.rawValue, title: "Open \(pane.title) settings"),
                         Item(id: "intent:settings.\(pane.rawValue)", title: "\(pane.title) Settings", subtitle: "Suggested · Settings",
                              symbol: "sparkles", shortcut: nil) { SettingsWindowController.shared.show(pane: pane) }))
        }
        return list
    }

    /// Asks the model which command a request like "split the pane and zoom
    /// in" means, after a short pause in typing.
    private func scheduleIntent() {
        intentTask?.cancel()
        let q = query
        guard Intelligence.isEnabled(.paletteIntents), IntelligencePrompts.looksLikeRequest(q) else { return }
        intentTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            let choices = intentChoices()
            guard let id = await Intelligence.paletteIntent(for: q, choices: choices.map(\.choice)),
                  !Task.isCancelled, query == q, let match = choices.first(where: { $0.choice.id == id }) else { return }
            // Keep the highlighted row where it is while the suggestion lands on top.
            let keep = items.indices.contains(selected) ? items[selected].id : nil
            intent = (q, match.item)
            items = computeItems()
            if let keep, let idx = items.firstIndex(where: { $0.id == keep }) { selected = idx }
        }
    }

    private func computeItems() -> [Item] {
        var all: [Item] = []
        let c = controller
        for (i, tab) in c.workspace.tabs.enumerated() {
            all.append(Item(id: "tab:\(i)", title: tab.title, subtitle: "Tab \(i + 1) · \(tab.subtitle)", symbol: "rectangle.on.rectangle",
                            shortcut: i < 9 ? "⌘\(i + 1)" : nil) { c.select(tab) })
        }
        for action in ShortcutAction.allCases where ![.commandPalette, .copy, .paste, .selectAll].contains(action) {
            all.append(Item(id: "action:\(action.rawValue)", title: action.title.replacingOccurrences(of: "…", with: ""), subtitle: action.category.rawValue,
                            symbol: "command", shortcut: action.shortcut?.displayString) {
                c.perform(action)
            })
        }
        all.append(Item(id: "install-hooks", title: "Install Claude Code & Codex notifications", subtitle: "Integrations", symbol: "sparkles", shortcut: nil) {
            SettingsWindowController.shared.show(pane: .integrations)
        })
        if !query.isEmpty {
            let dark = ConfigController.shared.isDark
            for theme in ThemeLibrary.shared.themes where theme.isDark == dark {
                all.append(Item(id: "theme:\(theme.name)", title: "Theme: \(theme.name)", subtitle: dark ? "Dark theme" : "Light theme", symbol: "paintpalette", shortcut: nil) {
                    if dark { SettingsStore.shared.settings.darkTheme = theme.name } else { SettingsStore.shared.settings.lightTheme = theme.name }
                })
            }
            for cmd in HistoryStore.shared.search(query, limit: 30) {
                all.append(Item(id: "history:\(cmd)", title: cmd, subtitle: "Run from history", symbol: "clock.arrow.circlepath", shortcut: nil) {
                    if let s = c.focusedSession, s.state == .idle { s.submit(command: cmd) }
                })
            }
        }
        guard !query.isEmpty else { return Array(all.prefix(60)) }
        let q = query.lowercased()
        let matches = all.compactMap { item -> (Item, Int)? in
            guard let score = FuzzyMatch.score(q, in: item.title.lowercased()) else { return nil }
            return (item, score)
        }
        .sorted { $0.1 < $1.1 }
        .prefix(60)
        .map(\.0)
        guard let intent, intent.query == query else { return matches }
        return [intent.item] + matches
    }
}

struct PaletteView: View {
    @Bindable var model: PaletteModel
    @FocusState private var focused: Bool

    var body: some View {
        let items = model.items
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search commands, tabs, themes, history…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onSubmit { run(items) }
                    .onKeyPress(.upArrow) { model.selected = max(0, model.selected - 1); return .handled }
                    .onKeyPress(.downArrow) { model.selected = min(items.count - 1, model.selected + 1); return .handled }
                    .onKeyPress(.escape) { CommandPalette.close(); return .handled }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                            HStack(spacing: 10) {
                                Image(systemName: item.symbol).frame(width: 18).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title).lineLimit(1)
                                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if let s = item.shortcut {
                                    Text(s).font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(idx == model.selected ? Color.accentColor.opacity(0.25) : .clear))
                            .contentShape(Rectangle())
                            .id(idx)
                            .onTapGesture {
                                model.selected = idx
                                run(items)
                            }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.selected) { _, i in proxy.scrollTo(i) }
            }
        }
        .frame(width: 600, height: 420)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.secondary.opacity(0.25)))
        .onAppear { focused = true }
    }

    private func run(_ items: [PaletteModel.Item]) {
        guard items.indices.contains(model.selected) else { return }
        let item = items[model.selected]
        CommandPalette.close()
        model.controller.window?.makeKey()
        item.run()
        model.controller.focusSelected()
    }
}
