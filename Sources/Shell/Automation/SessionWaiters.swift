import Foundation

/// Lets automation wait for something a session reports over the control
/// socket: a command finishing (the next prompt) or an agent hook event.
///
/// `TerminalSession` calls `notify` from `promptReady`, `agentEvent` and
/// `close`; each waiter decides whether the event is the one it wants.
@MainActor
final class SessionWaiters {
    static let shared = SessionWaiters()

    enum Event {
        /// A command finished and the shell is back at a prompt.
        case commandFinished
        /// An agent hook reported `event` (working, needs-input, finished, ended).
        case agent(AgentKind, event: String, message: String?)
        /// The pane was closed.
        case closed
    }

    /// One pending wait. `handle` returns true once it has resumed its
    /// continuation, which removes it.
    private final class Waiter {
        let token = UUID()
        var handle: (Event?) -> Bool = { _ in false }
        var timeout: Task<Void, Never>?
    }

    private var waiters: [UUID: [Waiter]] = [:]

    var pendingCount: Int { waiters.values.reduce(0) { $0 + $1.count } }

    func notify(_ sessionID: UUID, _ event: Event) {
        guard let list = waiters[sessionID] else { return }
        let remaining = list.filter { !$0.handle(event) }
        waiters[sessionID] = remaining.isEmpty ? nil : remaining
    }

    /// Suspends until `match` returns a result for an event on `sessionID`,
    /// or throws `timedOut` / `sessionClosed`. `register` runs after the
    /// waiter is installed, so an action that triggers the event can't race it.
    func wait<T: Sendable>(
        on sessionID: UUID,
        timeout seconds: TimeInterval,
        register: () throws -> Void = {},
        match: @escaping (Event) -> T?
    ) async throws -> T {
        let waiter = Waiter()
        let token = waiter.token
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                waiter.handle = { [weak waiter] event in
                    guard let waiter else { return true }
                    let result: Result<T, Error>
                    switch event {
                    case nil: result = .failure(AutomationError.timedOut)
                    case .closed?: result = .failure(AutomationError.sessionClosed)
                    case let event?:
                        guard let value = match(event) else { return false }
                        result = .success(value)
                    }
                    waiter.timeout?.cancel()
                    waiter.handle = { _ in true }
                    continuation.resume(with: result)
                    return true
                }
                waiters[sessionID, default: []].append(waiter)
                waiter.timeout = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(max(seconds, 1)))
                    guard !Task.isCancelled else { return }
                    self?.expire(token, sessionID: sessionID)
                }
                do {
                    try register()
                } catch {
                    remove(token, sessionID: sessionID)
                    waiter.timeout?.cancel()
                    waiter.handle = { _ in true }
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { @MainActor in self.expire(token, sessionID: sessionID) }
        }
    }

    private func expire(_ token: UUID, sessionID: UUID) {
        guard let waiter = waiters[sessionID]?.first(where: { $0.token == token }) else { return }
        remove(token, sessionID: sessionID)
        _ = waiter.handle(nil)
    }

    private func remove(_ token: UUID, sessionID: UUID) {
        waiters[sessionID]?.removeAll { $0.token == token }
        if waiters[sessionID]?.isEmpty == true { waiters[sessionID] = nil }
    }
}
