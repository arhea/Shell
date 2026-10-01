import SwiftUI

/// Rows of the native view's transcript: items, or a folded run of tool calls.
@MainActor
enum ClaudeTranscript {
    enum Row: Identifiable {
        case item(ClaudeItem)
        /// Consecutive tool calls (and the thinking between them), folded.
        case tools([ClaudeItem])

        var id: UUID {
            switch self {
            case .item(let i): i.id
            case .tools(let items): items[0].id
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
    /// everything after the last user message.
    static func rows(_ items: [ClaudeItem], mode: ToolCallDisplay) -> [Row] {
        guard mode != .showAll else { return items.map { .item($0) } }
        let currentTurnStart = mode == .collapsePrevious ? (items.lastIndex { $0.kind == .user } ?? -1) + 1 : items.count
        var rows: [Row] = []
        var run: [ClaudeItem] = []
        func flush() {
            // A run without a tool call (just thinking) stays as it was.
            if run.contains(where: { $0.kind == .tool }) {
                rows.append(.tools(run))
            } else {
                rows += run.map { .item($0) }
            }
            run = []
        }
        for (index, item) in items.enumerated() {
            if index < currentTurnStart, folds(item) {
                run.append(item)
            } else {
                flush()
                rows.append(.item(item))
            }
        }
        flush()
        return rows
    }
}

/// A folded run of tool calls: "6 tool calls · Read 3 · Edit 2 · Bash 1".
struct ToolGroupView: View {
    let items: [ClaudeItem]
    let palette: ClaudePalette
    let mentions: InlineMarkdown.MentionStyle
    let fontSize: CGFloat
    var directory: String?
    @State var expanded = false

    var body: some View {
        let p = palette
        let tools = items.filter { $0.kind == .tool }
        let failed = tools.filter(\.isError).count
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(p.dim)
                        .frame(width: 12)
                    Image(systemName: "wrench.and.screwdriver").foregroundStyle(p.dim).frame(width: 14)
                    Text("\(tools.count) tool call\(tools.count == 1 ? "" : "s")")
                        .font(.system(size: fontSize - 1, weight: .semibold))
                        .foregroundStyle(p.foreground)
                    Text(Self.breakdown(tools))
                        .font(.system(size: fontSize - 1.5))
                        .foregroundStyle(p.dim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if failed > 0 {
                        Text("\(failed) failed").font(.system(size: fontSize - 1.5, weight: .medium)).foregroundStyle(p.red)
                    }
                    if tools.contains(where: \.isRunning) { ProgressView().controlSize(.mini) }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Collapse tool calls" : "Show tool calls")
            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(items) { item in
                        ClaudeItemView(item: item, palette: p, mentions: mentions, fontSize: fontSize, directory: directory)
                            .equatable()
                    }
                }
                .padding(.leading, 19)
            }
        }
        .padding(.vertical, 2)
    }

    /// "Read 3 · Edit 2 · Bash", most used first.
    static func breakdown(_ tools: [ClaudeItem]) -> String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for t in tools {
            let name = ClaudeToolFormat.displayName(t.toolName)
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        return order.sorted { counts[$0]! > counts[$1]! }
            .map { counts[$0]! > 1 ? "\($0) \(counts[$0]!)" : $0 }
            .joined(separator: " · ")
    }
}
