import AppKit
import CoreImage
import SwiftUI

// MARK: - Prompts

struct PermissionCard: View {
    let request: ClaudePermissionRequest
    let palette: ClaudePalette
    let fontSize: CGFloat
    var showsKeyHint = true
    var onDecide: (_ allow: Bool, _ always: Bool) -> Void

    var body: some View {
        let p = palette
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: ClaudeToolFormat.symbol(request.toolName)).foregroundStyle(p.yellow)
                Text("Allow \(ClaudeToolFormat.displayName(request.displayName))?").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            if let d = request.description, !d.isEmpty,
               !(request.input["file_path"] as? String).map({ d.contains(ClaudeToolFormat.shortPath($0)) || d.contains($0) }).isTrue {
                Text(d).font(.system(size: 12)).foregroundStyle(p.dim)
            }
            detail(p)
            if let reason = request.reason, !reason.isEmpty {
                Text(reason).font(.system(size: 11)).foregroundStyle(p.dim)
            }
            HStack(spacing: 8) {
                Button { onDecide(true, false) } label: { Text("1  Allow").frame(minWidth: 70) }
                    .buttonStyle(.borderedProminent).tint(p.claude)
                if !request.suggestions.isEmpty {
                    Button { onDecide(true, true) } label: { Text("2  Always allow") }
                        .help("Allow and add Claude Code's suggested permission rule")
                }
                Button { onDecide(false, false) } label: { Text("\(request.suggestions.isEmpty ? 2 : 3)  Deny") }
                Spacer()
                if showsKeyHint { Text("Return allows · Esc denies").font(.system(size: 10)).foregroundStyle(p.dim) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(p.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(p.yellow.opacity(0.6), lineWidth: 1))
    }

    @ViewBuilder
    private func detail(_ p: ClaudePalette) -> some View {
        if let diff = ClaudeToolFormat.diff(name: request.toolName, input: request.input) {
            if let path = request.input["file_path"] as? String {
                Text(ClaudeToolFormat.shortPath(path)).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.blue)
            }
            ScrollView { DiffView(lines: diff, palette: p, fontSize: fontSize - 2) }.frame(maxHeight: 220)
        } else {
            let text = request.toolName == "Bash" ? (request.input["command"] as? String ?? "") : ClaudeToolFormat.summary(name: request.toolName, input: request.input)
            if !text.isEmpty {
                ScrollView {
                    Text(request.toolName == "Bash" ? CodeHighlighter.attributed(text, language: "sh", palette: p) : AttributedString(text))
                        .font(.system(size: fontSize - 1, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 6).fill(p.raised))
            }
        }
    }
}

/// Claude's AskUserQuestion prompt: pick an option, several for
/// multi-select questions, or type your own answer under "Other".
struct QuestionCard: View {
    let request: ClaudePermissionRequest
    let palette: ClaudePalette
    let fontSize: CGFloat
    var directory: String?
    var onAnswer: ([String: String]) -> Void
    var onDeny: () -> Void
    @State private var choices: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]
    @State private var hovered: [String: String] = [:]

    var body: some View {
        let p = palette
        let questions = request.questions
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble").foregroundStyle(p.claude)
                Text(questions.count == 1 ? "Claude has a question" : "Claude has \(questions.count) questions")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(p.dim)
                Spacer()
            }
            ForEach(questions) { q in question(q) }
            HStack(spacing: 8) {
                Button("Submit") { onAnswer(answers(questions)) }
                    .buttonStyle(.borderedProminent).tint(p.claude)
                    .disabled(!questions.allSatisfy { !answer(for: $0).isEmpty })
                Button("Skip") { onDeny() }
                Spacer()
                Text(hint(questions)).font(.system(size: 10)).foregroundStyle(p.dim)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(p.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(p.claude.opacity(0.5), lineWidth: 1))
    }

