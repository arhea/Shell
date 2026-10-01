import AppKit
import SwiftUI

/// Small formatting helpers shared by the inspector's panels.
enum InspectorFormat {
    /// "41s", "3m 14s", "1h 02m".
    static func duration(_ d: TimeInterval) -> String {
        let s = max(0, Int(d.rounded()))
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return String(format: "%dm %02ds", m, s % 60) }
        return String(format: "%dh %02dm", m / 60, m % 60)
    }

    /// "just now", "6 min ago", "2 h ago", "3 days ago".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 45 { return "just now" }
        if s < 3600 { return "\(max(1, s / 60)) min ago" }
        if s < 86400 { return "\(s / 3600) h ago" }
        let d = s / 86400
        return d == 1 ? "1 day ago" : "\(d) days ago"
    }

    static func color(_ kind: InspectorChange.Kind) -> Color {
        switch kind {
        case .modified, .renamed: DS.Status.working
        case .added: DS.Status.done
        case .deleted, .conflicted: DS.Status.failed
        }
    }
}

/// The Session tab for a Claude pane: changed files, the agent's to-dos, and
/// subagents and background tasks still running.
struct InspectorSessionView: View {
    let changes: [InspectorChange]
    let todos: [InspectorTodo]
    let background: [InspectorBackgroundItem]
    var onReview: (() -> Void)?
    var onOpenFile: (InspectorChange) -> Void
    var onStop: (InspectorBackgroundItem) -> Void
    var onViewTranscript: (InspectorBackgroundItem) -> Void

    init(changes: [InspectorChange], todos: [InspectorTodo], background: [InspectorBackgroundItem],
         onReview: (() -> Void)? = nil, onOpenFile: @escaping (InspectorChange) -> Void,
         onStop: @escaping (InspectorBackgroundItem) -> Void, onViewTranscript: @escaping (InspectorBackgroundItem) -> Void) {
        self.changes = changes
        self.todos = todos
        self.background = background
        self.onReview = onReview
        self.onOpenFile = onOpenFile
        self.onStop = onStop
        self.onViewTranscript = onViewTranscript
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                changesSection
                if !todos.isEmpty { todosSection }
                if !background.isEmpty { backgroundSection }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    // MARK: Changes

    private var changesSection: some View {
        let totals = InspectorChangeTotals(changes)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Changes").font(.system(size: DS.Size.body, weight: .semibold))
                if totals.files > 0 {
                    Text("\(totals.files) file\(totals.files == 1 ? "" : "s")").foregroundStyle(.secondary)
                    Text("+\(totals.additions)").foregroundStyle(DS.Status.done)
                    Text("−\(totals.deletions)").foregroundStyle(DS.Status.failed)
                }
                Spacer(minLength: 4)
                if let onReview, totals.files > 0 {
                    Button("Review", action: onReview)
                        .buttonStyle(.plain)
                        .foregroundStyle(DS.Status.info)
                        .help("Review the changes (⇧⌘R)")
                }
            }
            .font(.system(size: DS.Size.small))
            .monospacedDigit()
            if changes.isEmpty {
                Text("No uncommitted changes").font(.system(size: DS.Size.small)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(changes) { change in
                        InspectorChangeRow(change: change) { onOpenFile(change) }
                    }
                }
            }
        }
    }

    // MARK: To-dos

    private var todosSection: some View {
        let done = todos.filter { $0.state == .completed }.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("To-dos").font(.system(size: DS.Size.body, weight: .semibold))
                Text("\(done) of \(todos.count)").font(.system(size: DS.Size.small)).foregroundStyle(.secondary)
            }
            ForEach(todos) { todo in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    todoMark(todo.state).frame(width: 12, height: 12).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                    Text(todo.title)
                        .font(.system(size: DS.Size.body, weight: todo.state == .inProgress ? .medium : .regular))
                        .foregroundStyle(todo.state == .completed ? .secondary : .primary)
                        .strikethrough(todo.state == .completed)
                        .lineLimit(2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(todo.state == .completed ? "Done" : todo.state == .inProgress ? "In progress" : "Not started")
            }
        }
    }

    @ViewBuilder
    private func todoMark(_ state: InspectorTodo.State) -> some View {
        switch state {
        case .completed:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(DS.Status.done)
        case .inProgress:
            SpinnerRing(size: 11)
        case .pending:
            Circle().strokeBorder(Color.secondary, lineWidth: 1.2).frame(width: 11, height: 11)
        }
    }

    // MARK: Background

    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Running in background").font(.system(size: DS.Size.body, weight: .semibold))
                Text("\(background.count)").font(.system(size: DS.Size.small)).foregroundStyle(.secondary)
            }
            ForEach(background) { item in
                InspectorBackgroundCard(item: item, onStop: { onStop(item) }, onViewTranscript: { onViewTranscript(item) })
            }
        }
    }
}

