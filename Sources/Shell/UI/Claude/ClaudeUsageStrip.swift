import SwiftUI

/// The page's usage strip: one rounded card split into cells for the 5-hour
/// and weekly plan limits, today's tokens and a 7-day sparkline. Cells whose
/// data isn't available yet are left out.
struct ClaudeUsageTile: View {
    let palette: ChromePalette
    /// App-wide model (observed through property access; not state this view owns).
    var usage: ClaudeUsage = .shared
    /// Rescans transcripts while the strip is on screen. Off in unit tests, so
    /// rendering it never reads the user's ~/.claude/projects.
    static let refreshesUsage = !AppEnvironment.isRunningTests

    var body: some View {
        let limits = usage.limits
        let five = limits?.fiveHour
        let week = limits?.sevenDay
        let stats = usage.tokens
        Group {
            if five != nil || week != nil || stats != nil {
                HStack(spacing: 0) {
                    if let five { cell { limitCell("5-hour limit", five, weekly: false) } }
                    if let week {
                        if five != nil { divider }
                        cell { limitCell("Weekly limit", week, weekly: true) }
                    }
                    if stats != nil || usage.isScanning {
                        if five != nil || week != nil { divider }
                        ClaudeUsageTokens(stats: stats, palette: palette, limitsUpdatedAt: limits?.updatedAt)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .dashboardCard()
            } else if usage.isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Reading token usage from ~/.claude/projects…")
                }
                .font(.system(size: DS.Size.small))
                .foregroundStyle(.secondary)
            }
        }
        .task {
            while !Task.isCancelled {
                if Self.refreshesUsage { usage.refreshIfNeeded() }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private var divider: some View { Color.primary.opacity(0.08).frame(width: 0.5) }

    private func cell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func limitCell(_ label: String, _ window: ClaudeUsage.LimitWindow, weekly: Bool) -> some View {
        let color: Color = switch window.level {
        case .critical: DS.Status.failed
        case .warning: DS.Status.needsYou
        case .normal: DS.Status.done
        }
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text("\(window.percent)%").font(.system(size: DS.Size.title, weight: .semibold).monospacedDigit())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5).fill(Color.primary.opacity(0.09))
                    RoundedRectangle(cornerRadius: 2.5).fill(color).frame(width: max(5, geo.size.width * Double(window.percent) / 100))
                }
            }
            .frame(height: 5)
            if let reset = window.resetsAt {
                Text("Resets \(Self.resetText(reset, weekly: weekly))")
                    .font(.system(size: DS.Size.subtitle))
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .help("\(label): \(window.percent)% of your plan’s limit used")
    }

    // MARK: Formatting

    static func compact(_ n: Int) -> String {
        let v = Double(n)
        switch v {
        case 1_000_000_000...: return String(format: "%.1fB", v / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", v / 1_000_000)
        case 1_000...: return String(format: "%.1fK", v / 1_000)
        default: return "\(n)"
        }
    }

    /// "claude-opus-5-5" → "Opus 5.5".
    static func modelName(_ id: String) -> String { ClaudeModelName.format(id) }

    static func weekday(_ date: Date) -> String {
        String(date.formatted(.dateTime.weekday(.narrow)))
    }

    /// "4:40 PM" today (or for the 5-hour window), "Mon 10:00 PM" otherwise.
    static func resetText(_ date: Date, weekly: Bool) -> String {
        if weekly && !Calendar.current.isDateInToday(date) {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.hour().minute())
    }

    static func relative(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        return date.formatted(.relative(presentation: .named))
    }
}

/// The strip's token cells: today's total with its sessions and cache share,
/// and the last seven days as a bar sparkline (today in Claude orange).
struct ClaudeUsageTokens: View {
    let stats: ClaudeUsage.TokenStats?
    let palette: ChromePalette
    /// When plan limits were last reported, shown under the sparkline.
    var limitsUpdatedAt: Date?

    @ViewBuilder var body: some View {
        // Two cells, laid out by the strip's HStack (a multi-view body, so
        // each cell gets its own share of the width).
        if let stats {
            today(stats)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Color.primary.opacity(0.08).frame(width: 0.5)
            // As wide as its bars, like the design's auto-sized last column.
            week(stats)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxHeight: .infinity, alignment: .topLeading)
        } else {
            Text("Reading token usage from ~/.claude/projects…")
                .font(.system(size: DS.Size.small))
                .foregroundStyle(.secondary)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func today(_ stats: ClaudeUsage.TokenStats) -> some View {
        var detail = "\(stats.sessionsToday) session\(stats.sessionsToday == 1 ? "" : "s")"
        if let share = stats.today.cacheShare { detail += " · \(Int((share * 100).rounded()))% cache" }
        let t = stats.today
        var help = "\(t.total.formatted()) tokens today: in \(ClaudeUsageTile.compact(t.input)), out \(ClaudeUsageTile.compact(t.output)), "
            + "cache \(ClaudeUsageTile.compact(t.cacheWrite + t.cacheRead))"
        if let (model, count) = stats.modelsToday.first, t.total > 0 {
            help += "\nMostly \(ClaudeUsageTile.modelName(model)) (\(Int((Double(count) / Double(t.total) * 100).rounded()))%)"
        }
        help += "\nLast 5 hours: \(ClaudeUsageTile.compact(stats.lastFiveHours.total))"
        return VStack(alignment: .leading, spacing: 4) {
            Text("Tokens today").font(.system(size: 12)).foregroundStyle(.secondary)
            Text(ClaudeUsageTile.compact(t.total)).font(.system(size: 20, weight: .semibold).monospacedDigit()).tracking(-0.2)
            Text(detail).font(.system(size: DS.Size.subtitle)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .help(help)
    }

    private func week(_ stats: ClaudeUsage.TokenStats) -> some View {
        let bars = ClaudeUsage.sparkline(stats.days)
        let height: CGFloat = 32
        return VStack(alignment: .leading, spacing: 6) {
            Text("Last 7 days").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(bars) { bar in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(DS.claude.opacity(bar.isToday ? 1 : 0.45))
                        .frame(width: 10, height: bar.tokens == 0 ? 1 : max(3, height * bar.fraction))
                        .frame(height: height, alignment: .bottom)
                        .help("\(bar.day.formatted(.dateTime.weekday(.abbreviated).month().day())): \(bar.tokens.formatted()) tokens")
                }
            }
            .accessibilityHidden(true)
            if let limitsUpdatedAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("Updated \(ClaudeUsageTile.relative(limitsUpdatedAt, now: context.date))")
                        .font(.system(size: DS.Size.small))
                        .foregroundStyle(.tertiary)
                        .help("Plan limits as last reported by a Claude session in the native view")
                }
            }
        }
    }
}
