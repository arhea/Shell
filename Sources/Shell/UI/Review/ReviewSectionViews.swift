import AppKit
import SwiftUI

/// "▾ Sources/…/StreamWriter.swift +9 −2  New file   ☐ Viewed  Open in… ▾  Revert file…"
struct ReviewFileHeader: View {
    let file: ReviewFile
    let collapsed: Bool
    let model: ReviewChangesModel
    @State private var confirmRevert = false

    var body: some View {
        HStack(spacing: 8) {
            Button { model.toggleCollapsed(file.path) } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(width: 10)
                    Text("\(Text(file.folder.isEmpty ? "" : file.folder + "/").foregroundStyle(.secondary))\(Text(file.fileName).foregroundStyle(.primary))")
                        .font(ChatTypography.current.codeFont(size: DS.Size.body))
                        .lineLimit(1).truncationMode(.head)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(collapsed ? "Expand" : "Collapse") \(file.path)")
            if file.isUntracked || file.staged?.isNew == true { Pill("New file", color: ReviewStyle.added) }
            if file.status == .deleted { Pill("Deleted", color: ReviewStyle.removed) }
            if file.additions > 0 { Text("+\(file.additions)").foregroundStyle(ReviewStyle.added) }
            if file.deletions > 0 { Text("−\(file.deletions)").foregroundStyle(ReviewStyle.removed) }
            Spacer(minLength: 8)
            Toggle("Viewed", isOn: Binding(get: { model.isViewed(file) }, set: { model.setViewed(file, $0) }))
                .toggleStyle(.checkbox)
                .font(.system(size: DS.Size.body))
            if !collapsed {
                ReviewOpenMenu(url: model.repository.root.appendingPathComponent(file.path), exists: file.status != .deleted)
                Button("Revert file…") { confirmRevert = true }
                    .buttonStyle(.labeled(.plain, compact: true))
                    .confirmationDialog("Revert all changes to \(file.fileName)?", isPresented: $confirmRevert) {
                        Button("Revert File", role: .destructive) { model.revertFile(file) }
                    } message: {
                        Text(file.isNewFile ? "The new file moves to the Trash." : "Staged and unstaged changes are discarded. This can't be undone.")
                    }
            }
        }
        .font(.system(size: DS.Size.small, weight: .medium))
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Color.primary.opacity(0.025))
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { if !collapsed { Divider() } }
    }
}

/// "Open in VS Code ▾": the preferred editor, other installed editors, the default app and Finder.
struct ReviewOpenMenu: View {
    let url: URL
    let exists: Bool

    var body: some View {
        let preferred = ExternalEditor.preferred
        Menu {
            ForEach(ExternalEditor.installed) { editor in
                Button("Open in \(editor.name)") { editor.open([url]) }
            }
            Button("Open with Default App") { NSWorkspace.shared.open(url) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } label: {
            Text(preferred.map { "Open in \($0.name)" } ?? "Open")
        } primaryAction: {
            if let preferred { preferred.open([url]) } else { NSWorkspace.shared.open(url) }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!exists)
    }
}

/// "@@ -40,7 +40,14 @@ func write(_ data: Data) throws      Stage hunk  Revert hunk"
struct ReviewHunkHeader: View {
    let ref: ReviewHunkRef
    let header: String
    let model: ReviewChangesModel

    var body: some View {
        HStack(spacing: 4) {
            Text(header)
                .font(ChatTypography.current.codeFont(size: DS.Size.small))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if model.busyHunks.contains(ref) {
                ProgressView().controlSize(.small)
            } else if ref.staged {
                Button("Unstage hunk") { model.unstageHunk(ref) }
                    .buttonStyle(.labeled(.plain, compact: true))
            } else {
                Button("Stage hunk") { model.stageHunk(ref) }
                    .buttonStyle(.labeled(.plain, compact: true))
                Button("Revert hunk") { model.revertHunk(ref) }
                    .buttonStyle(.labeled(.plain, compact: true))
                    .help("Discard this change from the working tree")
            }
        }
        .padding(.leading, 14).padding(.trailing, 8)
        .frame(height: 28)
        .background(ReviewStyle.hunkBar)
    }
}

/// "⋯ 14 unchanged lines  Expand"
struct ReviewGapRow: View {
    let count: Int
    let expand: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "ellipsis").font(.system(size: 9))
            Text("\(count) unchanged line\(count == 1 ? "" : "s")")
            Button("Expand", action: expand).buttonStyle(.link)
            Spacer(minLength: 0)
        }
        .font(.system(size: DS.Size.small))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 24)
        .background(Color.primary.opacity(0.03))
    }
}

/// The inline comment card under a line: "AR Comment on line 48".
struct ReviewCommentCard: View {
    let target: ReviewCommentTarget
    @Bindable var model: ReviewChangesModel
    let send: () -> Void
    @FocusState private var focused: Bool

    private static var initials: String {
        let parts = NSFullUserName().split(separator: " ")
        let letters = parts.prefix(2).compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "You" : letters.uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(Self.initials)
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(Color.primary.opacity(0.12), in: Circle())
                Text("Comment on line \(target.line)").font(.system(size: DS.Size.small)).foregroundStyle(.secondary)
            }
            TextField("Ask Claude about this line…", text: $model.commentText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: DS.Size.body))
                .lineLimit(2...8)
                .focused($focused)
            HStack(spacing: 8) {
                Text("Claude gets the file, line and hunk as context")
                    .font(.system(size: DS.Size.caption)).foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                Button("Cancel") { model.cancelComment() }
                    .buttonStyle(.labeled(.plain, compact: true))
                    .keyboardShortcut(.cancelAction)
                Button { send() } label: {
                    HStack(spacing: 4) { Text("Send to Claude"); Text("⌘⏎").opacity(0.75) }
                }
                .buttonStyle(.labeled(.primary, compact: true))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .cardSurface()
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .onAppear { focused = true }
    }
}

/// The strip along the right edge marking where changes are; click to jump.
struct ReviewOverviewRuler: View {
    let marks: [ReviewRows.Mark]
    let jump: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                for mark in marks {
                    let y = mark.position * size.height
                    let color: Color = switch mark.kind {
                    case .added: ReviewStyle.added
                    case .removed: ReviewStyle.removed
                    case .modified: ReviewStyle.modified
                    }
                    ctx.fill(Path(CGRect(x: 1, y: y, width: size.width - 2, height: 3)), with: .color(color.opacity(0.85)))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard geo.size.height > 0 else { return }
                jump(location.y / geo.size.height)
            }
        }
        .frame(width: 8)
        .background(Color.primary.opacity(0.03))
        .accessibilityLabel("Overview of changes")
    }
}
