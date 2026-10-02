import AppKit
import CoreImage
import SwiftUI

// MARK: - Shared

/// The yellow "needs you" card every prompt uses.
private struct PromptCardChrome: ViewModifier {
    let palette: ClaudePalette

    func body(content: Content) -> some View {
        content
            // The tint sits over the background (it used to sit behind an opaque fill and never showed).
            .background {
                RoundedRectangle(cornerRadius: 12).fill(palette.background)
                    .overlay(RoundedRectangle(cornerRadius: 12).fill(DS.Status.needsYou.opacity(palette.isDark ? 0.08 : 0.1)))
            }
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.Status.needsYou.opacity(0.35), lineWidth: 1))
    }
}

private extension View {
    func promptCard(_ palette: ClaudePalette) -> some View { modifier(PromptCardChrome(palette: palette)) }
}

/// "!" in a yellow disc, then the card's title.
private struct PromptHeader<Trailing: View>: View {
    let title: String
    let fontSize: CGFloat
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Text("!")
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(Color.black.opacity(0.85))
                .frame(width: 18, height: 18)
                .background(DS.Status.needsYou, in: Circle())
                .accessibilityHidden(true)
            Text(title).font(.system(size: fontSize + 0.5, weight: .semibold))
            Spacer(minLength: 6)
            trailing
        }
    }
}

