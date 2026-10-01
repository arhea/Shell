import SwiftUI

/// Rows of the native view's transcript: items, folded work, visible tool
/// runs, and end-of-turn summaries.
@MainActor
enum ClaudeTranscript {
    enum Row: Identifiable {
        case item(ClaudeItem)
        /// Earlier work folded into one "Worked for…" row: consecutive tool
        /// calls with the thinking (and, in finished turns, the in-between
        /// text) around them.
        case tools([ClaudeItem])
        /// Two or more consecutive tool calls shown as one card with a row per step.
        case run([ClaudeItem])
        /// The summary card after a finished turn that changed files or
        /// committed. Holds the turn's items, its user message first.
        case summary([ClaudeItem])

        var id: UUID {
            switch self {
            case .item(let i): i.id
            case .tools(let items), .run(let items): items[0].id
            case .summary(let items): items[0].summaryID
            }
        }
    }

    /// Tools with their own cards (questions, plans, to-dos) never fold.
    static func folds(_ item: ClaudeItem) -> Bool {
        switch item.kind {
        case .tool: !["AskUserQuestion", "ExitPlanMode", "TodoWrite"].contains(item.toolName)
        case .thinking: true
        default: false
        }
    }

    /// Folds runs of tool calls according to `mode`. The current turn is
    /// everything after the last user message; `turnRunning` keeps its
    /// summary card back until it ends.
    static func rows(_ items: [ClaudeItem], mode: ToolCallDisplay, turnRunning: Bool = false) -> [Row] {
        let currentTurnStart = (items.lastIndex { $0.kind == .user } ?? -1) + 1
        let foldBefore: Int
        switch mode {
        case .showAll: foldBefore = 0
        case .collapsePrevious: foldBefore = currentTurnStart
        case .collapseAll: foldBefore = items.count
        }
        return build(items, foldBefore: foldBefore, groupRuns: mode != .showAll, summaries: true,
                     turnRunning: turnRunning, currentTurnStart: currentTurnStart)
    }

    /// The rows inside an expanded fold: runs grouped, nothing folded.
    static func visibleRows(_ items: [ClaudeItem]) -> [Row] {
        build(items, foldBefore: 0, groupRuns: true, summaries: false, turnRunning: false, currentTurnStart: 0)
    }

    /// How a visible tool call groups: light steps (reads, searches, quick
    /// commands) into one run, consecutive edits into another; nil stands
    /// alone (a single edit's diff, a build or test command's output).
    enum RunKind { case light, edit }

    static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

    static func runKind(_ item: ClaudeItem) -> RunKind? {
        guard item.kind == .tool, folds(item) else { return nil }
        if editTools.contains(item.toolName) { return .edit }
        if item.toolName == "Bash", isProminentCommand(item) { return nil }
        return .light
    }

    /// Builds, tests and lints, and anything that failed, get their own output card.
    static func isProminentCommand(_ item: ClaudeItem) -> Bool {
        if item.isError { return true }
        let command = (item.input["command"] as? String ?? "").lowercased()
        return command.firstMatch(of: /\b(test|tests|build|lint|check|xcodebuild|pytest|cargo|make|tsc)\b/) != nil
    }

    /// Whether a finished turn gets a summary card: it changed a file or committed.
    static func hasChanges(_ item: ClaudeItem) -> Bool {
        guard item.kind == .tool, item.result != nil, !item.isError else { return false }
        if item.diffStats != nil { return true }
        return item.toolName == "Bash" && (item.input["command"] as? String ?? "").contains("git commit")
    }

    private static func build(_ items: [ClaudeItem], foldBefore: Int, groupRuns: Bool, summaries: Bool,
                              turnRunning: Bool, currentTurnStart: Int) -> [Row] {
        // In finished turns that fold, text between tool calls folds too:
        // only the turn's last reply stays out.
        var intermediate = Set<Int>()
        var toolLater = false
        for i in stride(from: items.count - 1, through: 0, by: -1) {
            let item = items[i]
            if item.kind == .user { toolLater = false; continue }
            if folds(item), item.kind == .tool { toolLater = true }
            if item.kind == .assistant, toolLater, i < min(foldBefore, currentTurnStart) { intermediate.insert(i) }
        }

        var rows: [Row] = []
        var fold: [ClaudeItem] = []
        var run: [ClaudeItem] = []
        var turn: [ClaudeItem] = []
        var turnChanged = false

        func flushFold() {
            // A fold without a tool call (just thinking) stays as it was.
            if fold.contains(where: { $0.kind == .tool }) { rows.append(.tools(fold)) } else { rows += fold.map { .item($0) } }
            fold = []
        }
        func flushRun() {
            guard let lastTool = run.lastIndex(where: { $0.kind == .tool }) else {
                rows += run.map { .item($0) }
                run = []
                return
            }
            let core = Array(run[...lastTool])
            let tools = core.filter { $0.kind == .tool }
            // A lone edit shows its diff card; a lone light step its one-row card.
            if tools.count >= 2 { rows.append(.run(core)) } else { rows += core.map { .item($0) } }
            rows += run[(lastTool + 1)...].map { .item($0) }
            run = []
        }
        func endTurn() {
            flushFold()
            flushRun()
            if summaries, turnChanged, !turn.isEmpty { rows.append(.summary(turn)) }
            turn = []
            turnChanged = false
        }

        for (i, item) in items.enumerated() {
            if item.kind == .user {
                endTurn()
                turn = [item]
                rows.append(.item(item))
                continue
            }
            turn.append(item)
            if hasChanges(item) { turnChanged = true }
            if i < foldBefore, folds(item) || intermediate.contains(i) {
                flushRun()
                fold.append(item)
                continue
            }
            flushFold()
            if groupRuns, let kind = runKind(item) {
                if let current = run.first(where: { $0.kind == .tool }).flatMap(runKind), current != kind { flushRun() }
                run.append(item)
            } else if groupRuns, item.kind == .thinking, !run.isEmpty {
                run.append(item)
            } else {
                flushRun()
                rows.append(.item(item))
            }
        }
        flushFold()
        flushRun()
        if !turnRunning { endTurn() }
        return rows
    }
}

/// Renders one transcript row.
struct ClaudeRowView: View {
    let row: ClaudeTranscript.Row
    let palette: ClaudePalette
    let mentions: InlineMarkdown.MentionStyle
    let fontSize: CGFloat
    var directory: String?
    var session: ClaudeCodeSession?

    var body: some View {
        switch row {
        case .item(let item):
            ClaudeItemView(item: item, palette: palette, mentions: mentions, fontSize: fontSize, directory: directory, session: session)
                .equatable()
        case .tools(let items):
            ToolGroupView(items: items, palette: palette, mentions: mentions, fontSize: fontSize, directory: directory, session: session)
        case .run(let items):
            ToolRunCard(items: items, palette: palette, fontSize: fontSize, directory: directory, session: session)
        case .summary(let items):
            TurnSummaryCard(items: items, palette: palette, fontSize: fontSize, directory: directory, session: session)
        }
    }
}
