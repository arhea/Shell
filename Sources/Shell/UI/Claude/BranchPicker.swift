import AppKit
import SwiftUI

/// A branch that can be checked out in a worktree.
struct BranchOption: Identifiable, Equatable {
    /// Local branch name (for a remote-only branch, the name without the remote).
    var name: String
    /// Set when the branch only exists on this remote.
    var remote: String?
    var date: Date?
    var subject: String
    /// Where it's already checked out, if anywhere.
    var worktreePath: String?
    var isDefault = false

    var id: String { (remote.map { $0 + "/" } ?? "") + name }

    /// Parses `git for-each-ref --format='%(refname)%09%(committerdate:unix)%09%(subject)' refs/heads refs/remotes`.
    /// Remote branches are listed only when there's no local branch of the same name.
    /// Newest first.
    static func parse(refs output: String, worktrees: [WorktreeInfo], defaultBranch: String?) -> [BranchOption] {
        var local: [BranchOption] = []
        var remote: [BranchOption] = []
        let checkedOut = Dictionary(worktrees.compactMap { wt in wt.branch.map { ($0, wt.path) } }, uniquingKeysWith: { a, _ in a })
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2 else { continue }
            let ref = fields[0]
            let date = Double(fields[1]).map { Date(timeIntervalSince1970: $0) }
            let subject = fields.count > 2 ? fields[2] : ""
            if ref.hasPrefix("refs/heads/") {
                let name = String(ref.dropFirst(11))
                local.append(BranchOption(name: name, date: date, subject: subject, worktreePath: checkedOut[name], isDefault: name == defaultBranch))
            } else if ref.hasPrefix("refs/remotes/") {
                let rest = ref.dropFirst(13)
                guard let slash = rest.firstIndex(of: "/") else { continue }
                let name = String(rest[rest.index(after: slash)...])
                guard name != "HEAD" else { continue }
                remote.append(BranchOption(name: name, remote: String(rest[..<slash]), date: date, subject: subject, isDefault: name == defaultBranch))
            }
        }
        let localNames = Set(local.map(\.name))
        var seenRemote = Set<String>()
        let remoteOnly = remote.filter { !localNames.contains($0.name) && seenRemote.insert($0.name).inserted }
        return (local + remoteOnly).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
}

/// What the picker starts the agent on.
enum BranchChoice: Equatable, Identifiable {
    /// A new branch (off the default branch) with this name.
    case create(String)
    case existing(BranchOption)

    var id: String {
        switch self {
        case .create(let name): "+create:" + name
        case .existing(let b): b.id
        }
    }
}

@MainActor
@Observable
final class BranchPickerModel {
    var query = "" {
        didSet {
            selected = 0
            filter()
            scheduleSuggestions()
        }
    }
    var selected = 0
    /// Branch names Apple Intelligence suggested for the typed description.
    private(set) var suggestions: [String] = []
    private(set) var isSuggesting = false
    @ObservationIgnored private var suggestionTask: Task<Void, Never>?
    /// A "create branch" row (when the query is a new, valid name), then matching branches.
    private(set) var rows: [BranchChoice] = []
    private(set) var isLoading = true
    private(set) var isFetching = false
    private(set) var error: String?
    private(set) var info: AgentLauncher.RepoInfo?

    let directory: String
    let worktreeRoot: String
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private var all: [BranchOption] = []

    init(directory: String) {
        self.directory = directory
        var env = MCPManager.defaultEnvironment()
        env["GIT_TERMINAL_PROMPT"] = "0"
        environment = env
        worktreeRoot = WorktreeService.worktreeRoot(environment: env)
    }

    var current: BranchChoice? { rows.indices.contains(selected) ? rows[selected] : nil }

    /// The typed name when it would be a new branch; nil for empty, invalid or existing names.
    var newBranchName: String? {
        guard let name = AgentLauncher.branchName(from: query), !all.contains(where: { $0.name == name || $0.id == name }) else { return nil }
        return name
    }

