import AppKit
import SwiftUI

/// ⇧⌘P palette ("Go to anything"): jump to a tab, worktree or recent folder,
/// run any action, switch theme, or rerun history. `>` limits the search to
/// actions, `@` to folders and worktrees.
@MainActor
enum CommandPalette {
    private static var panel: NSPanel?
    static let size = NSSize(width: 680, height: 460)

    static func show(for controller: TerminalWindowController, query: String = "") {
        close()
        guard let window = controller.window else { return }
        let p = PalettePanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        let model = PaletteModel(controller: controller)
        if !query.isEmpty { model.query = query }
        let host = NSHostingView(rootView: PaletteView(model: model))
        host.frame = p.contentRect(forFrameRect: p.frame)
        p.contentView = host
        let frame = window.frame
        p.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - 120 - size.height))
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
    /// How a result was chosen: ⏎, ⌘⏎ (open in a new tab) or ⌥⏎ (start Claude there).
    enum Modifier { case plain, newTab, claude }

    struct Item: Identifiable {
        /// Stable across queries, so the list diffs instead of rebuilding.
        var id: String
        var section: PaletteSection
        var title: String
        var subtitle: String = ""
        var tile: TileKind
        /// Shortcut, size or "Open in new tab".
        var trailing: String?
        /// Offsets of the title characters that matched the query, in bold.
        var matches: [Int] = []
        /// True for places (worktrees, folders), which take ⌘⏎ and ⌥⏎.
        var takesModifiers = false
        var run: (Modifier) -> Void
    }

    struct Section: Identifiable {
        var section: PaletteSection
        var items: [Item]
        var id: Int { section.rawValue }
    }

    let controller: TerminalWindowController
    var query = "" {
        didSet {
            selected = 0
            recompute()
            scheduleIntent()
        }
    }
    var selected = 0
    /// Recomputed when the query (or worktree data) changes, not on every
    /// render: arrow keys re-render the list.
    private(set) var sections: [Section] = []
    private(set) var rows: [Item] = []
    /// The command Apple Intelligence matched to a plain-English query.
    @ObservationIgnored private var intent: (query: String, item: Item)?
    @ObservationIgnored private var intentTask: Task<Void, Never>?
    @ObservationIgnored private let worktrees: WorktreesModel?
    @ObservationIgnored private let repoName: String?

    init(controller: TerminalWindowController) {
        self.controller = controller
        let repo = controller.focusedRepository
        repoName = repo.map { $0.github?.name ?? ($0.mainWorktree?.lastPathComponent ?? $0.name) }
        worktrees = controller.worktreesForFocusedRepository()
        worktrees?.refreshIfNeeded()
        recompute()
        observeWorktrees()
        Intelligence.prewarm(for: .paletteIntents)
    }

    /// Worktree status arrives after the palette opens: show it when it does.
    private func observeWorktrees() {
        guard let worktrees else { return }
        withObservationTracking { _ = worktrees.worktrees } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.recompute(keepSelection: true)
                    self.observeWorktrees()
                }
            }
        }
    }

    private func recompute(keepSelection: Bool = false) {
        let keep = keepSelection && rows.indices.contains(selected) ? rows[selected].id : nil
        let parsed = PaletteQuery.parse(query)
        var candidates = computeCandidates(parsed)
        if let intent, intent.query == query { candidates.insert(intent.item, at: 0) }
        let groups = PaletteSearch.group(candidates, query: parsed, section: \.section, title: \.title)
        sections = groups.map { g in
            Section(section: g.section, items: g.items.map { item in
                var item = item
                if !parsed.text.isEmpty, item.section != .suggested {
                    item.matches = PaletteSearch.matchIndices(parsed.text, in: item.title) ?? []
                }
                return item
            })
        }
        rows = sections.flatMap(\.items)
        if let keep, let idx = rows.firstIndex(where: { $0.id == keep }) { selected = idx }
        selected = min(selected, max(rows.count - 1, 0))
    }

    func run(_ modifier: Modifier) {
        guard rows.indices.contains(selected) else { return }
        let item = rows[selected]
        CommandPalette.close()
        controller.window?.makeKey()
        item.run(item.takesModifiers ? modifier : .plain)
        controller.focusSelected()
    }

    // MARK: Candidates

    private func computeCandidates(_ q: PaletteQuery) -> [Item] {
        var all: [Item] = []
        let c = controller
        if q.includes(.tabs) { all += tabItems() }
        let worktreePaths = Set((worktrees?.worktrees ?? []).map { Self.standard($0.path) })
        if q.includes(.worktrees) { all += worktreeItems() }
        if q.includes(.folders) {
            for dir in RecentDirectories.list where !worktreePaths.contains(Self.standard(dir)) {
                all.append(placeItem(id: "folder:\(dir)", section: .folders, title: (dir as NSString).lastPathComponent,
                                     subtitle: Self.abbreviate(dir), tile: .folder, directory: dir))
            }
        }
        if q.includes(.actions) {
            for action in ShortcutAction.allCases where ![.commandPalette, .copy, .paste, .selectAll].contains(action) {
                all.append(Item(id: "action:\(action.rawValue)", section: .actions, title: action.title.replacingOccurrences(of: "…", with: ""),
                                tile: action == .claudeInNewWorktree || action == .claudeDashboard ? .claude : .symbol(Self.symbol(for: action)),
                                trailing: action.shortcut?.displayString) { _ in c.perform(action) })
            }
            all.append(Item(id: "install-hooks", section: .actions, title: "Install Claude Code & Codex notifications",
                            tile: .symbol("bell.badge")) { _ in SettingsWindowController.shared.show(pane: .integrations) })
        }
        if q.includes(.themes) {
            let dark = ConfigController.shared.isDark
            for theme in ThemeLibrary.shared.themes where theme.isDark == dark {
                all.append(Item(id: "theme:\(theme.name)", section: .themes, title: theme.name, subtitle: dark ? "Dark theme" : "Light theme",
                                tile: .symbol("paintpalette")) { _ in
                    if dark { SettingsStore.shared.settings.darkTheme = theme.name } else { SettingsStore.shared.settings.lightTheme = theme.name }
                })
            }
        }
        if q.includes(.history), !q.text.isEmpty {
            for cmd in HistoryStore.shared.search(q.text, limit: 30) {
                all.append(Item(id: "history:\(cmd)", section: .history, title: cmd, subtitle: "Run in this pane",
                                tile: .symbol("clock.arrow.circlepath")) { _ in
                    if let s = c.focusedSession, s.state == .idle { s.submit(command: cmd) }
                })
            }
        }
        return all
    }

    private func tabItems() -> [Item] {
        let c = controller
        return c.workspace.tabs.enumerated().map { i, tab in
            var parts: [String] = []
            if let state = TabPresentation.agentSummary(tab) { parts.append(state) }
            if let repo = tab.focusedSession.flatMap({ c.repository(for: $0) }), let pr = repo.pullRequest {
                parts.append("PR #\(pr.number)")
            }
            if parts.isEmpty { parts.append(tab.subtitle) }
            return Item(id: "tab:\(tab.id)", section: .tabs, title: tab.title, subtitle: parts.joined(separator: " · "),
                        tile: TabPresentation.tile(for: tab), trailing: i < 9 ? "⌘\(i + 1)" : nil) { _ in c.select(tab) }
        }
    }

    private func worktreeItems() -> [Item] {
        guard let worktrees else { return [] }
        let c = controller
        return worktrees.worktrees.filter { !$0.isBare }.map { w in
            let open = c.tabIndex(showing: w.path)
            let tab = open.map { c.workspace.tabs[$0] }
            var parts: [String] = [repoName ?? (w.path as NSString).lastPathComponent]
            if let tab, let state = TabPresentation.agentSummary(tab) { parts.append(state) }
            if let changes = w.changes { parts.append(changes == 0 ? "clean" : "\(changes) change\(changes == 1 ? "" : "s")") }
            if w.trackingKnown, w.branch != nil, w.upstream == nil, !w.isMain { parts.append("not pushed") }
            if w.ahead > 0 { parts.append("↑\(w.ahead)") }
            if let pr = w.pullRequest { parts.append("PR #\(pr.number)") }
            if tab == nil { parts.append("not open") }
            let title = w.branch ?? (w.isDetached ? "detached @ \(w.head ?? "?")" : (w.path as NSString).lastPathComponent)
            let isClaude = tab.map { TabPresentation.tile(for: $0) }.map { if case .claude = $0 { true } else { false } } ?? false
            return placeItem(id: "worktree:\(w.path)", section: .worktrees, title: title, subtitle: parts.joined(separator: " · "),
                             tile: isClaude ? .claude : .worktree, directory: w.path,
                             trailing: open.map { $0 < 9 ? "⌘\($0 + 1)" : "Open" } ?? "Open in new tab")
        }
    }

    /// A worktree or folder: ⏎ goes to it (an open tab, else a new one),
    /// ⌘⏎ always opens a new tab, ⌥⏎ starts Claude there in a new tab.
    private func placeItem(id: String, section: PaletteSection, title: String, subtitle: String, tile: TileKind,
                           directory: String, trailing: String? = nil) -> Item {
        let c = controller
        let open = c.tabIndex(showing: directory)
        return Item(id: id, section: section, title: title, subtitle: subtitle, tile: tile,
                    trailing: trailing ?? open.flatMap { $0 < 9 ? "⌘\($0 + 1)" : nil }, takesModifiers: true) { modifier in
            switch modifier {
            case .plain: c.switchToDirectory(directory)
            case .newTab: c.newTab(directory: directory)
            case .claude: c.startClaude(in: directory)
            }
        }
    }

    private static func standard(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

    private static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private static func symbol(for action: ShortcutAction) -> String {
        switch action.category {
        case .app: "gearshape"
        case .windows: "macwindow"
        case .panes: "rectangle.split.2x1"
        case .terminal: "terminal"
        case .view: "eye"
        }
    }

    // MARK: Apple Intelligence

    /// Commands the model may pick from: every action except the ones that
    /// only make sense as keys, plus each Settings pane.
    private func intentChoices() -> [(choice: IntelligencePrompts.Choice, item: Item)] {
        let c = controller
        let skipped: Set<ShortcutAction> = [.commandPalette, .copy, .paste, .selectAll, .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8]
        var list: [(IntelligencePrompts.Choice, Item)] = []
        for action in ShortcutAction.allCases where !skipped.contains(action) {
            let title = action.title.replacingOccurrences(of: "…", with: "")
            list.append((IntelligencePrompts.Choice(id: action.rawValue, title: title),
                         Item(id: "intent:\(action.rawValue)", section: .suggested, title: title, subtitle: "Suggested · \(action.category.rawValue)",
                              tile: .symbol("sparkles"), trailing: action.shortcut?.displayString) { _ in c.perform(action) }))
        }
        for pane in SettingsPane.allCases {
            list.append((IntelligencePrompts.Choice(id: "settings." + pane.rawValue, title: "Open \(pane.title) settings"),
                         Item(id: "intent:settings.\(pane.rawValue)", section: .suggested, title: "\(pane.title) Settings",
                              subtitle: "Suggested · Settings", tile: .symbol("sparkles")) { _ in SettingsWindowController.shared.show(pane: pane) }))
        }
        return list
    }

    /// Asks the model which command a request like "split the pane and zoom
    /// in" means, after a short pause in typing.
    private func scheduleIntent() {
        intentTask?.cancel()
        let q = query
        let parsed = PaletteQuery.parse(q)
        guard parsed.scope != .places, Intelligence.isEnabled(.paletteIntents), IntelligencePrompts.looksLikeRequest(parsed.text) else { return }
        intentTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            let choices = intentChoices()
            guard let id = await Intelligence.paletteIntent(for: parsed.text, choices: choices.map(\.choice)),
                  !Task.isCancelled, query == q, let match = choices.first(where: { $0.choice.id == id }) else { return }
            intent = (q, match.item)
            // Keep the highlighted row where it is while the suggestion lands on top.
            recompute(keepSelection: true)
        }
    }
}

