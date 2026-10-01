import SwiftUI

/// The right side of Review Changes: every file's diff in one lazy list, with
/// the overview ruler along the edge.
struct ReviewDiffList: View {
    @Bindable var model: ReviewChangesModel
    let onSendToClaude: (String) -> Void

    var body: some View {
        let palette = ClaudePalette.current
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.rows) { row in
                            rowView(row, palette: palette)
                        }
                    }
                    .padding(.bottom, 24)
                }
                .onChange(of: model.scrollToken) {
                    guard let id = model.scrollTarget else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .top) }
                }
            }
            ReviewOverviewRuler(marks: model.marks) { model.scroll(toFraction: $0) }
        }
        .overlay {
            if model.hasLoaded, model.files.isEmpty { emptyState }
        }
    }

    @ViewBuilder
    private func rowView(_ row: ReviewRow, palette: ClaudePalette) -> some View {
        switch row.kind {
        case .fileHeader(let file, let collapsed):
            ReviewFileHeader(file: file, collapsed: collapsed, model: model)
        case .sectionLabel(_, let staged):
            Text(staged ? "Staged" : "Not staged")
                .font(.system(size: DS.Size.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 4)
        case .hunkHeader(let ref, let header):
            ReviewHunkHeader(ref: ref, header: header, model: model)
        case .line(let ref, let left, let right):
            ReviewLineRow(left: left, right: right, split: model.split, language: ReviewStyle.language(for: ref.path),
                          palette: palette) { line, isNew in
                model.beginComment(rowID: row.id, ref: ref, line: line, isNew: isNew)
            }
        case .gap(let id, let ref, let count):
            ReviewGapRow(count: count) { model.expandGap(id, ref) }
        case .truncated(let path, let hidden):
            HStack(spacing: 8) {
                Text("\(hidden) more line\(hidden == 1 ? "" : "s") not shown").foregroundStyle(.secondary)
                Button("Show full diff") { model.showFullDiff(path) }.buttonStyle(.link)
                Spacer(minLength: 0)
            }
            .font(.system(size: DS.Size.small))
            .padding(.horizontal, 14).frame(height: 28)
        case .note(_, let text):
            Text(text)
                .font(.system(size: DS.Size.small))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 10)
        case .comment(let target):
            commentCard(target)
        case .fileEnd:
            Color.clear.frame(height: 10)
        }
    }

    @ViewBuilder
    private func commentCard(_ target: ReviewCommentTarget) -> some View {
        let card = ReviewCommentCard(target: target, model: model) {
            guard let message = model.commentMessage() else { return }
            onSendToClaude(message)
            model.cancelComment()
        }
        if model.split {
            HStack(spacing: 0) {
                if target.isNew { Spacer(minLength: 0).frame(maxWidth: .infinity) }
                card.frame(maxWidth: .infinity)
                if !target.isNew { Spacer(minLength: 0).frame(maxWidth: .infinity) }
            }
        } else {
            card.frame(maxWidth: 640, alignment: .leading).padding(.leading, ReviewStyle.gutterWidth * 2)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle").font(.system(size: 28)).foregroundStyle(.tertiary)
            Text("No changes").font(.system(size: DS.Size.title, weight: .semibold))
            Text("The working tree matches HEAD.").font(.system(size: DS.Size.small)).foregroundStyle(.secondary)
        }
    }
}
