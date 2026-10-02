import Foundation

// Turns a native Claude session's live state into the inspector's plain
// inputs, so the inspector views stay independent of ClaudeCodeSession.

extension InspectorTodo.State {
    init(_ status: ClaudeTodo.Status) {
        self = switch status {
        case .pending: .pending
        case .inProgress: .inProgress
        case .completed: .completed
        }
    }
}

extension InspectorTodo {
    /// The to-do as written ("File the issue and PR"); the status line above
    /// the composer says what's happening now ("Writing the PR description").
    init(_ todo: ClaudeTodo, index: Int) {
        self.init(id: "\(index)-\(todo.content)", title: todo.content, state: State(todo.status))
    }
}

extension InspectorBackgroundItem {
    init(_ task: ClaudeBackgroundTask) {
        let kind: Kind = task.kind == .subagent ? .subagent : .backgroundTask
        var detail = task.detail
        if kind == .subagent, !task.toolSummary.isEmpty {
            detail = [task.detail, task.toolSummary].compactMap { $0 }.joined(separator: " · ")
        }
        let isCommand = kind == .backgroundTask && task.detail == nil && task.command != nil
        self.init(id: task.id, name: task.title, kind: kind, startedAt: task.startedAt, isRunning: task.isRunning,
                  detail: isCommand ? task.command : detail, detailIsCommand: isCommand)
    }
}

extension InspectorSessionInputs {
    /// The Session tab's inputs for a native Claude session. Background work
    /// shows while it runs and for a minute after it ends.
    @MainActor
    init(session claude: ClaudeCodeSession, now: Date = Date()) {
        self.init()
        todos = claude.todos.enumerated().map { InspectorTodo($0.element, index: $0.offset) }
        background = claude.backgroundTasks
            .filter { $0.isRunning || ($0.endedAt.map { now.timeIntervalSince($0) < 60 } ?? false) }
            .map(InspectorBackgroundItem.init)
        onReview = { [weak claude] in claude?.requestReviewChanges() }
        onOpenFile = { [weak claude] change in claude?.requestReviewChanges(path: change.path) }
    }
}