struct PaletteView: View {
    @Bindable var model: PaletteModel
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme
    /// The design's palette corner: rounder than other panels.
    static let radius: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Color.primary.opacity(0.09).frame(height: 0.5)
            results
            Color.primary.opacity(0.09).frame(height: 0.5)
            footer
        }
        .frame(width: CommandPalette.size.width, height: CommandPalette.size.height)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5))
        .onAppear { focused = true }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
            TextField("Go to a tab, worktree, folder or action…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .focused($focused)
                .onKeyPress(.upArrow) { model.selected = max(0, model.selected - 1); return .handled }
                .onKeyPress(.downArrow) { model.selected = min(model.rows.count - 1, model.selected + 1); return .handled }
                .onKeyPress(.escape) { CommandPalette.close(); return .handled }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.command) {
                        model.run(.newTab)
                    } else if press.modifiers.contains(.option) {
                        model.run(.claude)
                    } else {
                        model.run(.plain)
                    }
                    return .handled
                }
            KeyHint("esc", boxed: true)
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.rows.isEmpty {
                        Text("No matches").font(.system(size: DS.Size.body)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                    let offsets = sectionOffsets
                    ForEach(Array(model.sections.enumerated()), id: \.element.id) { si, section in
                        Text(section.section.title)
                            .font(.system(size: DS.Size.small, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, si == 0 ? 8 : 10)
                            .padding(.bottom, 4)
                        ForEach(Array(section.items.enumerated()), id: \.element.id) { i, item in
                            let idx = offsets[si] + i
                            PaletteRow(item: item, selected: idx == model.selected)
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    model.selected = idx
                                    let flags = NSEvent.modifierFlags
                                    model.run(flags.contains(.command) ? .newTab : flags.contains(.option) ? .claude : .plain)
                                }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }
            .onChange(of: model.selected) { _, i in
                if model.rows.indices.contains(i) { proxy.scrollTo(model.rows[i].id) }
            }
        }
    }

    /// Index of each section's first row in the flattened list.
    private var sectionOffsets: [Int] {
        var result: [Int] = []
        var n = 0
        for s in model.sections {
            result.append(n)
            n += s.items.count
        }
        return result
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↑↓", "select")
            hint("⏎", "open")
            hint("⌘⏎", "open in new tab")
            hint("⌥⏎", "start Claude there")
            Spacer(minLength: 8)
            Text("Type > for commands, @ for folders")
        }
        .font(.system(size: DS.Size.subtitle))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 18)
        .frame(height: 36)
        .background(Color.black.opacity(colorScheme == .dark ? 0.12 : 0.03))
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(keys)
            Text(label)
        }
    }
}