/// "M  AppDelegate.swift App      +4 −1". Clicking opens the file or its diff.
struct InspectorChangeRow: View {
    let change: InspectorChange
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(change.letter)
                    .font(.system(size: DS.Size.small, weight: .bold, design: .monospaced))
                    .foregroundStyle(InspectorFormat.color(change.kind))
                    .frame(width: 12)
                HStack(spacing: 5) {
                    Text(change.fileName)
                        .foregroundStyle(.primary)
                        .strikethrough(change.kind == .deleted)
                        .lineLimit(1).truncationMode(.middle)
                        .layoutPriority(1)
                    if let folder = change.folder {
                        Text(folder).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
                .font(.system(size: DS.Size.body))
                Spacer(minLength: 6)
                HStack(spacing: 5) {
                    if let a = change.additions, a > 0 { Text("+\(a)").foregroundStyle(.secondary) }
                    if let d = change.deletions, d > 0 { Text("−\(d)").foregroundStyle(.secondary) }
                }
                .font(.system(size: DS.Size.small))
                .monospacedDigit()
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .rowBackground(selected: false, hovering: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(change.path)
    }
}

/// One subagent or background task: spinner, name, kind, elapsed time,
/// what it's doing, and its links.
struct InspectorBackgroundCard: View {
    let item: InspectorBackgroundItem
    var onStop: () -> Void
    var onViewTranscript: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                if item.isRunning { SpinnerRing(size: 11) } else {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(DS.Status.done)
                }
                Text(item.name).font(.system(size: DS.Size.body, weight: .semibold)).lineLimit(1)
                Pill(item.kind.label, color: .secondary)
                Spacer(minLength: 4)
                if let started = item.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(InspectorFormat.duration(ctx.date.timeIntervalSince(started)))
                            .font(.system(size: DS.Size.small)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            if let detail = item.detail {
                Text(detail)
                    .font(item.detailIsCommand ? .system(size: DS.Size.small, design: .monospaced) : .system(size: DS.Size.small))
                    .foregroundStyle(item.detailIsCommand ? .secondary : .primary)
                    .lineLimit(2).truncationMode(.middle)
            }
            if !item.jobs.isEmpty {
                VStack(spacing: 3) {
                    ForEach(item.jobs) { job in
                        HStack(spacing: 7) {
                            CheckStateMark(state: job.state, size: 11)
                            Text(job.name).font(.system(size: DS.Size.small)).lineLimit(1)
                            Spacer(minLength: 4)
                            if let d = job.detail { Text(d).font(.system(size: DS.Size.small)).monospacedDigit().foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                Button(item.kind == .subagent ? "View transcript" : "Output", action: onViewTranscript)
                    .foregroundStyle(DS.Status.info)
                if item.isRunning {
                    Button("Stop", action: onStop).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: DS.Size.small))
        }
        .padding(10)
        .cardSurface()
    }
}
