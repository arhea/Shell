import AppKit
import Observation
import SwiftUI

/// Directory listings for the explorer, cached until git or the file system
/// reports a change.
@MainActor
@Observable
final class FileTreeModel {
    struct Entry: Hashable {
        var name: String
        var path: String // relative to the root
        var isDirectory: Bool
    }

    struct Row: Identifiable, Hashable {
        var entry: Entry
        var depth: Int
        var id: String { entry.path }
    }

    let root: URL
    var expanded: Set<String> {
        didSet { onExpandedChange?(expanded) }
    }
    private(set) var revision = 0
    @ObservationIgnored private var listings: [String: [Entry]] = [:]
    @ObservationIgnored var onExpandedChange: ((Set<String>) -> Void)?

    init(root: URL, expanded: Set<String>) {
        self.root = root
        self.expanded = expanded
    }

    func invalidate() {
        listings.removeAll()
        revision &+= 1
    }

    func toggle(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
    }

    func listing(_ rel: String) -> [Entry] {
        if let cached = listings[rel] { return cached }
        let url = rel.isEmpty ? root : root.appendingPathComponent(rel)
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        let entries = items.compactMap { item -> Entry? in
            let name = item.lastPathComponent
            guard name != ".git", name != ".DS_Store" else { return nil }
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return Entry(name: name, path: rel.isEmpty ? name : rel + "/" + name, isDirectory: isDir)
        }.sorted { a, b in
            a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        listings[rel] = entries
        return entries
    }

    var rows: [Row] {
        _ = revision
        var out: [Row] = []
        func walk(_ rel: String, _ depth: Int) {
            for e in listing(rel) {
                out.append(Row(entry: e, depth: depth))
                if e.isDirectory, expanded.contains(e.path), out.count < 20_000 { walk(e.path, depth + 1) }
            }
        }
        walk("", 0)
        return out
    }
}

/// What the sidebar is attached to: a native Claude session or a terminal pane.
struct SidebarContext {
    /// The pane's working directory.
    var directory: String
    /// Inserts text into the Claude prompt or the terminal's command editor.
    var insert: ((String) -> Void)?
    /// "@path" for Claude, a shell-quoted path for the terminal.
    var isClaude: Bool
    /// Opens a directory in a new tab, optionally running a command there.
    var openTab: ((String, String?) -> Void)?
    /// Goes to a tab already in that directory (any window), else opens one.
    var switchTo: ((String) -> Void)?
    /// Opens the GitHub tab on this repository.
    var openGitHub: (() -> Void)?
}

/// The Files tab of the window's right sidebar.
struct FileExplorerView: View {
    let context: SidebarContext
    let repo: GitRepository
    let tree: FileTreeModel
    var onClose: () -> Void

    @State private var selected: String?

    private var changedOnly: Bool { SettingsStore.shared.settings.claudeExplorerChangedOnly }

    var body: some View {
        let p = ClaudePalette.current
        VStack(spacing: 0) {
            header(p)
            p.border.frame(height: 1)
            if changedOnly {
                changesList(p)
            } else {
                treeList(p)
            }
        }
        .background(p.surface)
        .foregroundStyle(p.foreground)
        // Re-list folders only when the working tree actually changed, not on
        // every refresh (FSEvents fire constantly during builds).
        .onChange(of: repo.status) { _, _ in tree.invalidate() }
        // Space previews the selected file, as in Finder.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            guard let selected else { return .ignored }
            QuickLookController.shared.toggle([url(selected)])
            return .handled
        }
    }

    // MARK: Header

