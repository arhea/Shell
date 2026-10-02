import AppKit
import SwiftUI

/// The default "Fix with Claude": saves each failing job's log to a file and
/// asks Claude to fix it — in the pane's prompt for a Claude pane, else in a
/// new tab running `claude` in the pane's folder.
@MainActor
enum ChecksFix {
    /// "Fix the failing CI check Test / Build and test on PR #39. …"
    static func prompt(for jobs: [CheckJob], logPaths: [String], prNumber: Int?) -> String {
        let names = jobs.map(ChecksText.title)
        let what = names.count == 1 ? "the failing CI check \(names[0])" : "the failing CI checks " + names.joined(separator: ", ")
        var text = "Fix \(what)" + (prNumber.map { " on PR #\($0)" } ?? "") + "."
        if !logPaths.isEmpty {
            text += logPaths.count == 1 ? " The failing log is in \(logPaths[0])." : " The failing logs are in " + logPaths.joined(separator: ", ") + "."
        }
        return text + " Find the cause, fix it, and run the relevant tests locally."
    }

    /// Where a job's log is saved.
    static func logURL(for job: CheckJob) -> URL {
        let safe = job.id.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return FileManager.default.temporaryDirectory.appendingPathComponent("shell-checks", isDirectory: true)
            .appendingPathComponent(String(safe) + ".log")
    }

