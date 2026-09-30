import SwiftUI
import WidgetKit

struct AgentsWidgetView: View {
    let entry: AgentsEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: WidgetSnapshot { entry.snapshot }
    private var live: Bool { snapshot.isLive(at: entry.date) }
    private var agents: [WidgetSnapshot.Agent] { live ? snapshot.agents : [] }

    var body: some View {
        Group {
            switch family {
            case .systemSmall: small
            case .systemLarge: large
            default: medium
            }
        }
        .widgetURL(ShellAppURL.dashboard.url)
    }

    // MARK: Sizes

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Spacer(minLength: 0)
            headline
            Spacer(minLength: 0)
            if let limit = WidgetSnapshot.current(snapshot.fiveHour, at: entry.date) {
                LimitMeter(label: "Session", limit: limit, compact: true)
            } else if let tokens = snapshot.tokensToday {
                Text("\(WidgetSnapshot.compact(tokens)) tokens today").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                header
                agentList(limit: 3)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                limits
                Spacer(minLength: 0)
                if let tokens = snapshot.tokensToday {
                    stat("Today", tokens)
                }
            }
            .frame(width: 118, alignment: .leading)
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            agentList(limit: 5)
            Spacer(minLength: 0)
            Divider()
            limits
            if let tokens = snapshot.tokensToday {
                HStack(alignment: .bottom, spacing: 14) {
                    stat("Today", tokens, detail: snapshot.sessionsToday.map { "\($0) session\($0 == 1 ? "" : "s")" })
                    if let five = snapshot.tokensLastFiveHours { stat("Last 5 hours", five, detail: topModel) }
                    Spacer(minLength: 0)
                    DailyBars(days: snapshot.days)
                }
            }
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 5) {
            ClaudeLogoShape().fill(Brand.claude).frame(width: 12, height: 12).widgetAccentable()
            Text("Agents").font(.caption.weight(.semibold))
            Spacer(minLength: 0)
            if live, family != .systemSmall, !agents.isEmpty {
                Text(summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// Small widget: the one number that matters most.
    @ViewBuilder private var headline: some View {
        if !live {
            notRunning
        } else if agents.isEmpty {
            Text("No agents running").font(.callout).foregroundStyle(.secondary)
        } else {
            let waiting = snapshot.count(.needsInput)
            let working = snapshot.count(.working) + snapshot.count(.starting)
            let (value, label, color): (Int, String, Color) =
                waiting > 0 ? (waiting, waiting == 1 ? "needs input" : "need input", Status.color(.needsInput))
                : working > 0 ? (working, "working", Status.color(.working))
                : (agents.count, agents.count == 1 ? "agent" : "agents", .secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(value)").font(.system(size: 34, weight: .semibold, design: .rounded)).foregroundStyle(color).monospacedDigit()
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func agentList(limit: Int) -> some View {
        if !live {
            notRunning
        } else if agents.isEmpty {
            Text("No agents running").font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: family == .systemLarge ? 8 : 5) {
                ForEach(agents.prefix(limit)) { agent in
                    Link(destination: ShellAppURL.session(agent.id).url) { AgentRow(agent: agent, detailed: family == .systemLarge) }
                }
                if agents.count > limit {
                    Text("+\(agents.count - limit) more").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var notRunning: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Shell isn't running").font(.caption.weight(.medium))
            Text("Open Shell to see your agents.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var limits: some View {
        let five = WidgetSnapshot.current(snapshot.fiveHour, at: entry.date)
        let seven = WidgetSnapshot.current(snapshot.sevenDay, at: entry.date)
        if five != nil || seven != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let five { LimitMeter(label: "Session", limit: five, compact: family != .systemLarge) }
                if let seven { LimitMeter(label: "Weekly", limit: seven, compact: family != .systemLarge) }
            }
        } else if family == .systemLarge {
            Text("Plan limits appear once a native Claude session reports them.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func stat(_ label: String, _ value: Int, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(WidgetSnapshot.compact(value)).font(.title3.weight(.semibold)).monospacedDigit()
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
    }

    private var summary: String {
        var parts: [String] = []
        let waiting = snapshot.count(.needsInput)
        let working = snapshot.count(.working) + snapshot.count(.starting)
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if working > 0 { parts.append("\(working) working") }
        if parts.isEmpty { parts.append("\(agents.count) running") }
        return parts.joined(separator: " · ")
    }

    private var topModel: String? {
        guard let model = snapshot.models.first, let today = snapshot.tokensToday, today > 0 else { return nil }
        return "\(model.name) \(Int((Double(model.tokens) / Double(today) * 100).rounded()))%"
    }
}

// MARK: - Components

enum Brand {
    /// Matches `ClaudeLogo.color` in the app.
    static let claude = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
}

enum Status {
    static func color(_ activity: WidgetSnapshot.Activity) -> Color {
        switch activity {
        case .needsInput: .orange
        case .working: Brand.claude
        case .finished: .green
        case .exited: .red
        case .starting, .idle: .secondary
        }
    }
}

struct AgentRow: View {
    let agent: WidgetSnapshot.Agent
    var detailed = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(Status.color(agent.activity)).frame(width: 7, height: 7).widgetAccentable()
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(agent.title).font(.caption.weight(.semibold)).lineLimit(1)
                    if agent.kind != "Claude" { Text(agent.kind).font(.caption2).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    if detailed { Text(agent.activity.title).font(.caption2).foregroundStyle(Status.color(agent.activity)) }
                }
                Text(secondLine).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    /// The message when it wants something, otherwise where it's working.
    private var secondLine: String {
        if agent.activity == .needsInput, let message = agent.message { return message }
        if detailed, let message = agent.message, agent.activity == .finished { return message }
        return agent.branch.map { "\(agent.directory) · \($0)" } ?? agent.directory
    }
}

struct LimitMeter: View {
    let label: String
    let limit: WidgetSnapshot.Limit
    var compact = false

    var body: some View {
        let fraction = min(max(limit.utilization, 0), 1)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(Int((fraction * 100).rounded()))%").fontWeight(.semibold).monospacedDigit()
            }
            .font(.caption2)
            ProgressView(value: fraction).progressViewStyle(.linear).tint(Self.color(fraction)).controlSize(.mini)
            if !compact, let reset = limit.resetsAt {
                Text("Resets \(reset, style: .relative)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    static func color(_ fraction: Double) -> Color {
        fraction >= 0.9 ? .red : fraction >= 0.7 ? .orange : .green
    }
}

struct DailyBars: View {
    let days: [WidgetSnapshot.Day]

    var body: some View {
        let peak = max(days.map(\.tokens).max() ?? 0, 1)
        let height: CGFloat = 34
        VStack(alignment: .trailing, spacing: 2) {
            Text("7 days").font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(days) { day in
                    UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                        .fill(Brand.claude.opacity(Calendar.current.isDateInToday(day.day) ? 1 : 0.5))
                        .frame(width: 8, height: day.tokens == 0 ? 1 : max(3, height * CGFloat(day.tokens) / CGFloat(peak)))
                        .widgetAccentable()
                }
            }
            .frame(height: height, alignment: .bottom)
        }
    }
}

#Preview(as: .systemMedium) {
    AgentsWidget()
} timeline: {
    AgentsEntry(date: .now, snapshot: .preview)
}

#Preview(as: .systemLarge) {
    AgentsWidget()
} timeline: {
    AgentsEntry(date: .now, snapshot: .preview)
}
