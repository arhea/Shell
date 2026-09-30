import AppKit
import Observation
import SwiftUI

/// State shared between the composer's text view and the SwiftUI around it.
@MainActor
@Observable
final class ClaudeComposerModel {
    struct Suggestion: Identifiable, Equatable {
        var id: String { insert }
        var kind: InlineMarkdown.TokenKind
        var title: String
        var insert: String
        var detail: String
        var badge: String?
    }

    var suggestions: [Suggestion] = []
    var selected = 0
    var height: CGFloat = 22
    var isEmpty = true
    /// A file or image is being dragged over the composer.
    var dropTargeted = false

    @ObservationIgnored weak var textView: ComposerTextView?
    @ObservationIgnored var tokenRange: NSRange?
    @ObservationIgnored var history: [String] = []
    @ObservationIgnored var historyIndex: Int?
    @ObservationIgnored var fileIndex: [String] = []
    @ObservationIgnored var fileIndexDate: Date?
    @ObservationIgnored var fileIndexLoading = false

    var showsSuggestions: Bool { !suggestions.isEmpty }

    func focus() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }

    /// Inserts text at the cursor (e.g. "@path" from the file explorer).
    func insert(_ text: String) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let needsSpace = range.location > 0 && !((tv.string as NSString).substring(with: NSRange(location: range.location - 1, length: 1)).first?.isWhitespace ?? true)
        tv.insertText((needsSpace ? " " : "") + text, replacementRange: range)
        focus()
    }
}

/// The composer's text view. Key handling is delegated to the coordinator.
final class ComposerTextView: NSTextView {
    var keyHandler: ((NSEvent) -> Bool)?
    var onFocus: (() -> Void)?
    /// Takes files or images from a paste or drop; returns false for plain text.
    var attachHandler: ((NSPasteboard) -> Bool)?
    /// A file drag entered (true) or left (false) the text view.
    var onDragHover: ((Bool) -> Void)?

