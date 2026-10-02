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
        case .modified, .renamed: DS.Status.needsYou
        case .added: DS.Status.done
        case .deleted, .conflicted: DS.Status.failed
        }
    }

    /// Line counts ("+79", "−3") in the code font.
    @MainActor
    static func countFont(_ size: CGFloat = DS.Size.small) -> Font { ChatTypography.current.codeFont(size: size) }
}

/// A section title with a dimmed detail: "Changes  3 files +79 −3", "To-dos  4 of 6".
struct InspectorSectionTitle<Detail: View>: View {
    let title: String
    @ViewBuilder var detail: Detail

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold))
            detail.font(.system(size: DS.Size.subtitle)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
    }
}

/// ✓ in a green disc, the working spinner, or an empty ring: a to-do's state.
struct TodoStateMark: View {
    let state: InspectorTodo.State
    var size: CGFloat = 14

    var body: some View {
        Group {
            switch state {
            case .completed:
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.55, weight: .bold))
                    .foregroundStyle(DS.Status.done)
                    .frame(width: size, height: size)
                    .background(DS.Status.done.opacity(0.2), in: Circle())
            case .inProgress:
                SpinnerRing(size: size)
            case .pending:
                Circle().strokeBorder(Color.secondary.opacity(0.8), lineWidth: 1.5).frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
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
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 14)
        }
    }

    // MARK: Changes

    private var changesSection: some View {
        let totals = InspectorChangeTotals(changes)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                InspectorSectionTitle(title: "Changes") {
                    if totals.files > 0 {
                        Text("\(totals.files) file\(totals.files == 1 ? "" : "s")")
                    }
                }
                if totals.files > 0 {
                    HStack(spacing: 5) {
                        Text("+\(totals.additions)").foregroundStyle(DS.Status.done)
                        Text("−\(totals.deletions)").foregroundStyle(DS.Status.failed)
                    }
                    .font(InspectorFormat.countFont())
                }
                Spacer(minLength: 4)
                if let onReview, totals.files > 0 {
                    Button("Review", action: onReview)
                        .buttonStyle(.plain)
                        .font(.system(size: DS.Size.subtitle))
                        .foregroundStyle(DS.Status.info)
                        .help("Review the changes (⇧⌘R)")
                }
            }
            if changes.isEmpty {
                Text("No uncommitted changes").font(.system(size: DS.Size.subtitle)).foregroundStyle(.secondary).padding(.horizontal, 2)
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
            InspectorSectionTitle(title: "To-dos") { Text("\(done) of \(todos.count)") }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(todos) { todo in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        TodoStateMark(state: todo.state).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                        Text(todo.title)
                            .font(.system(size: DS.Size.body, weight: todo.state == .inProgress ? .medium : .regular))
                            .foregroundStyle(todo.state == .completed ? AnyShapeStyle(.secondary)
                                             : todo.state == .pending ? AnyShapeStyle(Color.primary.opacity(0.8)) : AnyShapeStyle(.primary))
                            .strikethrough(todo.state == .completed)
                            .lineLimit(2)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(todo.state == .completed ? "Done" : todo.state == .inProgress ? "In progress" : "Not started")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
        }
    }

    // MARK: Background

    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorSectionTitle(title: "Running in background") { Text("\(background.count)") }
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
                    .font(.system(size: DS.Size.small, weight: .bold))
                    .foregroundStyle(InspectorFormat.color(change.kind))
                    .frame(width: 16)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(change.fileName)
                        .font(.system(size: DS.Size.body))
                        .foregroundStyle(.primary)
                        .strikethrough(change.kind == .deleted)
                        .lineLimit(1).truncationMode(.middle)
                        .layoutPriority(1)
                    if let folder = change.folder {
                        Text(folder).font(.system(size: DS.Size.subtitle)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 6)
                HStack(spacing: 5) {
                    if let a = change.additions, a > 0 { Text("+\(a)") }
                    if let d = change.deletions, d > 0 { Text("−\(d)") }
                }
                .font(InspectorFormat.countFont())
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.control))
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
            HStack(spacing: 8) {
                if item.isRunning { SpinnerRing(size: 11) } else {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(DS.Status.done)
                }
                Text(item.name).font(.system(size: DS.Size.body, weight: .semibold)).lineLimit(1)
                Text(item.kind.label)
                    .font(.system(size: DS.Size.small))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                    .fixedSize()
                Spacer(minLength: 4)
                if let started = item.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(InspectorFormat.duration(ctx.date.timeIntervalSince(started)))
                            .font(.system(size: DS.Size.subtitle)).monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
            }
            if let detail = item.detail {
                Text(detail)
                    .font(item.detailIsCommand ? InspectorFormat.countFont() : .system(size: 12))
                    .foregroundStyle(item.detailIsCommand ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.primary.opacity(0.8)))
                    .lineLimit(item.detailIsCommand ? 1 : 2).truncationMode(item.detailIsCommand ? .tail : .middle)
            }
            if !item.jobs.isEmpty {
                VStack(spacing: 4) {
                    ForEach(item.jobs) { job in
                        HStack(spacing: 8) {
                            CheckStateMark(state: job.state, size: 10)
                            Text(job.name).font(.system(size: 12)).lineLimit(1)
                                .foregroundStyle(job.state == .queued ? .secondary : .primary)
                            Spacer(minLength: 4)
                            if let d = job.detail {
                                Text(d).font(.system(size: DS.Size.subtitle)).monospacedDigit()
                                    .foregroundStyle(job.state == .queued ? .secondary : .tertiary)
                            }
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
            .font(.system(size: DS.Size.subtitle))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}
