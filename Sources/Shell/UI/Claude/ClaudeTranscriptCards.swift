import AppKit
import SwiftUI

// The transcript's tool and event cards: thinking rows, tool runs (one row
// per step), edit diffs, Bash output, CI failures and the end-of-turn
// summary. Status uses the shared vocabulary (orange spinner = working,
// green = done, red = failed); surfaces derive from the terminal theme.

// MARK: - Shared pieces

/// A path with its folder dimmed so the file name stands out, relative to
/// the session's directory when inside it.
enum ClaudePathText {
    static func split(_ path: String, directory: String?) -> (folder: String, name: String) {
        var shown = path
        if let directory, !directory.isEmpty {
            let base = directory.hasSuffix("/") ? directory : directory + "/"
            if path.hasPrefix(base) { shown = String(path.dropFirst(base.count)) }
        }
        if shown == path { shown = ClaudeToolFormat.shortPath(path) }
        guard let slash = shown.lastIndex(of: "/") else { return ("", shown) }
        return (String(shown[...slash]), String(shown[shown.index(after: slash)...]))
    }

    static func attributed(_ path: String, directory: String?, palette: ClaudePalette) -> AttributedString {
        let (folder, name) = split(path, directory: directory)
        var a = AttributedString(folder)
        a.foregroundColor = palette.dim
        var b = AttributedString(name)
        b.foregroundColor = palette.foreground
        return a + b
    }
}

/// ✓ / spinner / ✕ for a step.
struct StepStatusIcon: View {
    let item: ClaudeItem
    var size: CGFloat = 11

    var body: some View {
        if item.isRunning {
            SpinnerRing(size: size)
        } else if item.isError {
            Image(systemName: "xmark").font(.system(size: size, weight: .bold)).foregroundStyle(DS.Status.failed)
                .accessibilityLabel("Failed")
        } else {
            Image(systemName: "checkmark").font(.system(size: size, weight: .bold)).foregroundStyle(DS.Status.done)
                .accessibilityLabel("Done")
        }
    }
}

/// The small boxed tool name in card headers: "Edit", "Bash".
struct ToolChip: View {
    let name: String
    let palette: ClaudePalette

    var body: some View {
        Text(name)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(palette.foreground.opacity(0.85))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(palette.foreground.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }
}

/// "+4 −1" in diff colors.
struct DiffStatsText: View {
    let stats: ClaudeDiffStats
    let palette: ClaudePalette
    var size: CGFloat = 11.5

    var body: some View {
        HStack(spacing: 5) {
            if stats.added > 0 || stats.removed == 0 { Text("+\(stats.added)").foregroundStyle(palette.green) }
            if stats.removed > 0 { Text("−\(stats.removed)").foregroundStyle(palette.red) }
        }
        .font(ChatTypography.current.codeFont(size: size))
        .fixedSize()
    }
}

/// A bordered transcript card: body fill, hairline border, rounded. Tool
/// runs use the card fill; diffs and output sit on the sunken fill under a
/// card-colored header; events (a summary, a failure) are larger and tinted.
private struct TranscriptCard: ViewModifier {
    let palette: ClaudePalette
    var tint: Color?
    var fill: Color?
    var radius: CGFloat = DS.Radius.card

    func body(content: Content) -> some View {
        content
            .background {
                if let tint { palette.background.overlay(tint.opacity(0.1)) } else { fill ?? palette.surface }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .strokeBorder(tint.map { $0.opacity(0.35) } ?? palette.border.opacity(0.8), lineWidth: tint == nil ? 0.5 : 1))
    }
}

extension View {
    fileprivate func transcriptCard(_ palette: ClaudePalette, tint: Color? = nil, fill: Color? = nil,
                                    radius: CGFloat = DS.Radius.card) -> some View {
        modifier(TranscriptCard(palette: palette, tint: tint, fill: fill, radius: radius))
    }
}

/// A small text button for card headers and footers ("Copy", "Show all").
private struct CardTextButton: View {
    let title: String
    let palette: ClaudePalette
    var color: Color?
    var filled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(color ?? palette.foreground.opacity(0.85))
                .padding(.horizontal, 8)
                .frame(minHeight: 22)
                .background(filled ? palette.foreground.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

enum ClaudeClipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Opens terminal tabs for the transcript's "Open in terminal tab" and "Run in new tab".
@MainActor
enum ClaudeTerminalLauncher {
    static let shellLanguages: Set<String> = ["sh", "bash", "zsh", "shell"]

    static func isShell(_ language: String) -> Bool { shellLanguages.contains(language.lowercased()) }

    /// A tab in `directory`; `command` runs once its shell is ready.
    static func openTab(directory: String, command: String? = nil) {
        (NSApp.delegate as? AppDelegate)?.openTab(directory: directory, command: command)
    }

    /// The command that runs a snippet: one line as typed; several lines from
    /// a temporary script, so the prompt shows one readable command.
    static func command(for code: String, language: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("\n") { return trimmed }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ShellSnippets", isDirectory: true)
        let url = dir.appendingPathComponent("snippet-\(UUID().uuidString.prefix(8)).sh")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data((trimmed + "\n").utf8).write(to: url)
        } catch {
            Log.claude.error("couldn't write a snippet: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return (language.lowercased() == "zsh" ? "zsh " : "bash ") + ShellQuote.quote(url.path)
    }

    static func run(_ code: String, language: String, directory: String) {
        guard let command = command(for: code, language: language) else { return }
        openTab(directory: directory, command: command)
    }
}

// MARK: - Thinking

/// "▸ Thought for 6s", folded by default; a thread-style rule when open.
/// While streaming: "Thinking… 4s".
struct ThinkingView: View {
    let item: ClaudeItem
    let palette: ClaudePalette
    let fontSize: CGFloat
    @State private var expanded = false

    var body: some View {
        let p = palette
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 10)
                    if item.isRunning {
                        TimelineView(.periodic(from: item.startedAt, by: 1)) { context in
                            Text("Thinking… " + ClaudeFormat.duration(context.date.timeIntervalSince(item.startedAt)))
                        }
                    } else {
                        Text(item.duration.map { "Thought for " + ClaudeFormat.duration(max(1, $0)) } ?? "Thought")
                    }
                }
                .font(.system(size: fontSize - 1, weight: .medium))
                .foregroundStyle(p.dim)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide thinking" : "Show thinking")
            if expanded {
                Text(item.text)
                    .font(.system(size: fontSize - 0.5))
                    .foregroundStyle(p.dim)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 17)
                    .overlay(alignment: .leading) { Rectangle().fill(p.border).frame(width: 1) }
                    .padding(.leading, 4)
            }
        }
    }
}