    private func question(_ q: ClaudeQuestion) -> some View {
        let p = palette
        let preview = previewText(q)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if !q.header.isEmpty { QuestionHeaderChip(text: q.header, palette: p) }
                Text(InlineMarkdown.attributed(q.question, palette: p, directory: directory))
                    .font(.system(size: fontSize, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if q.multiSelect {
                Text("Select all that apply").font(.system(size: 10.5)).foregroundStyle(p.dim)
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(q.options.enumerated()), id: \.offset) { i, o in
                        optionRow(q, index: i, option: o)
                    }
                    otherRow(q)
                }
                .frame(maxWidth: preview == nil ? .infinity : 340, alignment: .leading)
                if let preview {
                    ScrollView([.vertical, .horizontal]) {
                        Text(preview)
                            .font(.system(size: fontSize - 2, design: .monospaced))
                            .foregroundStyle(p.foreground)
                            .textSelection(.enabled)
                            .fixedSize()
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: 240, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(p.raised))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(p.border, lineWidth: 0.5))
                }
            }
        }
    }

    private func optionRow(_ q: ClaudeQuestion, index: Int, option o: ClaudeQuestion.Option) -> some View {
        let p = palette
        let selected = choices[q.id]?.contains(o.label) == true
        return Button { toggle(q, o.label) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: selectionSymbol(q, selected))
                    .foregroundStyle(selected ? p.claude : p.dim)
                VStack(alignment: .leading, spacing: 1) {
                    Text(InlineMarkdown.attributed("\(index + 1). " + o.label, palette: p, directory: directory))
                        .font(.system(size: fontSize - 1, weight: .medium))
                    if !o.description.isEmpty {
                        Text(InlineMarkdown.attributed(o.description, palette: p, directory: directory))
                            .font(.system(size: fontSize - 2)).foregroundStyle(p.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? p.claude.opacity(0.1) : hovered[q.id] == o.label ? p.raised : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered[q.id] = o.label } else if hovered[q.id] == o.label { hovered[q.id] = nil }
        }
    }

    private func otherRow(_ q: ClaudeQuestion) -> some View {
        let p = palette
        let text = other[q.id] ?? ""
        let on = !text.trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: selectionSymbol(q, on)).foregroundStyle(on ? p.claude : p.dim)
            TextField("Other — type your own answer", text: Binding(
                get: { other[q.id] ?? "" },
                set: { value in
                    other[q.id] = value
                    // A typed answer replaces the choice in single-select questions.
                    if !q.multiSelect, !value.trimmingCharacters(in: .whitespaces).isEmpty { choices[q.id] = [] }
                }))
                .textFieldStyle(.plain)
                .font(.system(size: fontSize - 1))
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(on ? p.claude.opacity(0.1) : .clear))
    }

    private func selectionSymbol(_ q: ClaudeQuestion, _ selected: Bool) -> String {
        q.multiSelect ? (selected ? "checkmark.square.fill" : "square") : (selected ? "largecircle.fill.circle" : "circle")
    }

    private func toggle(_ q: ClaudeQuestion, _ label: String) {
        var set = choices[q.id] ?? []
        if q.multiSelect {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = [label]
            other[q.id] = ""
        }
        choices[q.id] = set
    }

    /// The highlighted option's preview, else the chosen one's, else the first.
    private func previewText(_ q: ClaudeQuestion) -> String? {
        guard q.options.contains(where: { $0.preview != nil }) else { return nil }
        if let h = hovered[q.id], let preview = q.options.first(where: { $0.label == h })?.preview { return preview }
        if let chosen = q.options.first(where: { choices[q.id]?.contains($0.label) == true && $0.preview != nil }) { return chosen.preview }
        return q.options.first { $0.preview != nil }?.preview
    }

    private func answer(for q: ClaudeQuestion) -> String {
        var parts = q.options.map(\.label).filter { choices[q.id]?.contains($0) == true }
        let typed = (other[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { parts.append(typed) }
        return parts.joined(separator: ", ")
    }

    private func answers(_ questions: [ClaudeQuestion]) -> [String: String] {
        Dictionary(questions.map { ($0.question, answer(for: $0)) }, uniquingKeysWith: { a, _ in a })
    }

    private func hint(_ questions: [ClaudeQuestion]) -> String {
        guard questions.count == 1, let q = questions.first else { return "Esc skips" }
        return q.multiSelect ? "Type an answer and Return · Esc skips"
            : "1–\(q.options.count) chooses · type an answer and Return · Esc skips"
    }
}

struct QuestionHeaderChip: View {
    let text: String
    let palette: ClaudePalette

    var body: some View {
        Text(text).font(.system(size: 10, weight: .bold)).foregroundStyle(palette.claude)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(palette.claude.opacity(0.14)))
            .fixedSize()
    }
}

/// ExitPlanMode: Claude's plan, rendered as markdown, waiting for approval.
struct PlanCard: View {
    let request: ClaudePermissionRequest
    let palette: ClaudePalette
    let fontSize: CGFloat
    var directory: String?
    /// The mode to continue in, or nil to keep planning.
    var onDecide: (ClaudePermissionMode?) -> Void

    var body: some View {
        let p = palette
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.clipboard").foregroundStyle(p.cyan)
                Text("Ready to code? Review Claude's plan").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            ScrollView {
                MarkdownView(text: request.plan, palette: p, fontSize: fontSize - 0.5, directory: directory)
                    .padding(10)
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 6).fill(p.raised))
            HStack(spacing: 8) {
                Button { onDecide(.acceptEdits) } label: { Text("1  Yes, auto-accept edits") }
                    .buttonStyle(.borderedProminent).tint(p.claude)
                Button { onDecide(.default) } label: { Text("2  Yes, ask before edits") }
                Button { onDecide(nil) } label: { Text("3  Keep planning") }
                Spacer()
                Text("Type feedback and Return to keep planning").font(.system(size: 10)).foregroundStyle(p.dim)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(p.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(p.cyan.opacity(0.6), lineWidth: 1))
    }
}
