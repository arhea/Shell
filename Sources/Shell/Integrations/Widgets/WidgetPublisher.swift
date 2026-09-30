import Foundation
import Observation
import WidgetKit

/// Keeps the desktop widgets' snapshot current. Watches the dashboard's
/// sessions and `ClaudeUsage`, writes `WidgetSnapshot` to the app group
/// container, and asks WidgetKit to reload — right away when an agent's
/// state changes, at most every few minutes for token and message churn
/// (WidgetKit budgets reloads).
@MainActor
final class WidgetPublisher {
    static let shared = WidgetPublisher()

    private var last: WidgetSnapshot?
    private var lastReload = Date.distantPast
    private var reloadPending = false
    private var debounce: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var hasWidgets = false
    private var started = false

    private static let debounceDelay: Duration = .seconds(2)
    private static let heartbeatInterval: Duration = .seconds(5 * 60)
    private static let minReloadInterval: TimeInterval = 5 * 60

    func start() {
        guard !started else { return }
        started = true
        publish()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                await self?.beat()
                try? await Task.sleep(for: Self.heartbeatInterval)
            }
        }
    }

    /// Marks Shell as not running so widgets stop showing its sessions.
    func stop() {
        guard started else { return }
        started = false
        debounce?.cancel()
        heartbeat?.cancel()
        let snapshot = WidgetSnapshot(generatedAt: Date(), appRunning: false, agents: [],
                                      fiveHour: last?.fiveHour, sevenDay: last?.sevenDay, limitsUpdatedAt: last?.limitsUpdatedAt,
                                      tokensToday: last?.tokensToday, tokensLastFiveHours: last?.tokensLastFiveHours,
                                      sessionsToday: last?.sessionsToday, days: last?.days ?? [], models: last?.models ?? [])
        try? snapshot.save()
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.widgetKind)
    }

    // MARK: Publishing

    /// Every few minutes: rescan token usage (only while a widget is placed)
    /// and refresh the snapshot's timestamp so widgets know Shell is alive.
    private func beat() async {
        let configurations = (try? await WidgetCenter.shared.currentConfigurations()) ?? []
        hasWidgets = configurations.contains { $0.kind == WidgetSnapshot.widgetKind }
        if hasWidgets { ClaudeUsage.shared.refreshIfNeeded() }
        publish()
        if reloadPending, Date().timeIntervalSince(lastReload) >= Self.minReloadInterval { reload() }
    }

    private func publish() {
        guard started else { return }
        let snapshot = withObservationTracking {
            Self.makeSnapshot()
        } onChange: {
            Task { @MainActor in WidgetPublisher.shared.scheduleUpdate() }
        }
        let previous = last
        last = snapshot
        do {
            try snapshot.save()
        } catch {
            NSLog("Shell: couldn't write widget snapshot: \(error)")
            return
        }
        guard let previous else { return reload() }
        if snapshot.statusSignature() != previous.statusSignature() {
            reload()
        } else if Self.content(snapshot) != Self.content(previous) {
            if Date().timeIntervalSince(lastReload) >= Self.minReloadInterval { reload() } else { reloadPending = true }
        }
    }

    private func scheduleUpdate() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceDelay)
            guard !Task.isCancelled else { return }
            self?.publish()
        }
    }

    private func reload() {
        reloadPending = false
        lastReload = Date()
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.widgetKind)
    }

    /// The snapshot without its timestamp, for change detection.
    private static func content(_ s: WidgetSnapshot) -> WidgetSnapshot {
        var s = s
        s.generatedAt = .distantPast
        return s
    }

    // MARK: Building

    static func makeSnapshot(now: Date = Date()) -> WidgetSnapshot {
        let entries = ClaudeDashboard.entries { $0.isClaude || $0.agent != nil }
        let agents = entries.map { entry in
            let session = entry.session
            let activity = ClaudeDashboard.activity(for: session)
            return WidgetSnapshot.Agent(
                id: session.id,
                kind: session.agent?.kind.displayName ?? AgentKind.claude.displayName,
                title: ClaudeDashboard.title(for: entry),
                directory: ClaudeDashboard.directory(for: session),
                branch: ClaudeDashboard.branch(for: session),
                activity: activity.widgetActivity,
                message: activity.message,
                location: entry.location)
        }
        var snapshot = WidgetSnapshot(generatedAt: now, appRunning: true, agents: WidgetSnapshot.sorted(agents))
        let usage = ClaudeUsage.shared
        if let limits = usage.limits {
            snapshot.fiveHour = limits.fiveHour.map { WidgetSnapshot.Limit(utilization: $0.utilization, resetsAt: $0.resetsAt) }
            snapshot.sevenDay = limits.sevenDay.map { WidgetSnapshot.Limit(utilization: $0.utilization, resetsAt: $0.resetsAt) }
            snapshot.limitsUpdatedAt = limits.updatedAt
        }
        if let tokens = usage.tokens {
            snapshot.tokensToday = tokens.today.total
            snapshot.tokensLastFiveHours = tokens.lastFiveHours.total
            snapshot.sessionsToday = tokens.sessionsToday
            snapshot.days = tokens.days.map { WidgetSnapshot.Day(day: $0.day, tokens: $0.tokens) }
            snapshot.models = tokens.modelsToday.prefix(3).map { WidgetSnapshot.Model(name: ClaudeModelName.format($0.0), tokens: $0.1) }
        }
        return snapshot
    }
}

extension ClaudeDashboard.Activity {
    var widgetActivity: WidgetSnapshot.Activity {
        switch self {
        case .needsInput: .needsInput
        case .working: .working
        case .starting: .starting
        case .finished: .finished
        case .idle: .idle
        case .exited: .exited
        }
    }
}