// MARK: - A single tool call

/// One tool call on its own: an edit as a diff card, Bash as an output card,
/// anything else as a one-step run.
struct ToolCallView: View {
    let item: ClaudeItem
    let palette: ClaudePalette
    let fontSize: CGFloat
    var directory: String?
    var session: ClaudeCodeSession?

    var body: some View {
        switch item.toolName {
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            EditCard(item: item, palette: palette, fontSize: fontSize, directory: directory, session: session)
        case "Bash":
            BashCard(item: item, palette: palette, fontSize: fontSize, directory: directory)
        default:
            ToolRunCard(items: [item], palette: palette, fontSize: fontSize, directory: directory, session: session)
        }
    }
}

// MARK: - Tool runs

/// Consecutive tool calls as one card, one compact row per step. With two or
/// more, a header names the run ("Explored the code · Grep 1 · Read 3") and folds it.
struct ToolRunCard: View {
    let items: [ClaudeItem]
    let palette: ClaudePalette
    let fontSize: CGFloat
    var directory: String?
    var session: ClaudeCodeSession?
    @State private var collapsed = false

    var body: some View {
        let p = palette
        let tools = items.filter { $0.kind == .tool }
        VStack(spacing: 0) {
            if tools.count >= 2 {
                header(tools, p)
            }
            if !collapsed {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 || tools.count >= 2 { p.border.opacity(0.5).frame(height: 0.5) }
                    ToolStepRow(item: item, palette: p, fontSize: fontSize, directory: directory, session: session,
                                indent: tools.count >= 2 ? 20 : 0)
                }
            }
        }
        .transcriptCard(p)
    }

    private func header(_ tools: [ClaudeItem], _ p: ClaudePalette) -> some View {
        let work = ClaudeWork(items)
        return Button { withAnimation(.easeOut(duration: 0.15)) { collapsed.toggle() } } label: {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .foregroundStyle(p.dim)
                    .frame(width: 10)
                Text(Self.title(tools)).font(.system(size: fontSize - 1.5, weight: .semibold)).foregroundStyle(p.foreground)
                Text(work.breakdown).font(.system(size: fontSize - 1.5)).foregroundStyle(p.dim).lineLimit(1)
                Spacer(minLength: 6)
                if work.failures > 0 {
                    Text("\(work.failures) failed").font(.system(size: fontSize - 2.5, weight: .medium)).foregroundStyle(DS.Status.failed)
                }
                if work.running {
                    SpinnerRing(size: 11)
                } else if let d = work.duration {
                    Text(ClaudeFormat.preciseDuration(d)).font(.system(size: fontSize - 2.5)).foregroundStyle(p.dim)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show each step" : "Fold this run")
    }

    static let readOnlyTools: Set<String> = ["Read", "Grep", "Glob", "LS", "NotebookRead", "WebFetch", "WebSearch", "BashOutput", "TaskOutput"]
    static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

    /// What a run did, in a few words.
    static func title(_ tools: [ClaudeItem]) -> String {
        let names = Set(tools.map(\.toolName))
        if names.isSubset(of: readOnlyTools) {
            return names.isSubset(of: ["WebFetch", "WebSearch"]) ? "Searched the web" : "Explored the code"
        }
        if names.isSubset(of: editTools) {
            let files = Set(tools.compactMap { ($0.input["file_path"] ?? $0.input["notebook_path"]) as? String }).count
            return "Edited \(files) file\(files == 1 ? "" : "s")"
        }
        if names == ["Bash"] { return "Ran \(tools.count) commands" }
        if names.isSubset(of: readOnlyTools.union(["Bash"])) { return "Explored the code" }
        return "Worked on it"
    }
}

/// Consecutive edits: the first as its diff card, the rest folded into one
/// row ("▸ ✓ Edit StreamWriter.swift +9 −2 … Write BrokenPipeTests.swift +64")
/// that opens to a row per edit.
struct EditRunView: View {
    let items: [ClaudeItem]
    let palette: ClaudePalette
    let fontSize: CGFloat
    var directory: String?
    var session: ClaudeCodeSession?
    @State private var expanded = false

    /// Whether a run is edits only (no thinking or other tools in between).
    static func applies(to items: [ClaudeItem]) -> Bool {
        items.count >= 2 && items.allSatisfy { $0.kind == .tool && ToolRunCard.editTools.contains($0.toolName) }
    }

    var body: some View {
        let p = palette
        let rest = Array(items.dropFirst())
        VStack(alignment: .leading, spacing: 6) {
            EditCard(item: items[0], palette: p, fontSize: fontSize, directory: directory, session: session)
            VStack(spacing: 0) {
                Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(p.dim)
                            .frame(width: 10)
                        if let first = rest.first {
                            StepStatusIcon(item: first)
                            summary(first, p)
                        }
                        Spacer(minLength: 6)
                        ForEach(rest.dropFirst().prefix(2), id: \.id) { item in summary(item, p) }
                        if rest.count > 3 {
                            Text("+\(rest.count - 3) more").font(.system(size: fontSize - 2)).foregroundStyle(p.dim).fixedSize()
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Fold these edits" : "Show each edit")
                if expanded {
                    ForEach(rest, id: \.id) { item in
                        p.border.opacity(0.5).frame(height: 0.5)
                        ToolStepRow(item: item, palette: p, fontSize: fontSize, directory: directory, session: session, indent: 20)
                    }
                }
            }
            .transcriptCard(p, radius: DS.Radius.row)
        }
    }

    /// "Edit StreamWriter.swift +9 −2"
    private func summary(_ item: ClaudeItem, _ p: ClaudePalette) -> some View {
        let path = (item.input["file_path"] ?? item.input["notebook_path"]) as? String ?? ""
        return HStack(spacing: 8) {
            Text(ClaudeToolFormat.displayName(item.toolName)).font(.system(size: fontSize - 2)).foregroundStyle(p.dim)
            Text((path as NSString).lastPathComponent)
                .font(ChatTypography.current.codeFont(size: fontSize - 2))
                .foregroundStyle(p.foreground)
                .lineLimit(1).truncationMode(.middle)
                .help(path)
            if let stats = item.diffStats { DiffStatsText(stats: stats, palette: p, size: fontSize - 2) }
        }
        .layoutPriority(1)
    }
}

/// One step of a run: status, tool, argument (folder dimmed), meta; click to
/// expand its diff, output or result. File steps offer "Open ↗" on hover.
struct ToolStepRow: View {
    let item: ClaudeItem
    let palette: ClaudePalette
    let fontSize: CGFloat
    var directory: String?
    var session: ClaudeCodeSession?
    var indent: CGFloat = 0
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        let p = palette
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { if hasDetail { expanded.toggle() } } label: {
                    HStack(spacing: 8) {
                        icon.frame(width: 16)
                        Text(name)
                            .font(.system(size: fontSize - 2))
                            .foregroundStyle(item.toolName.hasPrefix("mcp__") ? p.cyan : p.dim)
                            .lineLimit(1)
                            .fixedSize()
                            .frame(minWidth: 46, alignment: .leading)
                        Text(argument)
                            .font(ChatTypography.current.codeFont(size: fontSize - 2))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(name) \(item.summary)")
                if hovering, let path = filePath {
                    Button {
                        ClaudeLinks.openInEditor(URL(fileURLWithPath: path), line: item.input["offset"] as? Int)
                    } label: {
                        Text("Open ↗").font(.system(size: fontSize - 2.5)).foregroundStyle(p.blue)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(ClaudeToolFormat.shortPath(path))")
                }
                meta(p)
            }
            .padding(.leading, 12 + indent)
            .padding(.trailing, 12)
            .frame(minHeight: 30)
            .background(hovering ? p.foreground.opacity(0.04) : .clear)
            .onHover { hovering = $0 }
            if expanded {
                detail(p)
                    .padding(.leading, 12 + indent)
                    .padding([.trailing, .bottom], 10)
            }
        }
    }

    private var name: String {
        item.kind == .thinking ? "Thought" : ClaudeToolFormat.displayName(item.toolName)
    }

    @ViewBuilder private var icon: some View {
        if item.kind == .thinking {
            Image(systemName: "sparkle").font(.system(size: 10)).foregroundStyle(palette.dim)
        } else {
            StepStatusIcon(item: item)
        }
    }

    private var filePath: String? {
        guard ["Read", "Edit", "MultiEdit", "Write", "NotebookEdit"].contains(item.toolName) else { return nil }
        return (item.input["file_path"] ?? item.input["notebook_path"]) as? String
    }

    private var argument: AttributedString {
        if item.kind == .thinking {
            var a = AttributedString(item.text.split(separator: "\n").first.map(String.init) ?? "")
            a.foregroundColor = palette.dim
            return a
        }
        if let path = filePath { return ClaudePathText.attributed(path, directory: directory, palette: palette) }
        if item.toolName == "Grep" {
            var a = AttributedString(item.input["pattern"] as? String ?? "")
            a.foregroundColor = palette.foreground
            if let path = item.input["path"] as? String {
                let (folder, name) = ClaudePathText.split(path, directory: directory)
                var b = AttributedString("  in " + folder + name)
                b.foregroundColor = palette.dim
                a += b
            }
            return a
        }
        var a = AttributedString(item.summary)
        a.foregroundColor = palette.foreground
        return a
    }

    @ViewBuilder
    private func meta(_ p: ClaudePalette) -> some View {
        if item.kind == .thinking, let d = item.duration {
            Text(ClaudeFormat.duration(max(1, d))).font(.system(size: fontSize - 2.5)).foregroundStyle(p.dim)
        } else if let stats = item.diffStats {
            DiffStatsText(stats: stats, palette: p, size: fontSize - 2.5)
        } else if let meta = item.meta {
            Text(meta).font(.system(size: fontSize - 2.5)).foregroundStyle(item.isError ? DS.Status.failed : p.dim).fixedSize()
        }
    }

    private var hasDetail: Bool {
        if item.kind == .thinking { return !item.text.isEmpty }
        return !(item.result ?? "").isEmpty || ClaudeToolFormat.diff(name: item.toolName, input: item.input) != nil
    }

    @ViewBuilder
    private func detail(_ p: ClaudePalette) -> some View {
        if item.kind == .thinking {
            Text(item.text)
                .font(.system(size: fontSize - 1)).foregroundStyle(p.dim)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if let diff = ClaudeToolFormat.diff(name: item.toolName, input: item.input) {
            DiffView(lines: diff, palette: p, fontSize: fontSize - 2,
                     language: filePath.map { ($0 as NSString).pathExtension })
        } else if item.toolName == "Bash" {
            BashOutputBody(item: item, palette: p, fontSize: fontSize, directory: directory, framed: true)
        } else if let result = item.result.map(ClaudeToolFormat.visibleResult), !result.isEmpty {
            ResultText(text: result, isError: item.isError, palette: p, fontSize: fontSize)
        }
    }
}

/// A tool's raw result, scrollable and capped.
struct ResultText: View {
    let text: String
    let isError: Bool
    let palette: ClaudePalette
    let fontSize: CGFloat

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text.count > 12000 ? String(text.prefix(12000)) + "\n…" : text)
                .font(ChatTypography.current.codeFont(size: fontSize - 2))
                .foregroundStyle(isError ? DS.Status.failed : palette.foreground.opacity(0.85))
                .textSelection(.enabled)
                .fixedSize()
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(palette.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Edit

/// "✓ Edit  Sources/Shell/App/AppDelegate.swift +4 −1  [Unified|Split] Copy Review ⌘⇧R"
/// over the diff, with word-level highlights.
struct EditCard: View {
    let item: ClaudeItem
    let palette: ClaudePalette
    let fontSize: CGFloat
    var directory: String?
    var session: ClaudeCodeSession?
    @State private var split: Bool?
    @State private var showAll = false
    @State private var width: CGFloat = 0
    @State private var copied = false

    /// Lines shown before "Show all": a new file starts short.
    private var limit: Int { item.toolName == "Write" ? 12 : 40 }

    var body: some View {
        let p = palette
        let diff = ClaudeToolFormat.diff(name: item.toolName, input: item.input)
        let canSplit = diff?.contains { $0.kind == .removed || $0.kind == .context } ?? false
        let style = ChatPreferences.shared.diffStyle
        let autoSplit = style == .sideBySide || (style == .automatic && width >= DiffView.sideBySideMinWidth)
        let isSplit = canSplit && (split ?? autoSplit)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                StepStatusIcon(item: item)
                ToolChip(name: item.toolName == "Write" ? "Write" : "Edit", palette: p)
                if let path = filePath {
                    Text(ClaudePathText.attributed(path, directory: directory, palette: p))
                        .font(ChatTypography.current.codeFont(size: fontSize - 2))
                        .lineLimit(1).truncationMode(.head)
                        .help(path)
                }
                if let stats = item.diffStats ?? diff.map(Self.stats) {
                    DiffStatsText(stats: stats, palette: p, size: fontSize - 2.5)
                }
                Spacer(minLength: 6)
                if canSplit {
                    UnifiedSplitPicker(split: Binding(get: { isSplit }, set: { split = $0 }), palette: p)
                }
                if let diff {
                    CardTextButton(title: copied ? "Copied" : "Copy", palette: p) {
                        ClaudeClipboard.copy(Self.unifiedText(diff))
                        copied = true
                    }
                    .help("Copy the diff")
                }
                CardTextButton(title: "Review ⌘⇧R", palette: p, filled: true) {
                    if let session { session.requestReviewChanges(path: filePath) } else {
                        NotificationCenter.default.post(name: .shellReviewChanges, object: nil, userInfo: filePath.map { ["path": $0] })
                    }
                }
                .help("Review all of Claude's changes")
            }
            .padding(.leading, 12).padding(.trailing, 8)
            .frame(minHeight: 38)
            .background(p.surface)
            if let diff {
                p.border.opacity(0.6).frame(height: 0.5)
                DiffView(lines: diff, palette: p, fontSize: fontSize - 2, collapsedLimit: showAll ? nil : limit,
                         split: isSplit, framed: false, language: filePath.map { ($0 as NSString).pathExtension })
                if diff.count > limit {
                    HStack {
                        CardTextButton(title: showAll ? "Show less" : "Show all \(diff.count) lines", palette: p, color: p.blue) {
                            showAll.toggle()
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 6).padding(.bottom, 4)
                }
            }
            if item.isError, let result = item.result {
                Text(ClaudeToolFormat.visibleResult(result))
                    .font(ChatTypography.current.codeFont(size: fontSize - 2))
                    .foregroundStyle(DS.Status.failed)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .padding(10)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .transcriptCard(p, fill: p.sunken)
    }

    private var filePath: String? { (item.input["file_path"] ?? item.input["notebook_path"]) as? String }

    static func stats(_ lines: [ClaudeDiff.Line]) -> ClaudeDiffStats {
        .init(added: lines.filter { $0.kind == .added }.count, removed: lines.filter { $0.kind == .removed }.count)
    }

    /// The diff as `+`/`-`/` ` lines, for the clipboard.
    static func unifiedText(_ lines: [ClaudeDiff.Line]) -> String {
        lines.map { line in
            switch line.kind {
            case .added: "+" + line.text
            case .removed: "-" + line.text
            case .context: " " + line.text
            case .gap: "@@" + (line.text.isEmpty ? "" : " " + line.text)
            }
        }.joined(separator: "\n")
    }
}

/// Unified | Split.
struct UnifiedSplitPicker: View {
    @Binding var split: Bool
    let palette: ClaudePalette

    var body: some View {
        HStack(spacing: 0) {
            segment("Unified", selected: !split) { split = false }
            segment("Split", selected: split) { split = true }
        }
        .padding(2)
        .background(palette.foreground.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.Radius.control))
        .fixedSize()
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(selected ? palette.foreground : palette.dim)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(selected ? palette.foreground.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Bash

/// "✓ Bash  <command>  Passed 41.2s" over the last lines of output.
struct BashCard: View {
    let item: ClaudeItem
    let palette: ClaudePalette
    let fontSize: CGFloat
    var directory: String?

    var body: some View {
        let p = palette
        let command = item.input["command"] as? String ?? item.summary
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                StepStatusIcon(item: item)
                ToolChip(name: "Bash", palette: p)
                Text(CodeHighlighter.attributed(command.replacingOccurrences(of: "\n", with: " ⏎ "), language: "sh", palette: p))
                    .font(ChatTypography.current.codeFont(size: fontSize - 2))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(command)
                state(p)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(p.surface)
            if !(item.result.map(ClaudeToolFormat.visibleResult) ?? "").isEmpty {
                p.border.opacity(0.6).frame(height: 0.5)
                BashOutputBody(item: item, palette: p, fontSize: fontSize, directory: directory, framed: false)
            }
        }
        .transcriptCard(p, fill: p.sunken)
    }

    @ViewBuilder
    private func state(_ p: ClaudePalette) -> some View {
        HStack(spacing: 6) {
            if item.isRunning {
                TimelineView(.periodic(from: item.startedAt, by: 1)) { context in
                    Text(ClaudeFormat.duration(context.date.timeIntervalSince(item.startedAt))).foregroundStyle(p.dim)
                }
            } else if item.isError {
                Text("Failed").foregroundStyle(DS.Status.failed)
                if let code = item.result.flatMap(ClaudeOutput.exitCode) { Text("exit \(code)").foregroundStyle(p.dim) }
            } else if item.input["run_in_background"] as? Bool == true {
                Text("In background").foregroundStyle(p.dim)
            } else if item.result != nil {
                Text("Passed").foregroundStyle(DS.Status.done)
                if let d = item.duration { Text(ClaudeFormat.preciseDuration(d)).foregroundStyle(p.dim) }
            }
        }
        .font(.system(size: fontSize - 2.5))
        .fixedSize()
    }
}

/// A command's output: ANSI stripped, the last ~10 lines with "Show all N
/// lines · Copy output · Open in terminal tab".
struct BashOutputBody: View {
    let item: ClaudeItem
    let palette: ClaudePalette
    let fontSize: CGFloat
    var directory: String?
    var framed = false
    @State private var showAll = false
    @State private var copied = false

    static let previewLines = 10

    var body: some View {
        let p = palette
        let output = ClaudeOutput.stripANSI(ClaudeToolFormat.visibleResult(item.result ?? ""))
        let lines = ClaudeOutput.lines(output)
        let shown = showAll ? Array(lines.prefix(4000)) : Array(lines.suffix(Self.previewLines))
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(showAll ? [.vertical, .horizontal] : [.horizontal], showsIndicators: showAll) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : String(line))
                            .foregroundStyle(color(line, p))
                    }
                }
                .font(ChatTypography.current.codeFont(size: fontSize - 2))
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize()
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: showAll ? 420 : nil)
            .fixedSize(horizontal: false, vertical: true)
            p.border.opacity(0.5).frame(height: 0.5)
            HStack(spacing: 6) {
                if lines.count > Self.previewLines {
                    CardTextButton(title: showAll ? "Show last \(Self.previewLines) lines" : "Show all \(lines.count) lines",
                                   palette: p, color: p.blue) { showAll.toggle() }
                }
                CardTextButton(title: copied ? "Copied" : "Copy output", palette: p, color: p.dim) {
                    ClaudeClipboard.copy(output)
                    copied = true
                }
                if let directory {
                    CardTextButton(title: "Open in terminal tab", palette: p, color: p.dim) {
                        ClaudeTerminalLauncher.openTab(directory: directory)
                    }
                    .help("Open a terminal tab in \(ClaudeToolFormat.shortPath(directory))")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 30)
        }
        .background(framed ? p.background.opacity(0.6) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: framed ? 6 : 0))
    }

    private func color(_ line: Substring, _ p: ClaudePalette) -> Color {
        if Self.isSuccessLine(line) { return p.green }
        if ClaudeOutput.isErrorLine(line) { return p.red }
        return p.foreground.opacity(item.isError ? 0.85 : 0.72)
    }

    /// A run's success summary ("** TEST SUCCEEDED **", "ok  pkg 0.2s",
    /// "== 12 passed in 0.4s =="), not every line that mentions "passed".
    static func isSuccessLine(_ line: Substring) -> Bool {
        if line.contains("SUCCEEDED") || line.hasPrefix("ok ") || line.hasPrefix("PASS") { return true }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("=") && trimmed.contains(" passed") && !trimmed.contains("failed")
    }
}

// MARK: - Folded turns

/// "▸ Worked for 6m 12s · 28 tool calls · Read 9 · Edit 3 · committed 74c838f · opened PR #39"
struct ToolGroupView: View {
    let items: [ClaudeItem]
    let palette: ClaudePalette
    let mentions: InlineMarkdown.MentionStyle
    let fontSize: CGFloat
    var directory: String?
    var session: ClaudeCodeSession?
    @State var expanded = false

    var body: some View {
        let p = palette
        let work = ClaudeWork(items)
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(p.dim)
                        .frame(width: 10)
                    if work.running { SpinnerRing(size: 11) }
                    Text(Self.headline(work))
                        .font(.system(size: fontSize - 1.5, weight: .medium))
                        .foregroundStyle(p.foreground)
                        .fixedSize()
                    Text(Self.details(work))
                        .font(.system(size: fontSize - 1.5))
                        .foregroundStyle(p.dim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if work.failures > 0 {
                        Text("\(work.failures) failed").font(.system(size: fontSize - 1.5, weight: .medium)).foregroundStyle(DS.Status.failed)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(p.surface, in: RoundedRectangle(cornerRadius: DS.Radius.row))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.row).strokeBorder(p.border.opacity(0.8), lineWidth: 0.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Fold the work" : "Show each step")
            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(ClaudeTranscript.visibleRows(items)) { row in
                        ClaudeRowView(row: row, palette: p, mentions: mentions, fontSize: fontSize, directory: directory, session: session)
                    }
                }
                .padding(.leading, 12)
            }
        }
    }

    /// "Worked for 6m 12s", or "Working…" while it runs.
    static func headline(_ work: ClaudeWork) -> String {
        if work.running { return "Working…" }
        guard let d = work.duration, d >= 1 else { return "Worked" }
        return "Worked for " + ClaudeFormat.duration(d)
    }

    /// "28 tool calls · Read 9 · Edit 3 · 1 subagent · committed 74c838f · opened PR #39"
    static func details(_ work: ClaudeWork) -> String {
        var parts = ["\(work.toolCount) tool call\(work.toolCount == 1 ? "" : "s")"]
        if !work.breakdown.isEmpty { parts.append(work.breakdown) }
        if work.subagents > 0 { parts.append("\(work.subagents) subagent\(work.subagents == 1 ? "" : "s")") }
        if let sha = work.commits.last { parts.append("committed \(sha)") }
        if let pr = work.pullRequests.last { parts.append("opened PR #\(pr.number)") }
        return parts.joined(separator: " · ")
    }

    /// "Read 3 · Edit 2 · Bash", most used first.
    static func breakdown(_ tools: [ClaudeItem]) -> String {
        var counts: [String: Int] = [:]
        for t in tools { counts[ClaudeToolFormat.displayName(t.toolName), default: 0] += 1 }
        return ClaudeWork.breakdown(counts)
    }
}

