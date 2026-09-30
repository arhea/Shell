import AppKit
import CoreImage
import SwiftUI

/// A file edit as a git-style diff: side by side (old | new) when there's
/// room, else unified. Settings › Claude & Codex › Edit diffs.
struct DiffView: View {
    let lines: [ClaudeToolFormat.DiffLine]
    let palette: ClaudePalette
    let fontSize: CGFloat
    var collapsedLimit: Int?

    /// Below this width side by side becomes unified.
    static let sideBySideMinWidth: CGFloat = 640
    @State private var width: CGFloat = 0

    var body: some View {
        let style = ChatPreferences.shared.diffStyle
        // A new file has nothing on the left.
        let canSplit = lines.contains { $0.kind == .removed || $0.kind == .context }
        let split = canSplit && (style == .sideBySide || (style == .automatic && width >= Self.sideBySideMinWidth))
        VStack(alignment: .leading, spacing: 0) {
            if split {
                SideBySideDiff(rows: shownRows, palette: palette, font: font)
            } else {
                UnifiedDiff(lines: shownLines, palette: palette, font: font, minWidth: width)
            }
            if let limit = collapsedLimit, lines.count > limit {
                Text("… \(lines.count - limit) more lines").font(.system(size: 10)).foregroundStyle(palette.dim).padding(6)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.surface))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.border.opacity(0.6)))
    }

    private var font: Font { ChatTypography.current.codeFont(size: fontSize) }
    private var shownLines: [ClaudeToolFormat.DiffLine] { collapsedLimit.map { Array(lines.prefix($0)) } ?? lines }
    private var shownRows: [ClaudeDiff.Row] {
        // Pair only what's shown: a collapsed diff shouldn't pay for every line.
        let rows = ClaudeDiff.rows(shownLines)
        return collapsedLimit.map { Array(rows.prefix($0)) } ?? rows
    }
}

/// One column: `−`/`+` lines with old and new line numbers.
private struct UnifiedDiff: View {
    let lines: [ClaudeDiff.Line]
    let palette: ClaudePalette
    let font: Font
    /// Rows stretch to at least the pane's width so their colors reach the edge.
    var minWidth: CGFloat = 0

    var body: some View {
        let rows = ClaudeDiff.rows(lines)
        // Word-level highlights come from the side-by-side pairing.
        var changes: [ClaudeDiff.Line: Range<Int>] = [:]
        for r in rows {
            if let l = r.left, let c = r.leftChange { changes[l] = c }
            if let rt = r.right, let c = r.rightChange { changes[rt] = c }
        }
        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    if line.kind == .gap {
                        DiffGapRow(text: line.text, palette: palette, font: font)
                    } else {
                        HStack(spacing: 0) {
                            DiffGutter(number: line.oldNumber, palette: palette, font: font)
                            DiffGutter(number: line.newNumber, palette: palette, font: font)
                            Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                                .foregroundStyle(line.kind == .added ? palette.green : palette.red)
                                .frame(width: 14)
                            DiffText(line: line, change: changes[line], palette: palette, font: font)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DiffColors.background(line.kind, palette))
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: minWidth, alignment: .leading)
        }
    }
}

/// Old on the left, new on the right; changed lines paired row by row.
private struct SideBySideDiff: View {
    let rows: [ClaudeDiff.Row]
    let palette: ClaudePalette
    let font: Font

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                if row.left?.kind == .gap {
                    DiffGapRow(text: row.left?.text ?? "", palette: palette, font: font)
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        cell(row.left, change: row.leftChange, number: row.left?.oldNumber)
                        palette.border.frame(width: 1)
                        cell(row.right, change: row.rightChange, number: row.right?.newNumber)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ line: ClaudeDiff.Line?, change: Range<Int>?, number: Int?) -> some View {
        HStack(alignment: .top, spacing: 0) {
            DiffGutter(number: number, palette: palette, font: font)
            if let line {
                Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                    .foregroundStyle(line.kind == .added ? palette.green : palette.red)
                    .frame(width: 14)
                DiffText(line: line, change: change, palette: palette, font: font)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(line.map { DiffColors.background($0.kind, palette) } ?? palette.raised.opacity(0.5))
    }
}

private enum DiffColors {
    static func background(_ kind: ClaudeDiff.Line.Kind, _ p: ClaudePalette) -> Color {
        switch kind {
        case .added: p.green.opacity(0.12)
        case .removed: p.red.opacity(0.12)
        case .context, .gap: .clear
        }
    }
}

private struct DiffGutter: View {
    let number: Int?
    let palette: ClaudePalette
    let font: Font

    var body: some View {
        Text(number.map(String.init) ?? "")
            .font(font)
            .foregroundStyle(palette.dim.opacity(0.8))
            .frame(minWidth: 34, alignment: .trailing)
            .padding(.trailing, 6)
    }
}

/// A line of code with its changed part (if paired) highlighted.
private struct DiffText: View {
    let line: ClaudeDiff.Line
    let change: Range<Int>?
    let palette: ClaudePalette
    let font: Font

    var body: some View {
        Text(attributed)
            .font(font)
            .foregroundStyle(line.kind == .context ? palette.foreground.opacity(0.75) : palette.foreground)
            .textSelection(.enabled)
            .padding(.trailing, 8)
    }

    private var attributed: AttributedString {
        var s = AttributedString(line.text.isEmpty ? " " : line.text)
        if let change, change.upperBound <= line.text.count {
            let chars = s.characters
            let lower = chars.index(chars.startIndex, offsetBy: change.lowerBound)
            let upper = chars.index(chars.startIndex, offsetBy: change.upperBound)
            s[lower..<upper].backgroundColor = (line.kind == .added ? palette.green : palette.red).opacity(0.35)
        }
        return s
    }
}

private struct DiffGapRow: View {
    let text: String
    let palette: ClaudePalette
    let font: Font

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "ellipsis").font(.system(size: 9))
            if !text.isEmpty { Text(text) }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(palette.dim)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.raised.opacity(0.6))
    }
}
