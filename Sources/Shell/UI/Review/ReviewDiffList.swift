import SwiftUI

/// The right side of Review Changes: every file's diff in one lazy list, with
/// the overview ruler along the edge.
struct ReviewDiffList: View {
    @Bindable var model: ReviewChangesModel
    let onSendToClaude: (String) -> Void
    /// The visible part of the list, for the ruler. A reference, so scrolling
    /// redraws only the ruler, not the list.
    @State private var viewport = ReviewViewport()

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
                .onScrollGeometryChange(for: ClosedRange<Double>.self) { geo in
                    let height = max(geo.contentSize.height, 1)
                    let lo = min(max(geo.contentOffset.y / height, 0), 1)
                    return lo...min(max((geo.contentOffset.y + geo.containerSize.height) / height, lo), 1)
                } action: { _, range in
                    viewport.range = range
                }
                .onAppear {
                    // A load that finished before the list existed asked for a file.
                    if let id = model.scrollTarget { proxy.scrollTo(id, anchor: .top) }
                }
                .onChange(of: model.scrollToken) {
                    guard let id = model.scrollTarget else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .top) }
                }
            }
            ReviewOverviewRuler(marks: model.marks, viewport: viewport) { model.scroll(toFraction: $0) }
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
                .font(.system(size: DS.Size.small, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
        case .hunkHeader(let ref, let header):
            ReviewHunkHeader(ref: ref, header: header, model: model)
        case .line(let ref, let left, let right):
            ReviewLineRow(left: left, right: right, split: model.split, language: ReviewStyle.language(for: ref.path),
                          palette: palette, comment: model.comment?.rowID == row.id ? model.comment : nil) { line, isNew in
                model.beginComment(rowID: row.id, ref: ref, line: line, isNew: isNew)
            }
        case .gap(let id, let ref, let count):
            ReviewGapRow(count: count) { model.expandGap(id, ref) }
        case .truncated(let path, let hidden):
            HStack(spacing: 8) {
                Text("\(hidden) more line\(hidden == 1 ? "" : "s") not shown").foregroundStyle(.secondary)
                Button("Show full diff") { model.showFullDiff(path) }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.Status.selection)
                Spacer(minLength: 0)
            }
            .font(.system(size: DS.Size.subtitle))
            .padding(.horizontal, 16).frame(height: 28)
        case .note(_, let text):
            Text(text)
                .font(.system(size: DS.Size.subtitle))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 10)
        case .comment(let target):
            commentCard(target)
        case .fileEnd:
            Color.clear.frame(height: 14)
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
            // The card sits in its line's column, indented past the gutter, with
            // the column divider running through.
            HStack(spacing: 0) {
                Group {
                    if target.isNew { Color.clear } else { card }
                }
                .frame(maxWidth: .infinity)
                Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
                Group {
                    if target.isNew { card } else { Color.clear }
                }
                .frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            card.frame(maxWidth: 640 + ReviewStyle.gutterWidth * 2, alignment: .leading)
                .padding(.leading, ReviewStyle.gutterWidth)
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

/// The scrolled-to part of the diff list, as fractions of its height.
@MainActor
@Observable
final class ReviewViewport {
    var range: ClosedRange<Double> = 0...0
}