    private func header(_ p: ClaudePalette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: repo.isLinkedWorktree ? "square.stack.3d.up" : "shippingbox").foregroundStyle(p.cyan)
                Text(repo.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                OpenInMenu(urls: [repo.root], palette: p, github: repo.github)
            }
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(p.magenta)
                Text(repo.branchLabel).lineLimit(1).truncationMode(.middle)
                if repo.status.ahead > 0 { Text("↑\(repo.status.ahead)").foregroundStyle(p.green) }
                if repo.status.behind > 0 { Text("↓\(repo.status.behind)").foregroundStyle(p.yellow) }
                Spacer(minLength: 0)
                if repo.isLinkedWorktree {
                    Text("worktree")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(p.yellow)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(p.yellow.opacity(0.14)))
                        .help(repo.mainWorktree.map { "Main checkout: \($0.path)" } ?? repo.root.path)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(p.dim)
            if let gh = repo.github {
                VStack(alignment: .leading, spacing: 3) {
                    Link(destination: gh.url) {
                        Label(gh.slug, systemImage: "arrow.up.right.square").lineLimit(1)
                    }
                    .help("Open \(gh.slug) on GitHub")
                    if let pr = repo.pullRequest {
                        Link(destination: pr.url) {
                            Label("#\(pr.number) \(pr.title)", systemImage: pr.state == .merged ? "arrow.triangle.merge" : "arrow.triangle.pull")
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .help("\(pr.title) — \(pr.isDraft ? "draft" : pr.state.rawValue.lowercased())")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(p.blue)
            }
            Picker("", selection: Binding(get: { changedOnly }, set: { SettingsStore.shared.settings.claudeExplorerChangedOnly = $0 })) {
                Text("Files").tag(false)
                Text("Changes (\(repo.status.changeCount))").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: Lists

    private func treeList(_ p: ClaudePalette) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(tree.rows) { row in
                    let st = row.entry.isDirectory ? nil : repo.status(for: row.entry.path)
                    let dirKind = row.entry.isDirectory ? repo.directoryStatus(for: row.entry.path) : nil
                    let ignored = repo.isIgnored(row.entry.path, isDirectory: row.entry.isDirectory)
                    FileRow(name: row.entry.name, detail: nil, depth: row.depth, isDirectory: row.entry.isDirectory,
                            expanded: tree.expanded.contains(row.entry.path), status: st?.kind ?? (ignored ? .ignored : nil),
                            letter: st?.letter, dirKind: dirKind, selected: selected == row.entry.path,
                            palette: p)
                        .onTapGesture(count: 2) { if !row.entry.isDirectory { open(row.entry.path) } }
                        .onTapGesture {
                            selected = row.entry.path
                            if row.entry.isDirectory { tree.toggle(row.entry.path) }
                        }
                        .contextMenu { menu(for: row.entry.path, isDirectory: row.entry.isDirectory) }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func changesList(_ p: ClaudePalette) -> some View {
        let changes = repo.status.changes
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if changes.isEmpty {
                    Text("No changes").font(.system(size: 12)).foregroundStyle(p.dim).padding(12)
                }
                ForEach(changes, id: \.path) { change in
                    let dir = (change.path as NSString).deletingLastPathComponent
                    FileRow(name: (change.path as NSString).lastPathComponent, detail: dir.isEmpty ? nil : dir, depth: 0,
                            isDirectory: change.path.hasSuffix("/"), expanded: false, status: change.status.kind,
                            letter: change.status.letter, dirKind: nil, selected: selected == change.path,
                            palette: p, staged: change.status.isStaged)
                        .onTapGesture(count: 2) { open(change.path) }
                        .onTapGesture { selected = change.path }
                        .contextMenu { menu(for: change.path, isDirectory: false) }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Actions

    private func url(_ rel: String) -> URL { repo.root.appendingPathComponent(rel) }

    private func open(_ rel: String) {
        let u = url(rel)
        guard FileManager.default.fileExists(atPath: u.path) else { return }
        if let editor = ExternalEditor.preferred {
            editor.open([u])
        } else {
            NSWorkspace.shared.open(u)
        }
    }

    @ViewBuilder
    private func menu(for rel: String, isDirectory: Bool) -> some View {
        let u = url(rel)
        if let insert = context.insert {
            Button(context.isClaude ? "Mention in Prompt" : "Insert Path") {
                insert(context.isClaude ? "@" + mentionPath(rel) + " " : shellQuoted(mentionPath(rel)) + " ")
            }
        }
        Button("Quick Look") { QuickLookController.shared.toggle([u]) }
        Divider()
        ForEach(ExternalEditor.installed) { editor in
            Button("Open in \(editor.name)") { editor.open([u]) }
        }
        if !isDirectory { Button("Open with Default App") { NSWorkspace.shared.open(u) } }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
        if let gh = repo.github, let branch = repo.status.branch, repo.isBranchPublished {
            Button("Open on GitHub") {
                NSWorkspace.shared.open(gh.url.appendingPathComponent(isDirectory ? "tree" : "blob")
                    .appendingPathComponent(branch).appendingPathComponent(rel))
            }
        }
        Divider()
        Button("Copy Path") { copy(u.path) }
        Button("Copy Relative Path") { copy(rel) }
    }

    /// Path relative to the Claude session's directory when possible.
    private func mentionPath(_ rel: String) -> String {
        let abs = url(rel).standardizedFileURL.path
        let base = URL(fileURLWithPath: context.directory).standardizedFileURL.path + "/"
        let path = abs.hasPrefix(base) ? String(abs.dropFirst(base.count)) : abs
        return path.contains(" ") ? "\"\(path)\"" : path
    }

    private func shellQuoted(_ path: String) -> String {
        let p = path.hasPrefix("\"") ? String(path.dropFirst().dropLast()) : path
        return ShellQuote.quote(p)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct FileRow: View {
    let name: String
    let detail: String?
    let depth: Int
    let isDirectory: Bool
    let expanded: Bool
    let status: GitFileStatus.Kind?
    let letter: String?
    let dirKind: GitFileStatus.Kind?
    let selected: Bool
    let palette: ClaudePalette
    var staged = false
    /// Row-local, so hovering re-renders one row instead of the whole tree.
    @State private var hovered = false

    var body: some View {
        let p = palette
        HStack(spacing: 5) {
            if isDirectory {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(p.dim)
                    .frame(width: 10)
            } else {
                Spacer().frame(width: 10)
            }
            Image(systemName: isDirectory ? (expanded ? "folder.fill" : "folder") : FileRow.icon(for: name))
                .font(.system(size: 11))
                .foregroundStyle(isDirectory ? p.blue.opacity(status == .ignored ? 0.5 : 0.9) : p.dim)
                .frame(width: 14)
            Text(name)
                .font(.system(size: 12))
                .foregroundStyle(nameColor(p))
                .strikethrough(status == .deleted)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail {
                Text(detail).font(.system(size: 10.5)).foregroundStyle(p.dim).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 2)
            if let letter, status != .ignored {
                Text(letter)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(FileRow.color(status, p))
                    .help(staged ? "Staged" : "Not staged")
                    .overlay(alignment: .bottom) {
                        if staged { Rectangle().fill(FileRow.color(status, p)).frame(height: 1).offset(y: 1) }
                    }
            } else if let dirKind, dirKind != .ignored {
                Circle().fill(FileRow.color(dirKind, p)).frame(width: 5, height: 5)
            }
        }
        .padding(.leading, 8 + CGFloat(depth) * 12)
        .padding(.trailing, 10)
        .frame(height: 22)
        .background(selected ? p.claude.opacity(0.16) : hovered ? p.raised : .clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    private func nameColor(_ p: ClaudePalette) -> Color {
        guard let status else { return p.foreground }
        if status == .ignored { return p.dim.opacity(0.8) }
        return FileRow.color(status, p)
    }

    static func color(_ kind: GitFileStatus.Kind?, _ p: ClaudePalette) -> Color {
        switch kind {
        case .modified: p.yellow
        case .added, .untracked: p.green
        case .deleted, .conflicted: p.red
        case .renamed: p.blue
        case .ignored: p.dim
        case nil: p.foreground
        }
    }

    static func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "swift", "go", "ts", "tsx", "js", "jsx", "py", "rb", "rs", "kt", "java", "c", "h", "m", "cpp", "vue", "zsh", "sh": "chevron.left.forwardslash.chevron.right"
        case "md", "txt", "rst": "doc.text"
        case "json", "yml", "yaml", "toml", "plist", "xml": "curlybraces"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "icns": "photo"
        case "lock": "lock"
        default: "doc"
        }
    }
}

/// "Open in" button: VS Code / Cursor / Sublime Text (whichever are installed) and Finder.
struct OpenInMenu: View {
    let urls: [URL]
    let palette: ClaudePalette
    var github: GitHubRemote?

    var body: some View {
        let editors = ExternalEditor.installed
        Menu {
            ForEach(editors) { editor in
                Button {
                    editor.open(urls)
                } label: {
                    Label { Text("Open in \(editor.name)") } icon: { Image(nsImage: editor.icon.resized(to: 16)) }
                }
            }
            if editors.isEmpty {
                Text("No VS Code, Cursor or Sublime Text found")
            }
            Divider()
            if let github {
                Button("Open on GitHub") { NSWorkspace.shared.open(github.url) }
            }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        } label: {
            HStack(spacing: 4) {
                if let preferred = ExternalEditor.preferred {
                    Image(nsImage: preferred.icon.resized(to: 14))
                    Text("Open")
                } else {
                    Image(systemName: "arrow.up.forward.app")
                    Text("Open")
                }
            }
            .font(.system(size: 11, weight: .medium))
        } primaryAction: {
            if let preferred = ExternalEditor.preferred { preferred.open(urls) } else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(ExternalEditor.preferred.map { "Open in \($0.name) (hold for more)" } ?? "Open")
    }
}

extension NSImage {
    func resized(to side: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: side, height: side))
        img.lockFocus()
        draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        img.unlockFocus()
        return img
    }
}