    /// Accept file and image drags, not just text.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL, .png, .tiff]
    }
    var placeholder = ""
    var placeholderColor: NSColor = .tertiaryLabelColor

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }

    override func paste(_ sender: Any?) {
        if attachHandler?(.general) == true { return }
        pasteAsPlainText(sender)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if Self.hasFiles(sender.draggingPasteboard) {
            onDragHover?(true)
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragHover?(false)
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onDragHover?(false)
        super.draggingEnded(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if Self.hasFiles(sender.draggingPasteboard) { return .copy }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onDragHover?(false)
        if Self.hasFiles(sender.draggingPasteboard), attachHandler?(sender.draggingPasteboard) == true { return true }
        return super.performDragOperation(sender)
    }

    private static func hasFiles(_ pb: NSPasteboard) -> Bool {
        pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || (pb.string(forType: .string) == nil && (pb.data(forType: .png) != nil || pb.data(forType: .tiff) != nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: placeholderColor]
        (placeholder as NSString).draw(at: NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y), withAttributes: attrs)
    }
}

struct ClaudeComposerField: NSViewRepresentable {
    let claude: ClaudeCodeSession
    let model: ClaudeComposerModel
    let palette: ClaudePalette
    let fontSize: CGFloat
    var onExit: () -> Void
    var onFocus: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder

        let tv = ComposerTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.isAutomaticLinkDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 0, height: 3)
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.placeholder = "Ask Claude…  / for skills & commands, @ for files & MCP servers"
        tv.setAccessibilityLabel("Claude prompt")
        tv.keyHandler = { [weak coordinator = context.coordinator] event in coordinator?.handleKey(event) ?? false }
        tv.onFocus = { [weak coordinator = context.coordinator] in coordinator?.parent.onFocus() }
        tv.attachHandler = { [weak coordinator = context.coordinator] pb in coordinator?.attach(from: pb) ?? false }
        tv.onDragHover = { [weak model] over in model?.dropTargeted = over }
        scroll.documentView = tv
        model.textView = tv
        context.coordinator.textView = tv
        context.coordinator.applyStyle()
        if !claude.draft.isEmpty {
            tv.string = claude.draft
            context.coordinator.textChanged()
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyStyle()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ClaudeComposerField
        weak var textView: ComposerTextView?
        private var lastStyleKey = ""

        init(_ parent: ClaudeComposerField) { self.parent = parent }

        var model: ClaudeComposerModel { parent.model }
        var claude: ClaudeCodeSession { parent.claude }

        var baseFont: NSFont { ChatTypography.current.nsFont(size: parent.fontSize) }
        var monoFont: NSFont { .monospacedSystemFont(ofSize: parent.fontSize - 0.5, weight: .regular) }

        func applyStyle() {
            guard let tv = textView else { return }
            let p = parent.palette
            let typography = ChatTypography.current
            let spacing = (typography.lineSpacing * 0.6).rounded()
            let key = "\(parent.fontSize)|\(spacing)|\(typography.family)|\(p.foreground)|\(p.dim)|\(claude.commands.count)|\(claude.mcpServers.count)"
            guard key != lastStyleKey else { return }
            lastStyleKey = key
            tv.font = baseFont
            tv.textColor = NSColor(p.foreground)
            tv.insertionPointColor = NSColor(p.claude)
            tv.placeholderColor = NSColor(p.dim)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = spacing
            tv.defaultParagraphStyle = paragraph
            tv.typingAttributes = [.font: baseFont, .foregroundColor: NSColor(p.foreground), .paragraphStyle: paragraph]
            tv.textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: tv.textStorage?.length ?? 0))
            tv.selectedTextAttributes = [.backgroundColor: NSColor(p.claude).withAlphaComponent(0.25)]
            highlight()
            tv.needsDisplay = true
        }

        // MARK: Text changes

        func textDidChange(_ notification: Notification) { textChanged() }

        func textViewDidChangeSelection(_ notification: Notification) { updateSuggestions() }

        func textChanged() {
            guard let tv = textView else { return }
            model.isEmpty = tv.string.isEmpty
            claude.draft = tv.string
            highlight()
            updateHeight()
            updateSuggestions()
            tv.needsDisplay = true
        }

        func updateHeight() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let h = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2
            let clamped = min(max(h, parent.fontSize + 10), 280)
            if abs(model.height - clamped) > 0.5 { model.height = clamped }
        }

        // MARK: Highlighting

        func highlight() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let text = tv.string
            let ns = text as NSString
            let full = NSRange(location: 0, length: ns.length)
            let p = parent.palette
            let fg = NSColor(p.foreground)
            storage.beginEditing()
            storage.setAttributes([.font: baseFont, .foregroundColor: fg], range: full)

            // Fenced code blocks (an unclosed fence runs to the end).
            var codeRanges: [NSRange] = []
            var searchFrom = 0
            while searchFrom < ns.length {
                let open = ns.range(of: "```", options: [], range: NSRange(location: searchFrom, length: ns.length - searchFrom))
                guard open.location != NSNotFound else { break }
                let afterOpen = open.location + 3
                let close = ns.range(of: "```", options: [], range: NSRange(location: afterOpen, length: ns.length - afterOpen))
                let end = close.location == NSNotFound ? ns.length : close.location + 3
                let range = NSRange(location: open.location, length: end - open.location)
                codeRanges.append(range)
                storage.addAttributes([.font: monoFont, .foregroundColor: fg, .backgroundColor: NSColor(p.raised)], range: range)
                // Language tag and fences dimmed; code tokens colored.
                let firstLineEnd = ns.range(of: "\n", options: [], range: NSRange(location: afterOpen, length: end - afterOpen))
                let headerEnd = firstLineEnd.location == NSNotFound ? end : firstLineEnd.location
                storage.addAttribute(.foregroundColor, value: NSColor(p.dim), range: NSRange(location: open.location, length: headerEnd - open.location))
                if close.location != NSNotFound {
                    storage.addAttribute(.foregroundColor, value: NSColor(p.dim), range: close)
                }
                let lang = ns.substring(with: NSRange(location: afterOpen, length: headerEnd - afterOpen)).trimmingCharacters(in: .whitespaces)
                let bodyStart = min(headerEnd + 1, end)
                let bodyEnd = close.location == NSNotFound ? end : close.location
                if bodyEnd > bodyStart {
                    let body = ns.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
                    for (r, token) in CodeHighlighter.tokens(in: body, language: lang) {
                        let nr = NSRange(r, in: body)
                        storage.addAttribute(.foregroundColor, value: NSColor(CodeHighlighter.color(token, p)),
                                             range: NSRange(location: bodyStart + nr.location, length: nr.length))
                    }
                }
                searchFrom = end
            }
            func inCode(_ r: NSRange) -> Bool { codeRanges.contains { NSIntersectionRange($0, r).length > 0 } }
            func apply(_ regex: NSRegularExpression, _ attrs: (NSTextCheckingResult) -> [(NSRange, [NSAttributedString.Key: Any])]) {
                for m in regex.matches(in: text, range: full) where !inCode(m.range) {
                    for (r, a) in attrs(m) where r.location != NSNotFound { storage.addAttributes(a, range: r) }
                }
            }
            let bold = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
            let italic = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            apply(Self.heading) { m in [(m.range, [.font: NSFont.systemFont(ofSize: self.parent.fontSize + 1, weight: .bold), .foregroundColor: NSColor(p.claude)])] }
            apply(Self.bold) { m in [(m.range, [.font: bold])] }
            apply(Self.italic) { m in [(m.range(at: 1), [.font: italic])] }
            apply(Self.listMarker) { m in [(m.range(at: 1), [.foregroundColor: NSColor(p.claude)])] }
            apply(Self.quote) { m in [(m.range, [.foregroundColor: NSColor(p.dim)])] }
            apply(Self.link) { m in [(m.range(at: 1), [.foregroundColor: NSColor(p.blue)]), (m.range(at: 2), [.foregroundColor: NSColor(p.dim)])] }
            apply(Self.inlineCode) { m in [(m.range, [.font: self.monoFont, .foregroundColor: NSColor(p.claude), .backgroundColor: NSColor(p.raised)])] }
            let style = mentionStyle
            apply(Self.token) { m in
                let r = m.range(at: 1)
                guard let kind = InlineMarkdown.classify(ns.substring(with: r), style: style) else { return [] }
                let color = NSColor(InlineMarkdown.color(for: kind, palette: p))
                return [(r, [.foregroundColor: color, .backgroundColor: color.withAlphaComponent(0.15),
                             .font: NSFont.systemFont(ofSize: self.parent.fontSize, weight: .semibold)])]
            }
            storage.endEditing()
            tv.typingAttributes = [.font: baseFont, .foregroundColor: fg]
        }

        var mentionStyle: InlineMarkdown.MentionStyle {
            InlineMarkdown.MentionStyle(skills: claude.skills, commands: Set(claude.commands.map(\.name)),
                                        mcpServers: Set(claude.mcpServers.map(\.mention)), agents: Set(claude.agents))
        }

        // swiftlint:disable force_try
        static let heading = try! NSRegularExpression(pattern: "^#{1,6} .*$", options: .anchorsMatchLines)
        static let bold = try! NSRegularExpression(pattern: "(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
        static let italic = try! NSRegularExpression(pattern: "(?<![*\\w])(\\*(?=\\S)[^*\\n]+?(?<=\\S)\\*)(?![*\\w])")
        static let listMarker = try! NSRegularExpression(pattern: "^\\s*([-*+]|\\d+\\.)\\s", options: .anchorsMatchLines)
        static let quote = try! NSRegularExpression(pattern: "^>.*$", options: .anchorsMatchLines)
        static let link = try! NSRegularExpression(pattern: "\\[([^\\]\\n]+)\\](\\([^)\\s]+\\))")
        static let inlineCode = try! NSRegularExpression(pattern: "`[^`\\n]+`")
        static let token = try! NSRegularExpression(pattern: "(?:^|(?<=[\\s(\\[]))([/@][\\w\\-:.\\/~]+)", options: .anchorsMatchLines)
        // swiftlint:enable force_try

        // MARK: Suggestions

        /// The `/…` or `@…` token the cursor is in, if any.
        func currentToken() -> (range: NSRange, text: String)? {
            guard let tv = textView else { return nil }
            let sel = tv.selectedRange()
            guard sel.length == 0 else { return nil }
            let ns = tv.string as NSString
            var start = sel.location
            while start > 0 {
                let c = ns.character(at: start - 1)
                if let scalar = UnicodeScalar(c), CharacterSet.whitespacesAndNewlines.contains(scalar) { break }
                start -= 1
            }
            guard start < sel.location else { return nil }
            let token = ns.substring(with: NSRange(location: start, length: sel.location - start))
            guard let first = token.first, first == "/" || first == "@" else { return nil }
            // Slash commands only at the start of a line.
            if first == "/", start > 0, ns.character(at: start - 1) != 10 { return nil }
            // Not inside a code block.
            let before = ns.substring(to: start)
            if before.components(separatedBy: "```").count % 2 == 0 { return nil }
            return (NSRange(location: start, length: sel.location - start), token)
        }

        func updateSuggestions() {
            guard let (range, token) = currentToken() else {
                hideSuggestions()
                return
            }
            model.tokenRange = range
            let query = String(token.dropFirst()).lowercased()
            var result: [ClaudeComposerModel.Suggestion] = []
            if token.hasPrefix("/") {
                let ranked = claude.commands.compactMap { c -> (Int, ClaudeCommandInfo)? in
                    guard let score = Self.score(c.name.lowercased(), query) else { return nil }
                    return (score, c)
                }.sorted { ($0.0, $0.1.name) < ($1.0, $1.1.name) }
                result = ranked.prefix(40).map { _, c in
                    let isSkill = claude.skills.contains(c.name)
                    let isMCP = c.name.hasPrefix("mcp__")
                    return .init(kind: isSkill ? .skill : .command, title: "/" + c.name, insert: "/" + c.name + " ",
                                 detail: Self.cleanDescription(c.description.isEmpty ? c.argumentHint : c.description),
                                 badge: isSkill ? "skill" : isMCP ? "mcp" : nil)
                }
            } else {
                for server in claude.mcpServers where Self.score(server.mention.lowercased(), query) != nil {
                    result.append(.init(kind: .mcp, title: "@" + server.mention, insert: "@" + server.mention + " ",
                                        detail: "MCP server", badge: server.status == "connected" ? "mcp" : server.status))
                }
                for agent in claude.agents where Self.score(agent.lowercased(), query) != nil {
                    result.append(.init(kind: .agent, title: "@agent-" + agent, insert: "@agent-" + agent + " ", detail: "Subagent", badge: "agent"))
                }
                loadFileIndexIfNeeded()
                let files = model.fileIndex.compactMap { path -> (Int, String)? in
                    let name = (path as NSString).lastPathComponent.lowercased()
                    if let s = Self.score(name, query) { return (s, path) }
                    if let s = Self.score(path.lowercased(), query) { return (s + 10, path) }
                    return nil
                }.sorted { ($0.0, $0.1.count, $0.1) < ($1.0, $1.1.count, $1.1) }
                for (_, path) in files.prefix(40) {
                    let quoted = path.contains(" ") ? "\"\(path)\"" : path
                    result.append(.init(kind: .file, title: (path as NSString).lastPathComponent, insert: "@" + quoted + " ",
                                        detail: path, badge: nil))
                }
            }
            if result != model.suggestions {
                model.suggestions = result
                model.selected = 0
            }
        }

        func hideSuggestions() {
            if !model.suggestions.isEmpty { model.suggestions = [] }
            model.tokenRange = nil
        }

        func accept(_ s: ClaudeComposerModel.Suggestion) {
            guard let tv = textView, let range = model.tokenRange else { return }
            tv.insertText(s.insert, replacementRange: range)
            hideSuggestions()
        }

        /// Lower is better; nil = no match. Prefix < word-prefix < substring < subsequence.
        static func score(_ candidate: String, _ query: String) -> Int? {
            if query.isEmpty { return 0 }
            if candidate.hasPrefix(query) { return 0 }
            if candidate.contains(":" + query) || candidate.contains("-" + query) || candidate.contains("/" + query) || candidate.contains("_" + query) { return 1 }
            if candidate.contains(query) { return 2 }
            var it = candidate.makeIterator()
            for q in query {
                var found = false
                while let c = it.next() { if c == q { found = true; break } }
                if !found { return nil }
            }
            return 3
        }

        static func cleanDescription(_ s: String) -> String {
            let line = s.components(separatedBy: "\n").first ?? s
            return line.count > 140 ? String(line.prefix(137)) + "…" : line
        }

        private func loadFileIndexIfNeeded() {
            if let date = model.fileIndexDate, Date().timeIntervalSince(date) < 15 { return }
            guard !model.fileIndexLoading else { return }
            model.fileIndexLoading = true
            let model = self.model
            let directory = claude.directory
            let repo = claude.repository
            Task { [weak self] in
                let files = await Self.listFiles(directory: directory, repository: repo)
                model.fileIndex = files
                model.fileIndexDate = Date()
                model.fileIndexLoading = false
                self?.updateSuggestions()
            }
        }

        /// Paths relative to the session directory: tracked + untracked files
        /// in a repo, else a bounded walk of the directory.
        static func listFiles(directory: String, repository: GitRepository?) async -> [String] {
            if repository != nil,
               let out = await GitRepository.run(GitRepository.findGit(environment: ProcessInfo.processInfo.environment),
                                                 ["ls-files", "-co", "--exclude-standard", "-z"], in: directory) {
                return out.split(separator: "\0").prefix(50_000).map(String.init)
            }
            return await Task.detached {
                var files: [String] = []
                let base = URL(fileURLWithPath: directory)
                guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey],
                                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return files }
                while let url = e.nextObject() as? URL {
                    if url.lastPathComponent == "node_modules" { e.skipDescendants(); continue }
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
                    files.append(String(url.path.dropFirst(base.path.count + 1)))
                    if files.count >= 5000 { break }
                }
                return files
            }.value
        }

        // MARK: Keys

        func handleKey(_ event: NSEvent) -> Bool {
            guard let tv = textView else { return false }
            let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
            let empty = tv.string.isEmpty
            switch event.keyCode {
            case 36, 76: // Return
                if model.showsSuggestions, flags.isEmpty {
                    accept(model.suggestions[model.selected])
                    return true
                }
                if flags.contains(.shift) || flags.contains(.option) {
                    tv.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                // Inside an open ``` block, Return adds a line.
                let before = (tv.string as NSString).substring(to: tv.selectedRange().location)
                if before.components(separatedBy: "```").count % 2 == 0 {
                    tv.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                if let req = claude.pending.first {
                    let typed = tv.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if req.isPlan {
                        // Return approves; typed text is feedback to keep planning.
                        if typed.isEmpty { claude.approvePlan(req, mode: .acceptEdits) } else { claude.keepPlanning(req, feedback: typed) }
                        clear()
                        return true
                    }
                    if req.isQuestion {
                        // A typed reply answers a single question ("Other").
                        let questions = req.questions
                        if questions.count == 1, !typed.isEmpty {
                            claude.answer(req, answers: [questions[0].question: typed])
                            clear()
                        }
                        return true
                    }
                    if empty {
                        claude.respond(req, allow: true)
                        return true
                    }
                }
                submit()
                return true
            case 48: // Tab
                if flags.contains(.shift) {
                    claude.cyclePermissionMode()
                    return true
                }
                if model.showsSuggestions {
                    accept(model.suggestions[model.selected])
                    return true
                }
                return false
            case 53: // Esc
                if model.showsSuggestions {
                    hideSuggestions()
                } else if let req = claude.pending.first {
                    claude.respond(req, allow: false)
                } else if claude.isRunning {
                    claude.interrupt()
                } else if model.historyIndex != nil {
                    model.historyIndex = nil
                    tv.string = ""
                    textChanged()
                }
                return true
            case 126, 125: // Up / Down
                let up = event.keyCode == 126
                if model.showsSuggestions {
                    let n = model.suggestions.count
                    model.selected = (model.selected + (up ? -1 : 1) + n) % n
                    return true
                }
                if flags.isEmpty, empty || model.historyIndex != nil, onFirstOrLastLine(up: up) {
                    return recallHistory(up: up)
                }
                return false
            default:
                break
            }
            if flags == .control, event.charactersIgnoringModifiers == "d", empty {
                parent.onExit()
                return true
            }
            if flags == .control, event.charactersIgnoringModifiers == "c", claude.isRunning, tv.selectedRange().length == 0 {
                claude.interrupt()
                return true
            }
            // Number keys answer a question or plan, like Claude Code's TUI.
            if empty, flags.isEmpty, let req = claude.pending.first, let c = event.characters, let n = Int(c) {
                if req.isQuestion {
                    let questions = req.questions
                    if questions.count == 1, !questions[0].multiSelect, n >= 1, n <= questions[0].options.count {
                        claude.answer(req, answers: [questions[0].question: questions[0].options[n - 1].label])
                        return true
                    }
                } else if req.isPlan {
                    switch n {
                    case 1: claude.approvePlan(req, mode: .acceptEdits); return true
                    case 2: claude.approvePlan(req, mode: .default); return true
                    case 3: claude.keepPlanning(req, feedback: ""); return true
                    default: break
                    }
                }
            }
            // 1 / 2 / 3 answer a permission prompt, like Claude Code's TUI.
            if empty, flags.isEmpty, let req = claude.pending.first, !req.isQuestion, !req.isPlan, let c = event.characters {
                switch c {
                case "1": claude.respond(req, allow: true); return true
                case "2" where !req.suggestions.isEmpty: claude.respond(req, allow: true, always: true); return true
                case "2", "3": claude.respond(req, allow: false); return true
                default: break
                }
            }
            return false
        }

        private func onFirstOrLastLine(up: Bool) -> Bool {
            guard let tv = textView else { return true }
            let ns = tv.string as NSString
            let loc = tv.selectedRange().location
            if up { return ns.range(of: "\n", options: [], range: NSRange(location: 0, length: loc)).location == NSNotFound }
            return ns.range(of: "\n", options: [], range: NSRange(location: loc, length: ns.length - loc)).location == NSNotFound
        }

        private func recallHistory(up: Bool) -> Bool {
            guard let tv = textView, !model.history.isEmpty else { return false }
            var idx = model.historyIndex ?? model.history.count
            idx += up ? -1 : 1
            if idx < 0 { return true }
            if idx >= model.history.count {
                model.historyIndex = nil
                tv.string = ""
            } else {
                model.historyIndex = idx
                tv.string = model.history[idx]
            }
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            textChanged()
            return true
        }

        func submit() {
            guard let tv = textView else { return }
            let text = tv.string.trimmingCharacters(in: .whitespacesAndNewlines)
            let attachments = claude.draftAttachments
            guard !text.isEmpty || !attachments.isEmpty else { return }
            if attachments.isEmpty, text == "/exit" || text == "/quit" {
                parent.onExit()
                return
            }
            // Keep the draft while signed out or starting.
            guard claude.canSend else { return }
            claude.send(text, attachments: attachments)
            claude.draftAttachments = []
            if !text.isEmpty, model.history.last != text { model.history.append(text) }
            clear()
        }

        /// Adds pasted or dropped files and images to the draft.
        func attach(from pb: NSPasteboard) -> Bool {
            let pasted = claude.draftAttachments.filter { $0.name.hasPrefix("Pasted image") }.count
            let new = ClaudeAttachment.from(pasteboard: pb, pastedSoFar: pasted)
            guard !new.isEmpty else { return false }
            claude.draftAttachments += new
            return true
        }

        private func clear() {
            guard let tv = textView else { return }
            model.historyIndex = nil
            tv.string = ""
            tv.undoManager?.removeAllActions()
            textChanged()
        }
    }
}