// MARK: - End of turn

/// A finished turn that changed files or committed: what it did, with links.
/// Only rows that can be read from the transcript or the repository show.
struct TurnSummaryCard: View {
    let items: [ClaudeItem]
    let palette: ClaudePalette
    let fontSize: CGFloat
    var directory: String?
    var session: ClaudeCodeSession?
    @State private var copied = false

    var body: some View {
        let p = palette
        let work = ClaudeWork(items)
        let user = items.first { $0.kind == .user }
        let rows = Self.rows(work, repository: session?.repository, directory: directory)
        let prURL = work.pullRequests.last?.url ?? session?.repository?.pullRequest?.url
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(Color.black.opacity(0.8))
                    .frame(width: 20, height: 20)
                    .background(DS.Status.done, in: Circle())
                Text(Self.title(work)).font(.system(size: fontSize + 1, weight: .semibold))
                Spacer(minLength: 8)
                let meta = [(user?.turnDuration ?? work.duration).map(ClaudeFormat.duration),
                            user?.turnCost.map { String(format: "$%.2f", $0) }].compactMap { $0 }
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · ")).font(.system(size: fontSize - 2.5)).foregroundStyle(p.dim)
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
                ForEach(rows, id: \.key) { row in
                    GridRow {
                        Text(row.key).foregroundStyle(p.dim).gridColumnAlignment(.leading)
                        row.value(p, fontSize)
                    }
                }
            }
            .font(.system(size: fontSize - 1))
            .padding(.leading, 46).padding(.trailing, 16).padding(.top, 4).padding(.bottom, 14)
            HStack(spacing: 8) {
                Button("Review changes") { session?.requestReviewChanges() }
                    .buttonStyle(.labeled(.neutral))
                if let prURL {
                    Button("Open PR on GitHub ↗") { NSWorkspace.shared.open(prURL) }
                        .buttonStyle(.labeled(.neutral))
                }
                Spacer()
                Button {
                    ClaudeClipboard.copy(Self.plainText(work, rows: rows))
                    copied = true
                } label: {
                    Text(copied ? "Copied" : "Copy summary").foregroundStyle(p.dim)
                }
                .buttonStyle(.labeled(.plain))
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(p.surface)
            .overlay(alignment: .top) { p.border.opacity(0.6).frame(height: 0.5) }
        }
        .transcriptCard(p, fill: p.raised.opacity(0.75), radius: DS.Radius.panel)
    }

    struct Row {
        var key: String
        var text: String
        var value: (ClaudePalette, CGFloat) -> AnyView
    }

    static func title(_ work: ClaudeWork) -> String {
        if let pr = work.pullRequests.last { return "Opened PR #\(pr.number)" }
        if work.commits.count > 1 { return "Made \(work.commits.count) commits" }
        if let sha = work.commits.last { return "Committed \(sha)" }
        return "Changed \(work.files.count) file\(work.files.count == 1 ? "" : "s")"
    }

    @MainActor
    static func rows(_ work: ClaudeWork, repository: GitRepository?, directory: String?) -> [Row] {
        var rows: [Row] = []
        if let pr = work.pullRequests.last {
            let title = repository?.pullRequest.flatMap { $0.number == pr.number ? $0.title : nil }
            let text = "#\(pr.number)" + (title.map { " " + $0 } ?? "")
            rows.append(Row(key: "Pull request", text: text) { p, _ in
                AnyView(Link(text, destination: pr.url).foregroundStyle(p.blue))
            })
        }
        if let repo = repository {
            let branch = repo.branchLabel
            rows.append(Row(key: "Branch", text: branch) { p, size in
                AnyView(Text(branch).font(ChatTypography.current.codeFont(size: size - 2)).foregroundStyle(p.foreground))
            })
        }
        let stats = work.stats
        let files = work.files.count
        let filesText = "\(files) file\(files == 1 ? "" : "s")"
        if let sha = work.commits.last {
            rows.append(Row(key: "Commit", text: "\(sha) · \(filesText) +\(stats.added) −\(stats.removed)") { p, size in
                AnyView(HStack(spacing: 8) {
                    Text(sha).font(ChatTypography.current.codeFont(size: size - 2)).foregroundStyle(p.yellow)
                    if files > 0 {
                        Text(filesText).foregroundStyle(p.dim)
                        DiffStatsText(stats: stats, palette: p, size: size - 2)
                    }
                })
            })
        } else if files > 0 {
            let names = work.files.prefix(3).map(\.name).joined(separator: ", ") + (files > 3 ? " and \(files - 3) more" : "")
            rows.append(Row(key: "Changes", text: "\(names) +\(stats.added) −\(stats.removed)") { p, size in
                AnyView(HStack(spacing: 8) {
                    Text(names).foregroundStyle(p.foreground).lineLimit(1)
                    DiffStatsText(stats: stats, palette: p, size: size - 2)
                })
            })
        }
        if let tests = work.tests {
            rows.append(Row(key: "Tests", text: tests) { p, _ in
                AnyView(Text(tests).foregroundStyle(tests.contains("failed") ? DS.Status.failed : p.foreground))
            })
        }
        return rows
    }

    static func plainText(_ work: ClaudeWork, rows: [Row]) -> String {
        ([title(work)] + rows.map { "\($0.key): \($0.text)" }).joined(separator: "\n")
    }
}

