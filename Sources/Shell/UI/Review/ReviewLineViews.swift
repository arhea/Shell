import AppKit
import SwiftUI

/// Colors and fonts for Review Changes. Status colors are system colors, so
/// they match the rest of the chrome; syntax colors follow the terminal theme.
enum ReviewStyle {
    static let added = Color(nsColor: .systemGreen)
    static let removed = Color(nsColor: .systemRed)
    static let modified = Color(nsColor: .systemOrange)
    static let hunkBar = Color(nsColor: .systemBlue).opacity(0.07)
    static let gutterWidth: CGFloat = 46
    static let codeSize: CGFloat = 12

    @MainActor static var codeFont: Font { ChatTypography.current.codeFont(size: codeSize) }

    static func background(_ kind: UnifiedDiffLine.Kind) -> Color {
        switch kind {
        case .added: added.opacity(0.12)
        case .removed: removed.opacity(0.11)
        case .context: .clear
        }
    }

    static func color(_ status: ReviewFile.Status) -> Color {
        switch status {
        case .modified: modified
        case .added: added
        case .deleted: removed
        }
    }

    /// Highlighted code with the changed part of a paired line marked.
    @MainActor
    static func attributed(_ cell: ReviewCell, language: String, palette: ClaudePalette) -> AttributedString {
        let text = cell.text.hasSuffix("\r") ? String(cell.text.dropLast()) : cell.text
        var s = AttributedString(text.isEmpty ? " " : text)
        if text.count < 2000 {
            for (range, token) in CodeHighlighter.tokens(in: text, language: language) {
                guard let lo = AttributedString.Index(range.lowerBound, within: s),
                      let hi = AttributedString.Index(range.upperBound, within: s) else { continue }
                s[lo..<hi].foregroundColor = CodeHighlighter.color(token, palette)
            }
        }
        if let change = cell.change, change.upperBound <= text.count {
            let chars = s.characters
            let lo = chars.index(chars.startIndex, offsetBy: change.lowerBound)
            let hi = chars.index(chars.startIndex, offsetBy: change.upperBound)
            s[lo..<hi].backgroundColor = (cell.kind == .added ? added : removed).opacity(0.32)
        }
        return s
    }

    /// The highlighter's language key from a file name.
    static func language(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == "makefile" { return "make" }
        if name == "dockerfile" { return "dockerfile" }
        return ext
    }
}

/// Diagonal stripes for the empty side of a split row.
struct HatchPattern: View {
    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 12
            }
            ctx.stroke(path, with: .color(Color.primary.opacity(0.05)), lineWidth: 5)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// A line number; hovering shows "+", clicking starts a comment on the line.
struct ReviewGutter: View {
    let number: Int?
    var onComment: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Text(number.map(String.init) ?? "")
                .font(ReviewStyle.codeFont)
                .foregroundStyle(.tertiary)
                .padding(.trailing, 8)
            if hovering, number != nil, onComment != nil {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 15, height: 15)
                    .background(DS.Status.selection, in: RoundedRectangle(cornerRadius: 3))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 2)
            }
        }
        .frame(width: ReviewStyle.gutterWidth, alignment: .trailing)
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if number != nil { onComment?() } }
        .help(number == nil || onComment == nil ? "" : "Comment on this line")
        .accessibilityLabel(number.map { "Line \($0)" } ?? "")
        .accessibilityAddTraits(onComment == nil ? [] : .isButton)
    }
}

/// One code line: gutter(s), +/− marker and highlighted text.
struct ReviewCodeCell: View {
    let cell: ReviewCell?
    /// Split: the left (old) side. Ignored when `unified`.
    var left = false
    var unified = false
    let language: String
    let palette: ClaudePalette
    var onComment: ((Int, Bool) -> Void)?

    var body: some View {
        if let cell {
            HStack(alignment: .top, spacing: 0) {
                if unified {
                    ReviewGutter(number: cell.oldNumber, onComment: comment(cell.oldNumber, isNew: false, cell))
                    ReviewGutter(number: cell.newNumber, onComment: comment(cell.newNumber, isNew: true, cell))
                } else {
                    let n = cell.number(left: left)
                    ReviewGutter(number: n, onComment: comment(n, isNew: !left, cell))
                }
                Text(cell.kind == .added ? "+" : cell.kind == .removed ? "−" : " ")
                    .font(ReviewStyle.codeFont)
                    .foregroundStyle(cell.kind == .added ? ReviewStyle.added : ReviewStyle.removed)
                    .frame(width: 12)
                Text(ReviewStyle.attributed(cell, language: language, palette: palette))
                    .font(ReviewStyle.codeFont)
                    .foregroundStyle(cell.kind == .context ? Color.primary.opacity(0.78) : Color.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 8)
            }
            .padding(.vertical, 1.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ReviewStyle.background(cell.kind))
        } else {
            HatchPattern().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func comment(_ number: Int?, isNew: Bool, _ cell: ReviewCell) -> (() -> Void)? {
        guard let number, let onComment else { return nil }
        return { onComment(number, isNew) }
    }
}

/// A diff line row: two cells side by side, or one unified cell.
struct ReviewLineRow: View {
    let left: ReviewCell?
    let right: ReviewCell?
    let split: Bool
    let language: String
    let palette: ClaudePalette
    let onComment: (Int, Bool) -> Void

    var body: some View {
        if split {
            HStack(alignment: .top, spacing: 0) {
                ReviewCodeCell(cell: left, left: true, language: language, palette: palette, onComment: onComment)
                Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
                ReviewCodeCell(cell: right, left: false, language: language, palette: palette, onComment: onComment)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            ReviewCodeCell(cell: left, unified: true, language: language, palette: palette, onComment: onComment)
        }
    }
}