/// The autocomplete list shown above the composer.
struct ClaudeSuggestionList: View {
    @Bindable var model: ClaudeComposerModel
    let palette: ClaudePalette
    var onAccept: (ClaudeComposerModel.Suggestion) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, s in
                        row(s, selected: index == model.selected)
                            .id(index)
                            .onTapGesture { onAccept(s) }
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 240)
            .onChange(of: model.selected) { _, new in proxy.scrollTo(new) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 8).fill(palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.border))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    private func row(_ s: ClaudeComposerModel.Suggestion, selected: Bool) -> some View {
        let color = InlineMarkdown.color(for: s.kind, palette: palette)
        return HStack(spacing: 8) {
            Image(systemName: icon(s.kind))
                .foregroundStyle(color)
                .frame(width: 16)
            Text(s.title)
                .font(.system(size: 12, weight: .semibold, design: s.kind == .file ? .monospaced : .default))
                .foregroundStyle(palette.foreground)
                .lineLimit(1)
            Text(s.detail)
                .font(.system(size: 11))
                .foregroundStyle(palette.dim)
                .lineLimit(1)
                .truncationMode(s.kind == .file ? .head : .tail)
            Spacer(minLength: 4)
            if let badge = s.badge {
                Text(badge)
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .foregroundStyle(color)
                    .background(Capsule().fill(color.opacity(0.15)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? palette.claude.opacity(0.18) : .clear))
        .contentShape(Rectangle())
    }

    private func icon(_ kind: InlineMarkdown.TokenKind) -> String {
        switch kind {
        case .skill: "sparkles"
        case .command: "chevron.left.forwardslash.chevron.right"
        case .mcp: "puzzlepiece.extension"
        case .agent: "person.crop.circle"
        case .file: "doc"
        }
    }
}