    /// Typed text that can't be a branch name (shown as a hint).
    var invalidName: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty && AgentLauncher.branchName(from: query) == nil
    }

    /// Lists branches, then fetches (best-effort) and lists again so new remote
    /// branches show up without waiting for the network first.
    func load() async {
        do {
            let (info, _) = try await AgentLauncher.inspect(directory: directory, environment: environment)
            self.info = info
        } catch {
            self.error = error.localizedDescription
            isLoading = false
            return
        }
        await reload()
        isLoading = false
        isFetching = true
        let git = GitRepository.findGit(environment: environment)
        _ = await GitRepository.run(git, ["fetch", "--prune", "--quiet"], in: directory, environment: environment)
        isFetching = false
        await reload()
    }

    private func reload() async {
        let git = GitRepository.findGit(environment: environment)
        let refs = await GitRepository.run(git, ["for-each-ref", "--format=%(refname)%09%(committerdate:unix)%09%(subject)",
                                                 "refs/heads", "refs/remotes"], in: directory, environment: environment) ?? ""
        let worktrees = WorktreeInfo.parse(porcelain: await GitRepository.run(git, ["worktree", "list", "--porcelain"], in: directory,
                                                                              environment: environment) ?? "")
        let keep = current?.id
        all = BranchOption.parse(refs: refs, worktrees: worktrees, defaultBranch: info?.baseBranch)
        filter()
        if let keep, let idx = rows.firstIndex(where: { $0.id == keep }) { selected = idx }
    }

    private func filter() {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let matches: [BranchOption]
        if q.isEmpty {
            matches = Array(all.prefix(300))
        } else {
            matches = all.enumerated().compactMap { i, b -> (BranchOption, Int, Int)? in
                guard let score = FuzzyMatch.score(q, in: b.id.lowercased()) else { return nil }
                return (b, score, i)
            }
            .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
            .prefix(300)
            .map(\.0)
        }
        let typed = newBranchName
        let taken = Set(all.map(\.name))
        let suggested = suggestions.filter { $0 != typed && !taken.contains($0) }
        rows = (typed.map { [BranchChoice.create($0)] } ?? []) + suggested.map { .create($0) } + matches.map { .existing($0) }
    }

    /// Asks for branch names once the query reads like a description of the
    /// work ("fix login redirect on expired session"), after a short pause.
    private func scheduleSuggestions() {
        suggestionTask?.cancel()
        let description = query
        guard Intelligence.isEnabled(.branchNames), IntelligencePrompts.looksLikeRequest(description) else {
            isSuggesting = false
            if !suggestions.isEmpty {
                suggestions = []
                filter()
            }
            return
        }
        suggestionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled else { return }
            isSuggesting = true
            let recent = all.filter { $0.remote == nil }.map(\.name)
            let names = await Intelligence.branchNames(for: description, recentBranches: recent, existing: Set(all.map(\.name)))
            guard !Task.isCancelled, query == description else { return }
            isSuggesting = false
            // Keep the highlighted row where it is while suggestions arrive.
            let keep = current?.id
            suggestions = names
            filter()
            if let keep, let idx = rows.firstIndex(where: { $0.id == keep }) { selected = idx }
        }
    }

    func isSuggested(_ name: String) -> Bool { suggestions.contains(name) }

    /// Where the choice will be checked out, and whether that worktree already exists.
    func destination(for choice: BranchChoice) -> (path: String, exists: Bool)? {
        let name: String
        switch choice {
        case .create(let n): name = n
        case .existing(let b):
            if let path = b.worktreePath { return (path, true) }
            name = b.name
        }
        guard let info else { return nil }
        let path = AgentLauncher.worktreePath(root: worktreeRoot, repoName: info.repoName, branch: name) {
            FileManager.default.fileExists(atPath: $0)
        }
        return (path, false)
    }
}

/// Sheet for "Start Claude in Worktree…": type a new branch name or pick an existing branch.
@MainActor
enum BranchPicker {
    static func show(directory: String, agent: CodingAgent, in controller: TerminalWindowController, onPick: @escaping (BranchChoice) -> Void) {
        guard let window = controller.window else { return }
        let model = BranchPickerModel(directory: directory)
        var sheet: NSWindow?
        // The sheet owns this closure (through its view), so capture weakly and
        // drop the sheet afterwards; otherwise the sheet, its model and the
        // window controller all stay alive after the window closes.
        let close: () -> Void = { [weak window, weak controller] in
            guard let s = sheet else { return }
            window?.endSheet(s)
            controller?.focusSelected()
            // Released on the next turn: this closure is running from the sheet's own view.
            DispatchQueue.main.async { sheet = nil }
        }
        let view = BranchPickerView(model: model, agent: agent, onCancel: close) { choice in
            close()
            onPick(choice)
        }
        let s = NSWindow(contentViewController: NSHostingController(rootView: view))
        s.styleMask = [.titled]
        sheet = s
        window.beginSheet(s)
    }
}