// MARK: - CI failure

/// A failed CI check in the transcript: the failing log lines, Fix with
/// Claude, Re-run failed jobs and Full log.
struct CheckFailureCard: View {
    let item: ClaudeItem
    let palette: ClaudePalette
    let fontSize: CGFloat
    var session: ClaudeCodeSession?

    var body: some View {
        let p = palette
        if let failure = item.checkFailure {
            let job = failure.job
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Color.black.opacity(0.8))
                        .frame(width: 18, height: 18)
                        .background(DS.Status.failed, in: Circle())
                    Text("\(job.name) failed").font(.system(size: fontSize - 0.5, weight: .semibold))
                    Text(Self.subtitle(failure)).font(.system(size: fontSize - 2)).foregroundStyle(p.foreground.opacity(0.75))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if job.runID != nil {
                        Text("GitHub Actions")
                            .font(.system(size: 11)).foregroundStyle(p.foreground.opacity(0.75))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(p.foreground.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                            .fixedSize()
                    }
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
                if let line = Self.failureLine(failure) {
                    Text(Self.failureLineText(line, step: failure.failedStep, palette: p, fontSize: fontSize))
                        .font(.system(size: fontSize - 1.5)).foregroundStyle(p.foreground.opacity(0.75))
                        .padding(.leading, 42).padding(.trailing, 14).padding(.top, 2).padding(.bottom, 8)
                }
                let excerpt = ClaudeOutput.logExcerpt(failure.log)
                if !excerpt.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(excerpt.enumerated()), id: \.offset) { _, line in
                            Text(line.text)
                                .foregroundStyle(line.isError ? p.red.mix(with: p.foreground, by: 0.35) : p.dim)
                                .lineLimit(1).truncationMode(.tail)
                                .padding(.horizontal, 12).padding(.vertical, 1.5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(line.isError ? DS.Status.failed.opacity(0.14) : .clear)
                                .help(line.text)
                        }
                    }
                    .font(ChatTypography.current.codeFont(size: fontSize - 2))
                    .textSelection(.enabled)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(p.isDark ? 0.3 : 0.05), in: RoundedRectangle(cornerRadius: DS.Radius.row))
                    .padding(.horizontal, 14)
                }
                HStack(spacing: 6) {
                    if item.checkFixRequested {
                        // The same state the inspector's Checks card shows.
                        HStack(spacing: 6) {
                            SpinnerRing(color: DS.claude, size: 10)
                            Text("Claude is fixing")
                        }
                        .font(.system(size: DS.Size.body, weight: .medium))
                        .foregroundStyle(DS.claude)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 26)
                        .background(DS.claude.opacity(0.18), in: RoundedRectangle(cornerRadius: DS.Radius.control))
                        .accessibilityElement(children: .combine)
                    } else {
                        Button {
                            session?.fixCheckFailure(job, log: failure.log)
                        } label: {
                            HStack(spacing: 6) {
                                ClaudeMark(size: 11, color: .white)
                                Text("Fix with Claude")
                            }
                        }
                        .buttonStyle(.labeled(.primary))
                        .disabled(session?.canSend != true)
                    }
                    if let repo = session?.repository {
                        Button("Re-run failed jobs") {
                            Task { await BranchChecksModel.shared(for: repo).rerun(job) }
                        }
                        .buttonStyle(.labeled(.neutral))
                    }
                    if let url = job.url {
                        Button("Full log ↗") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.labeled(.neutral))
                    }
                    Spacer(minLength: 6)
                    Text("The log and failing test go to Claude")
                        .font(.system(size: fontSize - 2.5)).foregroundStyle(p.dim)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 12)
            }
            .transcriptCard(p, tint: DS.Status.failed, radius: DS.Radius.panel)
        }
    }

    /// "Test workflow · 74c838f · 4m 02s"
    static func subtitle(_ f: ClaudeCheckFailure) -> String {
        [f.workflowName.map { $0 + " workflow" }, f.headSHA, f.job.duration.map(ClaudeFormat.duration)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// The failure line with the step name in the code font.
    @MainActor
    static func failureLineText(_ line: String, step: String?, palette: ClaudePalette, fontSize: CGFloat) -> AttributedString {
        var text = AttributedString(line)
        if let step, let range = text.range(of: "step " + step) {
            let name = text.index(range.lowerBound, offsetByCharacters: 5)..<range.upperBound
            text[name].font = ChatTypography.current.codeFont(size: fontSize - 2)
            text[name].foregroundColor = palette.foreground
        }
        return text
    }

    /// "Failed at step Run tests · 1 of 211 tests failed"
    static func failureLine(_ f: ClaudeCheckFailure) -> String? {
        var parts: [String] = []
        if let step = f.failedStep { parts.append("Failed at step \(step)") }
        if let tests = ClaudeOutput.testSummary(f.log) {
            parts.append(tests.contains("failed") ? tests.replacingOccurrences(of: " failed", with: " tests failed") : tests)
        } else if let detail = f.job.detail, !detail.isEmpty {
            parts.append(detail)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Status line

/// Above the composer: "◌ Writing the PR description  2m 41s · ↓ 18.2k tokens   esc to interrupt",
/// or "● Waiting for your approval  Press 1, 2 or 3, or type different instructions".
struct ClaudeActivityLine: View {
    let claude: ClaudeCodeSession
    let palette: ClaudePalette

    var body: some View {
        let p = palette
        if let req = claude.pending.first {
            HStack(spacing: 9) {
                Circle().fill(DS.Status.needsYou).frame(width: 8, height: 8)
                Text(Self.waitingTitle(req)).fontWeight(.medium).foregroundStyle(DS.Status.needsYou)
                Text(Self.waitingHint(req)).foregroundStyle(p.dim).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 4)
        } else if claude.isRunning {
            HStack(spacing: 9) {
                SpinnerRing(size: 12)
                Text(claude.activityLabel).fontWeight(.medium).foregroundStyle(DS.Status.working).lineLimit(1)
                TimelineView(.periodic(from: claude.turnStartedAt ?? Date(), by: 1)) { context in
                    Text(Self.progress(elapsed: context.date.timeIntervalSince(claude.turnStartedAt ?? context.date),
                                       tokens: claude.turnOutputTokens))
                        .foregroundStyle(p.dim)
                        .monospacedDigit()
                }
                .layoutPriority(-1)
                Spacer(minLength: 6)
                Text("esc")
                    .font(.system(size: 11))
                    .foregroundStyle(p.foreground.opacity(0.8))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(p.foreground.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    .fixedSize()
                Text("to interrupt").font(.system(size: 12)).foregroundStyle(p.dim).fixedSize()
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 4)
        }
    }

    /// "2m 41s · ↓ 18.2k tokens"
    static func progress(elapsed: TimeInterval, tokens: Int) -> String {
        var s = ClaudeFormat.duration(elapsed)
        if tokens > 0 { s += " · ↓ " + ClaudeFormat.tokens(tokens) + " tokens" }
        return s
    }

    static func waitingTitle(_ req: ClaudePermissionRequest) -> String {
        req.isQuestion ? "Claude has a question" : req.isPlan ? "Review Claude's plan" : "Waiting for your approval"
    }

    static func waitingHint(_ req: ClaudePermissionRequest) -> String {
        if req.isQuestion {
            let qs = req.questions
            if qs.count == 1, let q = qs.first, !q.multiSelect, q.options.count > 1 { return "Press 1–\(q.options.count), or type an answer" }
            return "Choose an answer, or type one"
        }
        if req.isPlan { return "Press 1, 2 or 3, or type feedback to keep planning" }
        return req.suggestions.isEmpty ? "Press 1 or 2, or type different instructions" : "Press 1, 2 or 3, or type different instructions"
    }
}