struct PaletteRow: View {
    let item: PaletteModel.Item
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            PaletteTile(kind: item.tile, bare: item.subtitle.isEmpty, selected: selected)
            VStack(alignment: .leading, spacing: 1) {
                highlightedTitle
                    .font(.system(size: DS.Size.title))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.system(size: DS.Size.subtitle))
                        .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            if let trailing = item.trailing {
                Text(trailing)
                    .font(.system(size: DS.Size.subtitle))
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary.opacity(0.8))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        // Places (two lines) are 40pt, actions 34pt, as designed.
        .frame(height: item.subtitle.isEmpty ? 34 : 40)
        .background(RoundedRectangle(cornerRadius: DS.Radius.row).fill(selected ? DS.Status.selection : .clear))
    }

    /// The title with the matched characters in bold.
    private var highlightedTitle: Text {
        guard !item.matches.isEmpty else { return Text(item.title) }
        let marks = Set(item.matches)
        var attributed = AttributedString()
        for (i, ch) in item.title.enumerated() {
            var piece = AttributedString(String(ch))
            if marks.contains(i) { piece.font = .system(size: DS.Size.title, weight: .bold) }
            attributed += piece
        }
        return Text(attributed)
    }
}

/// A result's leading mark: the 22pt kind tile for places and tabs, a bare
/// glyph for one-line actions, and a white-on-translucent tile on the
/// selected (blue) row.
struct PaletteTile: View {
    let kind: TileKind
    var bare = false
    var selected = false

    var body: some View {
        if selected {
            glyph(color: .white)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(Color.white.opacity(bare ? 0 : 0.18)))
        } else if bare {
            glyph(color: nil).frame(width: 22, height: 22)
        } else {
            KindTile(kind: kind, size: 22)
        }
    }

    @ViewBuilder private func glyph(color: Color?) -> some View {
        let tint = color ?? Color.secondary
        switch kind {
        case .claude: ClaudeMark(size: 12, color: color ?? DS.claude)
        case .terminal: Text("›_").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(tint)
        case .codex: Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(tint)
        case .github: GitHubMark().fill(color ?? Color.primary.opacity(0.9)).frame(width: 13, height: 13)
        case .worktree: BranchGlyph(size: 11).foregroundStyle(tint)
        case .folder: Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(tint)
        case .symbol(let name): Image(systemName: name).font(.system(size: 11)).foregroundStyle(tint)
        }
    }
}