struct BranchPickerView: View {
    @Bindable var model: BranchPickerModel
    let agent: CodingAgent
    let onCancel: () -> Void
    let onPick: (BranchChoice) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let items = model.rows
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Start \(agent.shortName) in a Worktree").font(.headline)
                Text("Type a name for a new branch off \(model.info.map { ($0.baseRemote.map { $0 + "/" } ?? "") + $0.baseBranch } ?? "the default branch"), or pick an existing branch. It's checked out in a new worktree, then \(agent.displayName) starts there.\(Intelligence.isEnabled(.branchNames) ? " Describe the work in a few words to get suggested names." : "")")
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("New branch name, or search branches", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { pick() }
                    .onKeyPress(.upArrow) { model.selected = max(0, model.selected - 1); return .handled }
                    .onKeyPress(.downArrow) { model.selected = min(max(items.count - 1, 0), model.selected + 1); return .handled }
                    .onKeyPress(.escape) { onCancel(); return .handled }
                if model.isSuggesting {
                    ProgressView().controlSize(.small)
                    Text("Suggesting names").font(.system(size: 11)).foregroundStyle(.secondary)
                } else if model.isFetching {
                    ProgressView().controlSize(.small)
                    Text("Fetching").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.3)))

            list(items)
                .frame(height: 300)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.2)))

            HStack(spacing: 8) {
                destination
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Start \(agent.shortName)") { pick() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.current == nil)
            }
        }
        .padding(18)
        .frame(width: 560)
        .onAppear {
            focused = true
            Intelligence.prewarm(for: .branchNames)
        }
        .task { await model.load() }
    }

    @ViewBuilder private func list(_ items: [BranchChoice]) -> some View {
        if let error = model.error {
            placeholder(error)
        } else if model.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            placeholder(model.invalidName ? "\"\(model.query)\" isn't a valid branch name" : model.query.isEmpty ? "No branches" : "No branches match \"\(model.query)\"")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, choice in
                            row(choice, selected: idx == model.selected)
                                .id(idx)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    model.selected = idx
                                    pick()
                                }
                                .simultaneousGesture(TapGesture().onEnded { model.selected = idx })
                        }
                    }
                    .padding(4)
                }
                .onChange(of: model.selected) { _, i in proxy.scrollTo(i) }
            }
        }
    }

    @ViewBuilder private func row(_ choice: BranchChoice, selected: Bool) -> some View {
        switch choice {
        case .create(let name): createRow(name, selected: selected)
        case .existing(let b): branchRow(b, selected: selected)
        }
    }

    private func createRow(_ name: String, selected: Bool) -> some View {
        let suggested = model.isSuggested(name)
        return HStack(spacing: 8) {
            Image(systemName: suggested ? "sparkles" : "plus.circle.fill").font(.system(size: 12)).foregroundStyle(Color.accentColor).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("Create branch \(name)").font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text("New branch off \(model.info.map { ($0.baseRemote.map { $0 + "/" } ?? "") + $0.baseBranch } ?? "the default branch")")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if suggested { badge("suggested") }
            badge("new")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.25) : .clear))
    }

    private func branchRow(_ b: BranchOption, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: b.remote != nil ? "icloud" : "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(b.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(detail(b)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if b.isDefault { badge("default") }
            if b.worktreePath != nil { badge("worktree") }
            if let remote = b.remote { badge(remote) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.25) : .clear))
    }

    private func detail(_ b: BranchOption) -> String {
        var parts: [String] = []
        if let date = b.date { parts.append(date.formatted(.relative(presentation: .named))) }
        if !b.subject.isEmpty { parts.append(b.subject) }
        return parts.joined(separator: " · ")
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().strokeBorder(Color.secondary.opacity(0.4)))
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var destination: some View {
        if let choice = model.current, let (path, exists) = model.destination(for: choice) {
            Label {
                Text((exists ? "Opens " : "→ ") + ClaudeToolFormat.shortPath(path))
                    .lineLimit(1).truncationMode(.head)
            } icon: {
                Image(systemName: exists ? "folder" : "folder.badge.plus")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .help(path)
        }
    }

    private func pick() {
        guard let choice = model.current else { return }
        onPick(choice)
    }
}
