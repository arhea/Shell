import AppKit
import SwiftUI

/// "▾ Sources/…/StreamWriter.swift +9 −2  New file   ☐ Viewed  Open in… ▾  Revert file…"
struct ReviewFileHeader: View {
    let file: ReviewFile
    let collapsed: Bool
    let model: ReviewChangesModel
    @State private var confirmRevert = false

    var body: some View {
        let code = ChatTypography.current
        HStack(spacing: 10) {
            Button { model.toggleCollapsed(file.path) } label: {
                HStack(spacing: 10) {
                    Image(systemName: collapsed ? "arrowtriangle.right.fill" : "arrowtriangle.down.fill")
                        .font(.system(size: 7)).foregroundStyle(.secondary).frame(width: 8)
                    Text("\(Text(file.folder.isEmpty ? "" : file.folder + "/").foregroundStyle(.tertiary))\(Text(file.fileName).foregroundStyle(.primary))")
                        .font(code.codeFont(size: ReviewStyle.codeSize))
                        .lineLimit(1).truncationMode(.head)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(collapsed ? "Expand" : "Collapse") \(file.path)")
            if file.isUntracked || file.staged?.isNew == true { Pill("New file", color: ReviewStyle.added) }
            if file.status == .deleted { Pill("Deleted", color: ReviewStyle.removed) }
            HStack(spacing: 6) {
                if file.additions > 0 { Text("+\(file.additions)").foregroundStyle(ReviewStyle.added) }
                if file.deletions > 0 { Text("−\(file.deletions)").foregroundStyle(ReviewStyle.removed) }
            }
            .font(code.codeFont(size: DS.Size.subtitle))
            Spacer(minLength: 8)
            Toggle("Viewed", isOn: Binding(get: { model.isViewed(file) }, set: { model.setViewed(file, $0) }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if !collapsed {
                ReviewOpenMenu(url: model.repository.root.appendingPathComponent(file.path), exists: file.status != .deleted)
                Button("Revert file…") { confirmRevert = true }
                    .buttonStyle(.labeled(.plain, compact: true))
                    .font(.system(size: 12))
                    .confirmationDialog("Revert all changes to \(file.fileName)?", isPresented: $confirmRevert) {
                        Button("Revert File", role: .destructive) { model.revertFile(file) }
                    } message: {
                        Text(file.isNewFile ? "The new file moves to the Trash." : "Staged and unstaged changes are discarded. This can't be undone.")
                    }
            }
        }
        .padding(.leading, 16).padding(.trailing, 12)
        .frame(height: 42)
        .background(ClaudePalette.current.surface)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5) }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5) }
    }
}

/// "Open in Xcode ▾": the preferred editor, other installed editors, the default app and Finder.
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
        .controlSize(.small)
        .fixedSize()
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: DS.Radius.control))
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
            let parts = Self.split(header)
            HStack(spacing: 10) {
                Text(parts.range).foregroundStyle(ReviewStyle.hunkRange)
                if !parts.section.isEmpty { Text(parts.section).foregroundStyle(.secondary) }
            }
            .font(ChatTypography.current.codeFont(size: DS.Size.subtitle))
            .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Group {
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
            .font(.system(size: DS.Size.subtitle))
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 16).padding(.trailing, 8)
        .frame(height: 30)
        .background(ReviewStyle.hunkBar)
    }

    /// "@@ -1,2 +1,3 @@ func f()" → ("@@ -1,2 +1,3 @@", "func f()").
    static func split(_ header: String) -> (range: String, section: String) {
        guard header.hasPrefix("@@"), let end = header.range(of: "@@", range: header.index(header.startIndex, offsetBy: 2)..<header.endIndex)
        else { return (header, "") }
        return (String(header[..<end.upperBound]), header[end.upperBound...].trimmingCharacters(in: .whitespaces))
    }
}

/// "⋯ 14 unchanged lines  Expand"
struct ReviewGapRow: View {
    let count: Int
    let expand: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("⋯ \(count) unchanged line\(count == 1 ? "" : "s")").foregroundStyle(.tertiary)
            Button("Expand", action: expand)
                .buttonStyle(.plain)
                .foregroundStyle(DS.Status.selection)
            Spacer(minLength: 0)
        }
        .font(.system(size: DS.Size.subtitle))
        .padding(.horizontal, 16)
        .frame(height: 28)
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
            HStack(spacing: 8) {
                Text(Self.initials)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 18, height: 18)
                    .background(Color.primary.opacity(0.16), in: Circle())
                Text("Comment on line \(target.line)").foregroundStyle(.secondary)
            }
            .font(.system(size: DS.Size.subtitle))
            TextField("Ask Claude about this line…", text: $model.commentText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: DS.Size.title))
                .lineSpacing(4)
                .lineLimit(2...8)
                .focused($focused)
            HStack(spacing: 6) {
                Text("Claude gets the file, line and hunk as context")
                    .font(.system(size: DS.Size.small)).foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                Button("Cancel") { model.cancelComment() }
                    .buttonStyle(.labeled(.plain, compact: true))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button { send() } label: {
                    HStack(spacing: 6) { Text("Send to Claude"); Text("⌘⏎").opacity(0.8) }
                }
                .buttonStyle(.labeled(.primary, compact: true))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(ClaudePalette.current.raised, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(ClaudePalette.current.isDark ? 0.3 : 0.12), radius: 9, y: 6)
        .padding(.leading, 48).padding(.trailing, 16).padding(.top, 8).padding(.bottom, 10)
        .onAppear { focused = true }
    }
}

/// The strip along the right edge marking where changes are, with the visible
/// part shaded; click to jump.
struct ReviewOverviewRuler: View {
    let marks: [ReviewRows.Mark]
    let viewport: ReviewViewport
    let jump: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    for mark in marks {
                        let y = mark.position * size.height
                        let h = max(mark.length * size.height, 2)
                        let rect = CGRect(x: 2, y: y, width: size.width - 4, height: h)
                        switch mark.kind {
                        case .added: ctx.fill(Path(rect), with: .color(ReviewStyle.added.opacity(0.7)))
                        case .removed: ctx.fill(Path(rect), with: .color(ReviewStyle.removed.opacity(0.7)))
                        case .modified:
                            // An edited line: the old (red) above the new (green).
                            let top = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h / 2)
                            ctx.fill(Path(top), with: .color(ReviewStyle.removed.opacity(0.7)))
                            ctx.fill(Path(top.offsetBy(dx: 0, dy: h / 2)), with: .color(ReviewStyle.added.opacity(0.7)))
                        }
                    }
                }
                ReviewViewportThumb(viewport: viewport, height: geo.size.height)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard geo.size.height > 0 else { return }
                jump(location.y / geo.size.height)
            }
        }
        .frame(width: 10)
        .background(Color.primary.opacity(0.025))
        .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.06)).frame(width: 0.5) }
        .accessibilityLabel("Overview of changes")
    }
}

/// The shaded visible range on the ruler. Its own view, so scrolling only
/// redraws this.
private struct ReviewViewportThumb: View {
    let viewport: ReviewViewport
    let height: CGFloat

    var body: some View {
        let r = viewport.range
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: max(CGFloat(r.upperBound - r.lowerBound) * height, 0))
            .offset(y: CGFloat(r.lowerBound) * height)
            .allowsHitTesting(false)
    }
}