    static func start(_ jobs: [CheckJob], model: BranchChecksModel, context: SidebarContext) {
        Task {
            var paths: [String] = []
            for job in jobs {
                let log = await model.failedLog(for: job)
                guard !log.isEmpty else { continue }
                let url = logURL(for: job)
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try log.write(to: url, atomically: true, encoding: .utf8)
                    paths.append(url.path)
                } catch {
                    Log.git.error("Couldn't save the log for \(job.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            let text = prompt(for: jobs, logPaths: paths, prNumber: model.snapshot?.prNumber)
            if context.isClaude, let insert = context.insert {
                insert(text)
            } else if let openTab = context.openTab {
                openTab(context.directory, "claude " + ShellQuote.quote(text))
            }
        }
    }
}

/// ✓ / ✕ / spinner / – for a CI job or step, in the status colors.
struct CheckStateMark: View {
    let state: CheckJob.State
    var size: CGFloat = 12

    var body: some View {
        Group {
            switch state {
            case .passed:
                Image(systemName: "checkmark").font(.system(size: size * 0.85, weight: .bold)).foregroundStyle(DS.Status.done)
                    .accessibilityLabel("Passed")
            case .failed:
                Image(systemName: "xmark").font(.system(size: size * 0.85, weight: .bold)).foregroundStyle(DS.Status.failed)
                    .accessibilityLabel("Failed")
            case .running:
                SpinnerRing(size: size * 0.9)
            case .queued:
                Circle().strokeBorder(Color.secondary, lineWidth: 1.2).frame(width: size * 0.85, height: size * 0.85)
                    .accessibilityLabel("Queued")
            case .skipped, .cancelled:
                Text("–").font(.system(size: size, weight: .semibold)).foregroundStyle(.secondary)
                    .accessibilityLabel(state == .skipped ? "Skipped" : "Cancelled")
            }
        }
        .frame(width: size + 2, height: size + 2)
    }
}

/// Shared wording for check states and the empty states of both views.
@MainActor
enum ChecksText {
    /// "Test / Build and test": the workflow's name (without its " · file.yml")
    /// and the job's, or just the job's when the workflow is unknown or already in it.
    static func title(_ job: CheckJob) -> String {
        guard let workflow = job.workflow?.components(separatedBy: " · ").first?.trimmingCharacters(in: .whitespaces),
              !workflow.isEmpty, workflow != job.name, !job.name.hasPrefix(workflow + " / ") else { return job.name }
        return "\(workflow) / \(job.name)"
    }

    /// "test.yml" from "Test · test.yml", shown under a job's title.
    static func workflowFile(_ job: CheckJob) -> String? {
        guard let parts = job.workflow?.components(separatedBy: " · "), parts.count > 1 else { return nil }
        let file = parts.dropFirst().joined(separator: " · ").trimmingCharacters(in: .whitespaces)
        return file.isEmpty ? nil : file
    }

    static func duration(_ job: CheckJob) -> String? {
        switch job.state {
        case .skipped: "skipped"
        case .cancelled: "cancelled"
        case .queued: "queued"
        default: job.duration.map(InspectorFormat.duration)
        }
    }

    static func duration(_ step: CheckJob.Step) -> String? {
        step.state == .skipped ? "skipped" : step.duration.map(InspectorFormat.duration)
    }

    /// Why there's nothing to list, or nil when there are jobs.
    static func emptyState(_ model: BranchChecksModel) -> (title: String, detail: String?)? {
        if let snap = model.snapshot {
            if snap.prNumber == nil {
                return ("No pull request for this branch", "Checks show here once \(snap.branch) has a pull request.")
            }
            return snap.jobs.isEmpty ? ("No checks reported", "GitHub hasn't reported any checks for this pull request yet.") : nil
        }
        if let error = model.error { return ("Checks unavailable", error) }
        if model.isLoading { return ("Loading checks…", nil) }
        return ("No checks yet", "Shell asks gh for this branch's checks when it has a pull request.")
    }

    /// "PR #39 · 74c838f · 6 min ago".
    static func subtitle(_ snap: BranchChecksSnapshot, now: Date) -> String {
        var parts: [String] = []
        if let n = snap.prNumber { parts.append("PR #\(n)") }
        if let sha = snap.headSHA { parts.append(String(sha.prefix(7))) }
        parts.append(InspectorFormat.ago(snap.updatedAt, now: now))
        return parts.joined(separator: " · ")
    }
}

/// The inspector's Checks tab: the jobs on this branch's PR, failures first
/// and expanded, with Fix with Claude, Re-run and the job log.
struct InspectorChecksView: View {
    let model: BranchChecksModel
    /// Jobs Claude is already fixing; their Fix button shows "Claude is fixing".
    var fixing: Set<String> = []
    /// Show the "Send failures to Claude" toggle (Claude panes).
    var showsAutoFix = true
    /// Shown below the jobs (the all-runs list, links).
    var extra: AnyView?
    var onFix: (CheckJob) -> Void

    init(model: BranchChecksModel, fixing: Set<String> = [], showsAutoFix: Bool = true, extra: AnyView? = nil,
         onFix: @escaping (CheckJob) -> Void) {
        self.model = model
        self.fixing = fixing
        self.showsAutoFix = showsAutoFix
        self.extra = extra
        self.onFix = onFix
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if let empty = ChecksText.emptyState(model) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                if model.isLoading && model.snapshot == nil { ProgressView().controlSize(.mini) }
                                Text(empty.title).font(.system(size: DS.Size.body, weight: .medium))
                            }
                            if let detail = empty.detail {
                                Text(detail).font(.system(size: DS.Size.small)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } else if let snap = model.snapshot {
                        chips(snap)
                        ForEach(snap.failing) { job in failingCard(job) }
                        let rest = snap.jobs.filter { $0.state != .failed }
                        if !rest.isEmpty { otherJobs(rest) }
                    }
                    if let extra { extra }
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 14)
            }
            VStack(alignment: .leading, spacing: 8) {
                if showsAutoFix { autoFixCard }
                Text("Refreshes every 10s while a run is active · via gh")
                    .font(.system(size: DS.Size.small)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 2)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .padding(.top, 4)
        }
        .onAppear { model.refresh() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Checks on this branch").font(.system(size: DS.Size.title, weight: .semibold))
                if let snap = model.snapshot {
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in
                        Text(ChecksText.subtitle(snap, now: ctx.date)).font(.system(size: DS.Size.subtitle)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 2)
            Spacer(minLength: 4)
            if model.isLoading && model.snapshot != nil { ProgressView().controlSize(.mini) }
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.labeled(.plain, compact: true))
                .help("Refresh checks")
                .accessibilityLabel("Refresh checks")
        }
    }

    private func chips(_ snap: BranchChecksSnapshot) -> some View {
        HStack(spacing: 4) {
            if !snap.failing.isEmpty { CheckCountChip(text: "\(snap.failing.count) failing", color: DS.Status.failed) }
            if !snap.running.isEmpty { CheckCountChip(text: "\(snap.running.count) running", color: DS.Status.working) }
            if !snap.passed.isEmpty { CheckCountChip(text: "\(snap.passed.count) passed", color: DS.Status.done) }
            if !snap.skipped.isEmpty { CheckCountChip(text: "\(snap.skipped.count) skipped", color: nil) }
        }
    }

