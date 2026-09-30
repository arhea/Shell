import SwiftUI
import WidgetKit

@main
struct ShellWidgets: WidgetBundle {
    var body: some Widget {
        AgentsWidget()
    }
}

/// Running agents plus Claude plan limits and token usage.
struct AgentsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.widgetKind, provider: AgentsProvider()) { entry in
            AgentsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Agents")
        .description("Claude Code and Codex sessions running in Shell, with your Claude plan limits and token usage.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct AgentsEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot
}

/// Shell writes the snapshot and asks for reloads when it changes; the
/// timeline itself is one entry plus a fallback refresh.
struct AgentsProvider: TimelineProvider {
    private static let refresh: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> AgentsEntry {
        AgentsEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (AgentsEntry) -> Void) {
        let snapshot = context.isPreview ? (WidgetSnapshot.load().flatMap { $0.agents.isEmpty ? nil : $0 } ?? .preview)
            : WidgetSnapshot.load() ?? .empty
        completion(AgentsEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AgentsEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshot.load() ?? .empty
        var entries = [AgentsEntry(date: now, snapshot: snapshot)]
        // Re-render when the snapshot goes stale, so a crashed Shell doesn't
        // leave its sessions on screen.
        if snapshot.isLive(at: now) {
            let staleAt = snapshot.generatedAt.addingTimeInterval(WidgetSnapshot.staleAfter)
            if staleAt < now.addingTimeInterval(Self.refresh) { entries.append(AgentsEntry(date: staleAt, snapshot: snapshot)) }
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(Self.refresh))))
    }
}

extension WidgetSnapshot {
    /// Sample data for the widget gallery.
    static var preview: WidgetSnapshot {
        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return WidgetSnapshot(
            generatedAt: now, appRunning: true,
            agents: [
                Agent(id: UUID(), kind: "Claude", title: "shell", directory: "~/code/shell", branch: "feat/widgets",
                      activity: .needsInput, message: "Allow Bash?", location: "Tab 1"),
                Agent(id: UUID(), kind: "Claude", title: "api", directory: "~/code/api", branch: "main",
                      activity: .working, message: nil, location: "Tab 2"),
                Agent(id: UUID(), kind: "Codex", title: "web", directory: "~/code/web", branch: "fix/login",
                      activity: .finished, message: "Tests pass", location: "Tab 3"),
            ],
            fiveHour: Limit(utilization: 0.42, resetsAt: now.addingTimeInterval(2 * 3600)),
            sevenDay: Limit(utilization: 0.68, resetsAt: now.addingTimeInterval(3 * 86400)),
            limitsUpdatedAt: now,
            tokensToday: 18_400_000, tokensLastFiveHours: 6_200_000, sessionsToday: 7,
            days: (0..<7).reversed().map { offset in
                Day(day: calendar.date(byAdding: .day, value: -offset, to: today)!, tokens: [9, 14, 6, 21, 12, 17, 18][6 - offset] * 1_000_000)
            },
            models: [Model(name: "Opus 5.5", tokens: 15_000_000), Model(name: "Haiku 4.5", tokens: 3_400_000)])
    }
}