/// A numbered, full-width choice: "1  Allow once  ⏎". The first is
/// highlighted, as Return picks it.
struct PromptChoiceRow: View {
    let number: Int
    let title: Text
    var trailing: String?
    var selected = false
    let palette: ClaudePalette
    let fontSize: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? Color.white : palette.foreground.opacity(0.8))
                    .frame(width: 18, height: 18)
                    .background(selected ? Color.white.opacity(0.22) : palette.foreground.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                title
                    .font(.system(size: fontSize, weight: selected ? .medium : .regular))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let trailing {
                    Text(trailing).font(.system(size: fontSize - 1.5)).foregroundStyle(selected ? Color.white.opacity(0.85) : palette.dim)
                }
            }
            .foregroundStyle(selected ? Color.white : palette.foreground)
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(selected ? DS.Status.selection : hovering ? palette.foreground.opacity(0.07) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Permission

struct PermissionCard: View {
    let request: ClaudePermissionRequest
    let palette: ClaudePalette
    let fontSize: CGFloat
    var showsKeyHint = true
    var onDecide: (_ allow: Bool, _ always: Bool) -> Void

    var body: some View {
        let p = palette
        let size = fontSize - 0.5
        VStack(alignment: .leading, spacing: 0) {
            PromptHeader(title: Self.title(request), fontSize: fontSize) {
                ToolChip(name: ClaudeToolFormat.displayName(request.displayName), palette: p)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            detail(p)
                .padding(.horizontal, 14)
            if let explanation {
                Text(explanation)
                    .font(.system(size: fontSize - 1))
                    .foregroundStyle(p.foreground.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.top, 8)
            }
            VStack(spacing: 4) {
                PromptChoiceRow(number: 1, title: Text("Allow once"), trailing: showsKeyHint ? "⏎" : nil, selected: true,
                                palette: p, fontSize: size) { onDecide(true, false) }
                if !request.suggestions.isEmpty {
                    PromptChoiceRow(number: 2, title: Self.alwaysTitle(request.suggestions, palette: p), palette: p, fontSize: size) {
                        onDecide(true, true)
                    }
                    .help("Allow, and add Claude Code's suggested permission rule")
                }
                PromptChoiceRow(number: request.suggestions.isEmpty ? 2 : 3, title: Text("Deny, and tell Claude what to do instead"),
                                trailing: showsKeyHint ? "esc" : nil, palette: p, fontSize: size) { onDecide(false, false) }
                    .help("Type instructions in the composer first to send them with the denial")
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 10)
        }
        .promptCard(p)
    }

    /// The description and the reason it's asking, without one that only
    /// repeats the file path.
    private var explanation: String? {
        var parts: [String] = []
        if let d = request.description, !d.isEmpty,
           !(request.input["file_path"] as? String).map({ d.contains(ClaudeToolFormat.shortPath($0)) || d.contains($0) }).isTrue {
            parts.append(d)
        }
        if let reason = request.reason, !reason.isEmpty { parts.append(reason) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    static func title(_ request: ClaudePermissionRequest) -> String {
        let file = (request.input["file_path"] as? String).map { ($0 as NSString).lastPathComponent }
        switch request.toolName {
        case "Bash": return "Claude wants to run a command"
        case "Edit", "MultiEdit", "NotebookEdit": return "Claude wants to edit " + (file ?? "a file")
        case "Write": return "Claude wants to write " + (file ?? "a file")
        case "Read": return "Claude wants to read " + (file ?? "a file")
        case "WebFetch": return "Claude wants to fetch a page"
        case "WebSearch": return "Claude wants to search the web"
        default: return "Claude wants to use " + ClaudeToolFormat.displayName(request.displayName)
        }
    }

    /// "Always allow `gh pr merge` in this repo", from Claude Code's suggested rule.
    static func alwaysTitle(_ suggestions: [Any], palette: ClaudePalette) -> Text {
        let (lead, code, tail) = alwaysParts(suggestions)
        var text = AttributedString(lead)
        if let code {
            var c = AttributedString(code)
            c.font = .system(size: 12, design: .monospaced)
            text += AttributedString(" ") + c
        }
        if !tail.isEmpty { text += AttributedString(" " + tail) }
        return Text(text)
    }

    static func alwaysParts(_ suggestions: [Any]) -> (lead: String, code: String?, tail: String) {
        for case let s as [String: Any] in suggestions {
            let scope: String
            switch s["destination"] as? String {
            case "userSettings": scope = "everywhere"
            case "session": scope = "this session"
            case "localSettings", "projectSettings": scope = "in this repo"
            default: scope = ""
            }
            switch s["type"] as? String {
            case "addRules", "replaceRules":
                let rules = (s["rules"] as? [[String: Any]] ?? [])
                if let rule = rules.first {
                    let content = (rule["ruleContent"] as? String).map { $0.replacingOccurrences(of: ":*", with: "") }
                    let tool = rule["toolName"] as? String ?? ""
                    return ("Always allow", content.flatMap { $0.isEmpty ? nil : $0 } ?? ClaudeToolFormat.displayName(tool),
                            scope == "this session" ? "for this session" : scope)
                }
            case "setMode":
                if s["mode"] as? String == "acceptEdits" { return ("Allow all edits", nil, scope == "this session" ? "during this session" : scope) }
            case "addDirectories":
                if let dir = (s["directories"] as? [String])?.first {
                    return ("Always allow access to", ClaudeToolFormat.shortPath(dir), scope == "this session" ? "for this session" : scope)
                }
            default:
                continue
            }
        }
        return ("Always allow", nil, "")
    }

    @ViewBuilder
    private func detail(_ p: ClaudePalette) -> some View {
        if let diff = ClaudeToolFormat.diff(name: request.toolName, input: request.input) {
            VStack(alignment: .leading, spacing: 6) {
                if let path = request.input["file_path"] as? String {
                    Text(ClaudePathText.attributed(path, directory: nil, palette: p))
                        .font(.system(size: 11, design: .monospaced))
                }
                ScrollView { DiffView(lines: diff, palette: p, fontSize: fontSize - 2) }.frame(maxHeight: 220)
            }
        } else {
            let text = request.toolName == "Bash" ? (request.input["command"] as? String ?? "") : ClaudeToolFormat.summary(name: request.toolName, input: request.input)
            if !text.isEmpty {
                ScrollView {
                    Text(request.toolName == "Bash" ? CodeHighlighter.attributed(text, language: "sh", palette: p) : AttributedString(text))
                        .font(ChatTypography.current.codeFont(size: fontSize - 0.5))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                }
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: DS.Radius.row).fill(Color.black.opacity(p.isDark ? 0.28 : 0.05)))
            }
        }
    }
}

// MARK: - Questions

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
            PromptHeader(title: questions.count == 1 ? "Claude has a question" : "Claude has \(questions.count) questions",
                         fontSize: fontSize) { EmptyView() }
            ForEach(questions) { q in question(q) }
            HStack(spacing: 8) {
                Button("Submit") { onAnswer(answers(questions)) }
                    .buttonStyle(.labeled(.primary))
                    .disabled(!questions.allSatisfy { !answer(for: $0).isEmpty })
                Button("Skip") { onDeny() }
                    .buttonStyle(.labeled(.neutral))
                Spacer()
                Text(hint(questions)).font(.system(size: 10.5)).foregroundStyle(p.dim)
            }
        }
        .padding(14)
        .promptCard(p)
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
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(q.multiSelect ? (selected ? "✓" : " ") : "\(index + 1)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? Color.white : p.foreground.opacity(0.8))
                    .frame(width: 18, height: 18)
                    .background(selected ? DS.Status.selection : p.foreground.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
                VStack(alignment: .leading, spacing: 1) {
                    Text(InlineMarkdown.attributed(o.label, palette: p, directory: directory))
                        .font(.system(size: fontSize - 1, weight: .medium))
                    if !o.description.isEmpty {
                        Text(InlineMarkdown.attributed(o.description, palette: p, directory: directory))
                            .font(.system(size: fontSize - 2)).foregroundStyle(p.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? DS.Status.selection.opacity(0.16) : hovered[q.id] == o.label ? p.foreground.opacity(0.07) : .clear))
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
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "pencil")
                .font(.system(size: 10))
                .foregroundStyle(on ? Color.white : p.dim)
                .frame(width: 18, height: 18)
                .background(on ? DS.Status.selection : p.foreground.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
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
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(on ? DS.Status.selection.opacity(0.16) : .clear))
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
        guard questions.count == 1, let q = questions.first else { return "esc skips" }
        return q.multiSelect ? "Type an answer and ⏎ · esc skips"
            : "1–\(q.options.count) chooses · type an answer and ⏎ · esc skips"
    }
}

struct QuestionHeaderChip: View {
    let text: String
    let palette: ClaudePalette

    var body: some View {
        Text(text).font(.system(size: 10, weight: .bold)).foregroundStyle(palette.foreground.opacity(0.8))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(palette.foreground.opacity(0.1)))
            .fixedSize()
    }
}

// MARK: - Plans

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
        let size = fontSize - 0.5
        VStack(alignment: .leading, spacing: 0) {
            PromptHeader(title: "Ready to code? Review Claude's plan", fontSize: fontSize) {
                ToolChip(name: "Plan", palette: p)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            ScrollView {
                MarkdownView(text: request.plan, palette: p, fontSize: fontSize - 0.5, directory: directory)
                    .padding(12)
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: DS.Radius.row).fill(Color.black.opacity(p.isDark ? 0.28 : 0.05)))
            .padding(.horizontal, 14)
            VStack(spacing: 4) {
                PromptChoiceRow(number: 1, title: Text("Yes, and auto-accept edits"), trailing: "⏎", selected: true, palette: p, fontSize: size) {
                    onDecide(.acceptEdits)
                }
                PromptChoiceRow(number: 2, title: Text("Yes, and ask before edits"), palette: p, fontSize: size) { onDecide(.default) }
                PromptChoiceRow(number: 3, title: Text("No, keep planning"), trailing: "or type feedback", palette: p, fontSize: size) {
                    onDecide(nil)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 10)
        }
        .promptCard(p)
    }
}