    private func failingCard(_ job: CheckJob) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                CheckStateMark(state: .failed).padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ChecksText.title(job)).font(.system(size: DS.Size.body, weight: .semibold)).lineLimit(2)
                    if let file = ChecksText.workflowFile(job) {
                        Text(file).font(.system(size: DS.Size.small)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let d = ChecksText.duration(job) {
                    Text(d).font(.system(size: DS.Size.subtitle)).monospacedDigit().foregroundStyle(.tertiary).padding(.top, 1)
                }
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 8)
            if !job.steps.isEmpty {
                VStack(spacing: 4) {
                    ForEach(job.steps, id: \.self) { step in
                        let color: Color = step.state == .failed ? DS.Status.failed : .secondary
                        HStack(spacing: 8) {
                            CheckStateMark(state: step.state, size: 10)
                            Text(step.name).font(.system(size: 12)).lineLimit(1)
                            Spacer(minLength: 4)
                            if let d = ChecksText.duration(step) {
                                Text(d).font(.system(size: DS.Size.subtitle)).monospacedDigit()
                            }
                        }
                        .foregroundStyle(step.state == .skipped ? AnyShapeStyle(.tertiary) : AnyShapeStyle(color))
                    }
                }
                .padding(.leading, 30).padding(.trailing, 10).padding(.top, 2).padding(.bottom, 10)
            } else if let detail = job.detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                    .padding(.leading, 30).padding(.trailing, 10).padding(.bottom, 10)
            }
            Color.primary.opacity(0.07).frame(height: 0.5)
            HStack(spacing: 6) {
                if fixing.contains(job.id) {
                    HStack(spacing: 5) {
                        SpinnerRing(color: DS.claude, size: 9)
                        Text("Claude is fixing")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(DS.claude)
                    .frame(maxWidth: .infinity, minHeight: 26)
                    .background(DS.claude.opacity(0.18), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityElement(children: .combine)
                } else {
                    Button { onFix(job) } label: {
                        HStack(spacing: 5) { ClaudeMark(size: 10, color: .white); Text("Fix with Claude") }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .background(DS.Status.selection, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Start Claude on this failure with the job's log attached")
                }
                Button("Re-run") { Task { await model.rerun(job) } }
                    .buttonStyle(CheckCardButtonStyle())
                if let url = job.url {
                    Button("Log ↗") { NSWorkspace.shared.open(url) }
                        .buttonStyle(CheckCardButtonStyle())
                        .help("Open the job's log on GitHub")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Status.failed.opacity(0.35), lineWidth: 1))
    }

    private func otherJobs(_ jobs: [CheckJob]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(jobs.enumerated()), id: \.element.id) { i, job in
                if i > 0 { Color.primary.opacity(0.06).frame(height: 0.5) }
                CheckJobRow(job: job)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    private var autoFixCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Send failures to Claude").font(.system(size: DS.Size.body, weight: .semibold))
                Spacer(minLength: 4)
                Toggle("Send failures to Claude", isOn: Binding(get: { model.sendFailuresToClaude }, set: { model.sendFailuresToClaude = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            Text("When a check fails on this branch, Claude gets the log and starts a fix. Auto mode still asks before pushing.")
                .font(.system(size: DS.Size.subtitle)).foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

/// "1 failing", "3 passed": a count of jobs in a state, as a tinted capsule.
struct CheckCountChip: View {
    let text: String
    /// Nil is the neutral chip (skipped).
    let color: Color?

    var body: some View {
        Text(text)
            .font(.system(size: DS.Size.subtitle))
            .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(Color.primary.opacity(0.8)))
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(color.map { $0.opacity(0.14) } ?? Color.primary.opacity(0.06), in: Capsule())
            .fixedSize()
    }
}

/// The failing card's quiet "Re-run" and "Log ↗".
struct CheckCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .padding(.horizontal, 9)
            .frame(minHeight: 26)
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
    }
}

/// One job as a row: mark, name, duration. Clicking opens it on GitHub.
struct CheckJobRow: View {
    let job: CheckJob
    @State private var hovering = false

    var body: some View {
        let dim = job.state == .skipped || job.state == .cancelled
        Button { if let url = job.url { NSWorkspace.shared.open(url) } } label: {
            HStack(spacing: 8) {
                CheckStateMark(state: job.state, size: 11)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ChecksText.title(job)).font(.system(size: DS.Size.body)).lineLimit(1).truncationMode(.tail)
                    if job.state == .running, let detail = job.detail {
                        Text(detail).font(.system(size: DS.Size.caption)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let d = ChecksText.duration(job) {
                    Text(d).font(.system(size: DS.Size.subtitle)).monospacedDigit().foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(dim ? .secondary : .primary)
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(hovering ? Color.primary.opacity(0.05) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(job.url == nil ? ChecksText.title(job) : "Open \(ChecksText.title(job)) on GitHub")
    }
}

/// The compact checks popover for a terminal prompt's checks chip: each job
/// with a per-failure Fix, then Fix all with Claude, Re-run failed and
/// Open on GitHub.
struct ChecksPopoverView: View {
    let model: BranchChecksModel
    var onFix: (CheckJob) -> Void
    /// Called with every failing job.
    var onFixAll: ([CheckJob]) -> Void

    init(model: BranchChecksModel, onFix: @escaping (CheckJob) -> Void, onFixAll: @escaping ([CheckJob]) -> Void) {
        self.model = model
        self.onFix = onFix
        self.onFixAll = onFixAll
    }

    private var branch: String { model.snapshot?.branch ?? model.repository.status.branch ?? model.repository.branchLabel }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(12)
            Divider()
            if let empty = ChecksText.emptyState(model) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(empty.title).font(.system(size: DS.Size.body, weight: .medium))
                    if let d = empty.detail { Text(d).font(.system(size: DS.Size.small)).foregroundStyle(.secondary) }
                }
                .padding(12)
            } else if let snap = model.snapshot {
                ScrollView {
                    VStack(spacing: 0) { ForEach(sorted(snap.jobs)) { job in row(job) } }
                        .padding(.vertical, 4)
                }
                .frame(maxHeight: 360)
                Divider()
                footer(snap).padding(12)
            }
        }
        .frame(width: 456)
        .onAppear { model.refresh() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Checks for \(branch)").font(.system(size: DS.Size.title, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(subtitle(now: ctx.date)).font(.system(size: DS.Size.small)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Pill("GitHub Actions", color: .secondary)
        }
    }

    private func subtitle(now: Date) -> String {
        var parts: [String] = []
        if let slug = model.repository.github?.slug { parts.append(slug) }
        guard let snap = model.snapshot else { return parts.joined(separator: " · ") }
        if let n = snap.prNumber { parts.append("PR #\(n)") }
        if let sha = snap.headSHA { parts.append(String(sha.prefix(7))) }
        parts.append("updated \(InspectorFormat.ago(snap.updatedAt, now: now))")
        return parts.joined(separator: " · ")
    }

    /// Failing first, then running, then the rest, keeping GitHub's order within each.
    private func sorted(_ jobs: [CheckJob]) -> [CheckJob] {
        func rank(_ s: CheckJob.State) -> Int {
            switch s {
            case .failed: 0
            case .running, .queued: 1
            case .passed: 2
            case .skipped, .cancelled: 3
            }
        }
        return jobs.enumerated().sorted { (rank($0.element.state), $0.offset) < (rank($1.element.state), $1.offset) }.map(\.element)
    }

    private func row(_ job: CheckJob) -> some View {
        HStack(spacing: 10) {
            CheckStateMark(state: job.state, size: 11)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.name).font(.system(size: DS.Size.body, weight: .medium)).lineLimit(1)
                if let detail = job.detail {
                    Text(detail).font(.system(size: DS.Size.small)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 6)
            if let d = ChecksText.duration(job) {
                Text(d).font(.system(size: DS.Size.small)).monospacedDigit().foregroundStyle(.secondary)
            }
            if job.state == .failed {
                Button { onFix(job) } label: { HStack(spacing: 3) { ClaudeMark(size: 9); Text("Fix") } }
                    .buttonStyle(.labeled(.claude, compact: true))
                    .help("Start Claude on \(job.name) with its log attached")
            }
        }
        .foregroundStyle(job.state == .skipped || job.state == .cancelled ? .secondary : .primary)
        .padding(.horizontal, 12)
        .frame(minHeight: 46)
    }

    private func footer(_ snap: BranchChecksSnapshot) -> some View {
        let failing = snap.failing
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if !failing.isEmpty {
                    Button { onFixAll(failing) } label: {
                        HStack(spacing: 4) {
                            ClaudeMark(size: 10, color: .white)
                            Text(failing.count == 1 ? "Fix 1 failing with Claude" : "Fix \(failing.count) failing with Claude")
                        }
                    }
                    .buttonStyle(.labeled(.primary))
                    Button("Re-run failed") { Task { await model.rerunFailed() } }
                        .buttonStyle(.labeled(.neutral))
                }
                Spacer(minLength: 4)
                if let url = snap.prURL ?? model.repository.github?.url {
                    Button("Open on GitHub ↗") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.labeled(.plain))
                }
            }
            if !failing.isEmpty {
                Text(failing.count == 1 ? "Starts Claude in this folder with the job log attached"
                     : failing.count == 2 ? "Starts Claude in this folder with both job logs attached"
                     : "Starts Claude in this folder with all \(failing.count) job logs attached")
                    .font(.system(size: DS.Size.small)).foregroundStyle(.secondary)
            }
        }
    }
}
