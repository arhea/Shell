import AppKit
import SwiftUI

/// The text view inside the input editor. Adds ghost-text suggestions and
/// routes special keys to the editor controller.
final class CommandTextView: NSTextView {
    weak var editor: InputEditorView?
    var ghostText: String? {
        didSet { if ghostText != oldValue { needsDisplay = true } }
    }
    var ghostColor: NSColor = .tertiaryLabelColor

    override func keyDown(with event: NSEvent) {
        if let editor, editor.handleKeyDown(event) { return }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        if let editor, editor.handleCommand(selector) { return }
        super.doCommand(by: selector)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { editor?.focusChanged(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { editor?.focusChanged(false) }
        return ok
    }

    // ⌘C with nothing selected here copies the terminal's selection instead.
    override func copy(_ sender: Any?) {
        if selectedRange().length == 0, let editor, editor.copyTerminalSelection() { return }
        super.copy(sender)
    }

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ghost = ghostText, !ghost.isEmpty, let lm = layoutManager, let tc = textContainer,
              selectedRange().location == (string as NSString).length else { return }
        let firstLine = ghost.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ghost
        let length = (string as NSString).length
        var point = NSPoint(x: textContainerOrigin.x, y: textContainerOrigin.y)
        if length > 0 {
            let glyphRange = lm.glyphRange(forCharacterRange: NSRange(location: length - 1, length: 1), actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            let lastChar = (string as NSString).substring(from: length - 1)
            if lastChar == "\n" {
                point = NSPoint(x: textContainerOrigin.x, y: rect.maxY + textContainerOrigin.y)
            } else {
                point = NSPoint(x: rect.maxX + textContainerOrigin.x, y: rect.minY + textContainerOrigin.y)
            }
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                                                    .foregroundColor: ghostColor]
        (firstLine as NSString).draw(at: point, withAttributes: attrs)
    }
}

/// Warp-style command input: a native multi-line editor with syntax
/// highlighting, history ghost text, zsh completions, and a context bar.
@MainActor
final class InputEditorView: NSView, NSTextViewDelegate {
    let session: TerminalSession
    let textView = CommandTextView()
    private let scrollView = NSScrollView()
    private let promptLabel = NSTextField(labelWithString: "❯")
    private let separator = NSView()
    private var contextHost: NSHostingView<EditorContextBar>!
    let completion = CompletionModel()
    let barState = EditorBarState()

    var onHeightChange: (() -> Void)?
    var onCompletionVisibilityChange: (() -> Void)?
    var onFocus: (() -> Void)?
    var onSubmit: ((String) -> Void)?

    private var historyPosition: Int?
    private var historyPrefix = ""
    private var draftBeforeHistory = ""
    private var completionWork: DispatchWorkItem?
    private var pendingTabCompletion = false
    private var pendingSubmit: String?
    private var suppressCompletionOnce = false
    /// A corrected version of the command that just failed (Apple Intelligence).
    private var fixSuggestion: String?
    private var fixTask: Task<Void, Never>?
    /// The failure last asked about, so a bare prompt redraw doesn't ask again.
    private var fixCheckedFor: String?

    private(set) var editorFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    var isAtTop: Bool { SettingsStore.shared.settings.inputPosition == .top }

    init(session: TerminalSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true

        separator.wantsLayer = true
        addSubview(separator)

        contextHost = NSHostingView(rootView: EditorContextBar(session: session, bar: barState, onCopy: { _ in }))
        contextHost.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contextHost)

        promptLabel.isSelectable = false
        addSubview(promptLabel)

        textView.editor = self
        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: Self.textInset)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel("Command input")

        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        addSubview(scrollView)

        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: Appearance & layout

    func applyTheme() {
        let s = SettingsStore.shared.settings
        let t = ConfigController.shared.theme
        let size = CGFloat(s.editorFontSize > 0 ? s.editorFontSize : s.fontSize)
        editorFont = Self.font(family: s.fontFamily, size: size)
        textView.font = editorFont
        textView.textColor = t.foreground.nsColor
        textView.insertionPointColor = (t.cursor ?? t.accent).nsColor
        textView.selectedTextAttributes = [.backgroundColor: (t.selectionBackground ?? t.accent.mixed(with: t.background, 0.6)).nsColor]
        textView.typingAttributes = [.font: editorFont, .foregroundColor: t.foreground.nsColor]
        textView.ghostColor = t.background.mixed(with: t.foreground, 0.4).nsColor
        promptLabel.font = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        promptLabel.textColor = t.accent.nsColor
        separator.layer?.backgroundColor = t.background.mixed(with: t.foreground, 0.14).nsColor.cgColor
        layer?.backgroundColor = t.background.mixed(with: t.foreground, t.isDark ? 0.035 : 0.025).nsColor.cgColor
        contextHost.rootView = makeContextBar()
        highlight()
        needsLayout = true
        onHeightChange?()
    }

    /// Registers the bundled JetBrains Mono (libghostty's default font) so the
    /// editor and previews match the terminal.
    static let bundledFontFamily: String? = {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        var family: String?
        for url in files where url.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            if family == nil, let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
               let d = descs.first {
                family = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String
            }
        }
        return family
    }()

    static func font(family: String, size: CGFloat) -> NSFont {
        let family = family.isEmpty ? (bundledFontFamily ?? "") : family
        if !family.isEmpty,
           let f = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) ?? NSFont(name: family, size: size) {
            return f
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Cached per font; `preferredHeight` runs on every keystroke.
    private var lineHeightCache: (font: NSFont, height: CGFloat)?
    private var lineHeight: CGFloat {
        if let c = lineHeightCache, c.font == editorFont { return c.height }
        let h = ceil(NSLayoutManager().defaultLineHeight(for: editorFont))
        lineHeightCache = (editorFont, h)
        return h
    }

    private var contextHeight: CGFloat { 24 }

    // Spacing around the prompt (points). The text area is at least
    // `minTextLines` tall so the input reads as a roomy entry field.
    private static let sidePadding: CGFloat = 20
    private static let topPadding: CGFloat = 12
    private static let contextGap: CGFloat = 6
    private static let bottomPadding: CGFloat = 14
    private static let textInset: CGFloat = 4
    private static let minTextLines: CGFloat = 1.5

    /// Height of the text area for `textHeight` of laid-out text.
    private func textAreaHeight(_ textHeight: CGFloat) -> CGFloat {
        let minimum = ceil(lineHeight * Self.minTextLines) + Self.textInset * 2
        return max(minimum, min(textHeight, lineHeight * 10) + Self.textInset * 2)
    }

    var preferredHeight: CGFloat {
        let lm = textView.layoutManager, tc = textView.textContainer
        var textHeight = lineHeight
        if let lm, let tc {
            lm.ensureLayout(for: tc)
            textHeight = max(lineHeight, lm.usedRect(for: tc).height)
        }
        return Self.topPadding + contextHeight + Self.contextGap + textAreaHeight(textHeight) + Self.bottomPadding
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let pad = Self.sidePadding
        separator.frame = isAtTop ? NSRect(x: 0, y: bounds.height - 1, width: w, height: 1) : NSRect(x: 0, y: 0, width: w, height: 1)
        let top = Self.topPadding
        contextHost.frame = NSRect(x: pad - 4, y: top - 2, width: w - pad * 2 + 8, height: contextHeight)
        let textTop = top + contextHeight + Self.contextGap
        let promptWidth: CGFloat = 18
        promptLabel.sizeToFit()
        promptLabel.frame = NSRect(x: pad, y: textTop + Self.textInset - 1, width: promptWidth, height: lineHeight + 2)
        let textHeight = bounds.height - textTop - Self.bottomPadding
        scrollView.frame = NSRect(x: pad + promptWidth, y: textTop, width: w - pad * 2 - promptWidth, height: max(textHeight, lineHeight))
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.frame.size.width = scrollView.contentSize.width
    }

    func refreshContext() {
        contextHost.rootView = makeContextBar()
    }

    private func makeContextBar() -> EditorContextBar {
        EditorContextBar(session: session, bar: barState, onCopy: { [weak self] kind in self?.copy(kind) })
    }

    // MARK: Copy

    enum CopyKind { case command, lastCommand, lastOutput }

    /// Copies to the clipboard and flashes the result on the Copy button.
    func copy(_ kind: CopyKind) {
        var text: String?
        var message: String
        switch kind {
        case .command:
            if !textView.string.isEmpty {
                text = textView.string
                message = "Copied command"
            } else {
                // Nothing typed yet: the most useful thing is the last command.
                text = session.lastBlock?.command ?? session.lastCommand ?? HistoryStore.shared.entries.last
                message = "Copied last command"
            }
        case .lastCommand:
            text = session.lastBlock?.command ?? session.lastCommand ?? HistoryStore.shared.entries.last
            message = "Copied last command"
        case .lastOutput:
            text = session.lastOutput()
            message = text.map { $0.isEmpty ? "Last command had no output" : { n in "Copied \(n) line\(n == 1 ? "" : "s") of output" }($0.components(separatedBy: "\n").count) }
                ?? "Output no longer on screen"
            if text?.isEmpty == true { text = nil }
        }
        if let text, !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } else if kind != .lastOutput {
            message = "Nothing to copy"
        }
        barState.flash(message, success: text?.isEmpty == false)
    }

    // MARK: Focus & text

    func focus() {
        window?.makeFirstResponder(textView)
    }

    func focusChanged(_ focused: Bool) {
        if focused { onFocus?() }
        if !focused { hideCompletions() }
    }

    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            textView.setSelectedRange(NSRange(location: (newValue as NSString).length, length: 0))
            textDidChangeInternal(requestCompletions: false)
        }
    }

    func insert(_ string: String) {
        focus()
        textView.insertText(string, replacementRange: textView.selectedRange())
    }

    func copyTerminalSelection() -> Bool {
        guard let s = session.surfaceView.selectionText, !s.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        return true
    }

    /// Called when the shell reaches a prompt; flushes anything typed early.
    func shellBecameIdle() {
        if let pending = pendingSubmit {
            pendingSubmit = nil
            session.submit(command: pending)
            return
        }
        suggestFixIfNeeded()
    }

    // MARK: Suggested fix (Apple Intelligence)

    /// After a failed command, asks the on-device model for a corrected one
    /// and offers it as ghost text. It's only ever inserted by the user (→).
    private func suggestFixIfNeeded() {
        guard Intelligence.isEnabled(.commandFixes), let code = session.lastExitCode, code != 0,
              let command = session.lastCommand else { return }
        let key = "\(command)\u{0}\(code)\u{0}\(session.lastDuration ?? -1)"
        guard key != fixCheckedFor else { return }
        fixCheckedFor = key
        clearFix()
        let output = session.lastOutput() ?? ""
        guard IntelligencePrompts.shouldSuggestFix(exitCode: code, output: output) else { return }
        let directory = session.abbreviatedDirectory
        let branch = session.gitBranch
        fixTask = Task { [weak self] in
            let fix = await Intelligence.commandFix(command: command, exitCode: code, output: output, directory: directory, branch: branch)
            guard let self, let fix, !Task.isCancelled, session.state == .idle, session.lastCommand == command,
                  fix.hasPrefix(textView.string) else { return }
            fixSuggestion = fix
            updateGhost()
        }
    }

    private func clearFix() {
        fixTask?.cancel()
        fixTask = nil
        fixSuggestion = nil
        barState.suggestedFix = false
    }

    func textDidChange(_ notification: Notification) {
        textDidChangeInternal(requestCompletions: true)
    }

    private func textDidChangeInternal(requestCompletions: Bool) {
        historyPosition = textView.string.isEmpty ? nil : historyPosition
        highlight()
        updateGhost()
        if requestCompletions && !suppressCompletionOnce {
            scheduleCompletions()
        }
        suppressCompletionOnce = false
        if completion.isVisible && completion.mode == .history { refreshHistorySearch() }
        // Last, so the pane lays out the popup with its filtered items.
        onHeightChange?()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateGhost()
    }

    // MARK: Syntax highlighting

    private func highlight() {
        guard let storage = textView.textStorage else { return }
        let s = SettingsStore.shared.settings
        let t = ConfigController.shared.theme
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: editorFont, .foregroundColor: t.foreground.nsColor], range: full)
        if s.syntaxHighlighting {
            for token in ShellLexer.tokenize(storage.string) {
                let color: NSColor?
                switch token.kind {
                case .command:
                    color = CommandIndex.shared.isKnown(token.text, cwd: session.workingDirectory) ? t.palette[2].nsColor : t.palette[1].nsColor
                case .option: color = t.palette[6].nsColor
                case .string: color = t.palette[3].nsColor
                case .variable, .assignment: color = t.palette[5].nsColor
                case .operatorToken, .redirect: color = t.accent.nsColor
                case .comment: color = t.background.mixed(with: t.foreground, 0.45).nsColor
                case .argument: color = nil
                }
                if let color, NSMaxRange(token.range) <= storage.length {
                    storage.addAttribute(.foregroundColor, value: color, range: token.range)
                }
            }
        }
        storage.endEditing()
    }

    // MARK: Ghost text (history suggestion)

    private func updateGhost() {
        let str = textView.string
        let sel = textView.selectedRange()
        let atEnd = sel.length == 0 && sel.location == (str as NSString).length
        // A suggested fix wins over history while what's typed still leads to it.
        if atEnd, !completion.isVisible, let fix = fixSuggestion, fix.hasPrefix(str), fix != str {
            textView.ghostText = String(fix.dropFirst(str.count))
            barState.suggestedFix = true
            return
        }
        barState.suggestedFix = false
        guard SettingsStore.shared.settings.historySuggestions, !completion.isVisible, atEnd, !str.isEmpty,
              let suggestion = HistoryStore.shared.suggestion(for: str) else {
            textView.ghostText = nil
            return
        }
        textView.ghostText = String(suggestion.dropFirst(str.count))
    }

    private func acceptGhost(wordOnly: Bool) -> Bool {
        guard let ghost = textView.ghostText, !ghost.isEmpty else { return false }
        var piece = ghost
        if wordOnly {
            let trimmedStart = ghost.prefix { $0 == " " }
            let rest = ghost.dropFirst(trimmedStart.count)
            let word = rest.prefix { $0 != " " && $0 != "/" }
            let sep = rest.dropFirst(word.count).prefix(1)
            piece = String(trimmedStart) + String(word) + (sep == "/" ? "/" : "")
        }
        suppressCompletionOnce = true
        textView.insertText(piece, replacementRange: textView.selectedRange())
        return true
    }

    // MARK: Keys

    func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let chars = event.charactersIgnoringModifiers ?? ""

        if flags == .control {
            switch chars {
            case "c":
                if textView.string.isEmpty && !completion.isVisible {
                    session.surfaceView.writeRaw("\u{03}")
                } else {
                    hideCompletions()
                    text = ""
                }
                return true
            case "d":
                if textView.string.isEmpty { session.surfaceView.writeRaw("\u{04}"); return true }
                return false
            case "l":
                session.surfaceView.writeRaw("\u{0c}")
                return true
            case "r":
                showHistorySearch()
                return true
            case "u":
                let sel = textView.selectedRange()
                let str = textView.string as NSString
                let lineStart = str.lineRange(for: NSRange(location: sel.location, length: 0)).location
                textView.insertText("", replacementRange: NSRange(location: lineStart, length: sel.location - lineStart))
                return true
            case "w":
                textView.deleteWordBackward(nil)
                return true
            case " ":
                requestCompletionsNow(fromTab: true)
                return true
            default:
                break
            }
        }
        if flags == .option && event.keyCode == 0x7C /* → */ {
            if acceptGhost(wordOnly: true) { return true }
        }
        if flags == .command && event.keyCode == 0x7C {
            if acceptGhost(wordOnly: false) { return true }
        }
        if event.keyCode == 0x77 /* End */ && flags.isEmpty {
            if acceptGhost(wordOnly: false) { return true }
        }
        return false
    }

    func handleCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true
            }
            if completion.isVisible {
                if completion.mode == .history, let item = completion.selected {
                    hideCompletions()
                    text = item.insertion
                    submit()
                    return true
                }
                if completion.userNavigated, let item = completion.selected {
                    accept(item)
                    return true
                }
            }
            if Self.hasUnterminatedQuote(textView.string) || textView.string.hasSuffix("\\") {
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true
            }
            submit()
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertLineBreak(_:)):
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        case #selector(NSResponder.insertTab(_:)):
            if completion.isVisible, let item = completion.selected {
                if completion.mode == .history {
                    hideCompletions()
                    text = item.insertion
                } else {
                    accept(item)
                }
            } else {
                requestCompletionsNow(fromTab: true)
            }
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            if completion.isVisible { completion.move(-1); return true }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if completion.isVisible { hideCompletions(); return true }
            if textView.ghostText != nil {
                textView.ghostText = nil
                clearFix()
                return true
            }
            return true
        case #selector(NSResponder.moveUp(_:)):
            if completion.isVisible { completion.move(-1); return true }
            return historyStep(backwards: true)
        case #selector(NSResponder.moveDown(_:)):
            if completion.isVisible { completion.move(1); return true }
            return historyStep(backwards: false)
        case #selector(NSResponder.moveRight(_:)):
            let sel = textView.selectedRange()
            if sel.length == 0, sel.location == (textView.string as NSString).length, acceptGhost(wordOnly: false) { return true }
            return false
        case #selector(NSResponder.moveToEndOfLine(_:)), #selector(NSResponder.moveToEndOfParagraph(_:)):
            let sel = textView.selectedRange()
            if sel.length == 0, sel.location == (textView.string as NSString).length, acceptGhost(wordOnly: false) { return true }
            return false
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
            if completion.isVisible { completion.move(-8); return true }
            return false
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
            if completion.isVisible { completion.move(8); return true }
            return false
        default:
            return false
        }
    }

    nonisolated static func hasUnterminatedQuote(_ s: String) -> Bool {
        var quote: Character?
        var escape = false
        for c in s {
            if escape { escape = false; continue }
            if c == "\\" && quote != "'" { escape = true; continue }
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            }
        }
        return quote != nil
    }

    private func historyStep(backwards: Bool) -> Bool {
        let str = textView.string as NSString
        let sel = textView.selectedRange()
        // Only take over ↑ on the first line and ↓ on the last line.
        if backwards {
            if str.lineRange(for: NSRange(location: sel.location, length: 0)).location != 0 { return false }
        } else {
            if NSMaxRange(str.lineRange(for: NSRange(location: sel.location, length: 0))) < str.length { return false }
            if historyPosition == nil { return false }
        }
        if historyPosition == nil {
            historyPrefix = textView.string
            draftBeforeHistory = textView.string
        }
        if let (pos, cmd) = HistoryStore.shared.step(from: historyPosition, prefix: historyPrefix, backwards: backwards) {
            historyPosition = pos
            suppressCompletionOnce = true
            textView.string = cmd
            textView.setSelectedRange(NSRange(location: (cmd as NSString).length, length: 0))
            highlight()
            textView.ghostText = nil
            onHeightChange?()
        } else if !backwards {
            historyPosition = nil
            textView.string = draftBeforeHistory
            textView.setSelectedRange(NSRange(location: (draftBeforeHistory as NSString).length, length: 0))
            highlight()
            onHeightChange?()
        }
        return true
    }

    // MARK: Submit

    func submit() {
        let command = textView.string
        hideCompletions()
        clearFix()
        textView.ghostText = nil
        historyPosition = nil
        switch session.state {
        case .idle:
            session.submit(command: command)
        case .starting:
            pendingSubmit = command
        case .running, .unmanaged:
            session.surfaceView.sendText(command)
            session.surfaceView.writeRaw("\r")
        }
        onSubmit?(command)
        textView.string = ""
        textView.undoManager?.removeAllActions()
        highlight()
        onHeightChange?()
    }

    // MARK: Completions

    private func scheduleCompletions() {
        completionWork?.cancel()
        let s = SettingsStore.shared.settings
        guard s.completions else { return }
        if !s.completionsWhileTyping && !completion.isVisible { return }
        if completion.isVisible && completion.mode == .completions { filterVisibleCompletions() }
        let work = DispatchWorkItem { [weak self] in self?.requestCompletionsNow(fromTab: false) }
        completionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: work)
    }

    func requestCompletionsNow(fromTab: Bool) {
        completionWork?.cancel()
        guard session.state == .idle, SettingsStore.shared.settings.completions else { return }
        let sel = textView.selectedRange()
        let before = (textView.string as NSString).substring(to: sel.location)
        if !fromTab {
            // Don't pop up for an empty line or right after a newline.
            let word = currentWord
            if before.trimmingCharacters(in: .whitespaces).isEmpty { hideCompletions(); return }
            if word.isEmpty && !before.hasSuffix(" ") { hideCompletions(); return }
        }
        pendingTabCompletion = fromTab
        _ = session.requestCompletions(for: before)
    }

    private var currentWord: String {
        let str = textView.string
        let sel = textView.selectedRange()
        let r = ShellLexer.currentWordRange(in: str, cursor: sel.location)
        return (str as NSString).substring(with: r)
    }

    func completionsReceived(_ result: CompletionResult) {
        let fromTab = pendingTabCompletion
        pendingTabCompletion = false
        let word = currentWord
        var items = result.items
        // Hide the exact current word as the only match — nothing to offer.
        if items.count == 1, items[0].insertion == word || items[0].display == word, !fromTab {
            hideCompletions()
            return
        }
        items = Array(items.prefix(300)).enumerated().map { var i = $0.element; i.id = $0.offset; return i }
        if fromTab {
            if items.count == 1 {
                accept(items[0])
                return
            }
            // Insert the longest common prefix like zsh does.
            if let common = Self.commonPrefix(items.map(\.insertion)), common.count > word.count, common.hasPrefix(word) || word.isEmpty {
                replaceCurrentWord(with: common, appendSpace: false)
            }
        } else {
            let s = SettingsStore.shared.settings
            if !s.completionsWhileTyping && !completion.isVisible { return }
            let endsWithSpace = (textView.string as NSString).substring(to: textView.selectedRange().location).hasSuffix(" ")
            if word.isEmpty && (!endsWithSpace || items.count > 80) { hideCompletions(); return }
        }
        completion.workingDirectory = session.workingDirectory
        completion.showPreview = SettingsStore.shared.settings.completionPreview
        DebugCommands.trace("show \(items.count) word=\(word)")
        completion.show(items, mode: .completions)
        textView.ghostText = nil
        onCompletionVisibilityChange?()
    }

    private func filterVisibleCompletions() {
        let word = currentWord.lowercased()
        guard !word.isEmpty else { return }
        let filtered = completion.items.filter {
            $0.insertion.lowercased().hasPrefix(word) || $0.display.lowercased().hasPrefix(word)
        }
        if filtered.isEmpty { return }
        completion.items = filtered.enumerated().map { var i = $0.element; i.id = $0.offset; return i }
        completion.selectedIndex = 0
    }

    static func commonPrefix(_ strings: [String]) -> String? {
        guard var prefix = strings.first else { return nil }
        for s in strings.dropFirst() {
            while !s.hasPrefix(prefix) { prefix.removeLast() }
            if prefix.isEmpty { return nil }
        }
        return prefix
    }

    func accept(_ item: CompletionItem) {
        if completion.mode == .history {
            hideCompletions()
            text = item.insertion
            return
        }
        let noSpace = item.isDirectory || item.insertion.hasSuffix("/") || item.insertion.hasSuffix("=")
            || item.insertion.hasSuffix(":")
        hideCompletions()
        replaceCurrentWord(with: item.insertion, appendSpace: !noSpace)
        if item.isDirectory {
            // Keep drilling into the directory.
            requestCompletionsNow(fromTab: false)
        }
    }

    private func replaceCurrentWord(with replacement: String, appendSpace: Bool) {
        let str = textView.string
        let sel = textView.selectedRange()
        let range = ShellLexer.currentWordRange(in: str, cursor: sel.location)
        var insertion = replacement
        let after = (str as NSString).substring(from: sel.location)
        if appendSpace && !after.hasPrefix(" ") { insertion += " " }
        suppressCompletionOnce = true
        textView.insertText(insertion, replacementRange: range)
    }

    func hideCompletions() {
        guard completion.isVisible else { return }
        DebugCommands.trace("hide")
        completion.hide()
        onCompletionVisibilityChange?()
        updateGhost()
    }

    // MARK: History search (⌃R)

    private func showHistorySearch() {
        completion.query = textView.string
        refreshHistorySearch()
        completion.mode = .history
        completion.isVisible = true
        completion.userNavigated = true
        textView.ghostText = nil
        onCompletionVisibilityChange?()
    }

    private func refreshHistorySearch() {
        completion.query = textView.string
        let results = HistoryStore.shared.search(textView.string, limit: 150)
        completion.items = results.enumerated().map {
            CompletionItem(id: $0.offset, insertion: $0.element, display: $0.element.replacingOccurrences(of: "\n", with: " ⏎ "),
                           description: "", tag: "history", isDirectory: false, isFile: false)
        }
        completion.selectedIndex = 0
        completion.mode = .history
        if completion.items.isEmpty { completion.isVisible = false }
    }
}

/// Transient feedback for the Copy button.
@MainActor
@Observable
final class EditorBarState {
    /// The ghost text is a suggested fix for the last command.
    var suggestedFix = false
    var flashMessage: String?
    var flashSuccess = true
    @ObservationIgnored private var clearWork: DispatchWorkItem?

    func flash(_ message: String, success: Bool) {
        flashMessage = message
        flashSuccess = success
        clearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flashMessage = nil }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }
}

/// Bar above the input: context chips (directory, git branch, last status)
/// and the Copy split button.
struct EditorContextBar: View {
    let session: TerminalSession
    let bar: EditorBarState
    let onCopy: (InputEditorView.CopyKind) -> Void

    var body: some View {
        let palette = EditorPalette.current
        let theme = ConfigController.shared.theme
        HStack(spacing: 6) {
            if SettingsStore.shared.settings.showContextBar {
                chip(icon: "folder", text: session.abbreviatedDirectory, color: Color(nsColor: theme.palette[4].nsColor), palette: palette)
                    .onTapGesture {
                        if let dir = session.workingDirectory {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir)
                        }
                    }
                    .help("Reveal in Finder")
                if let branch = session.gitBranch {
                    chip(icon: "arrow.triangle.branch", text: branch, color: Color(nsColor: theme.palette[5].nsColor), palette: palette)
                }
                if let code = session.lastExitCode {
                    let ok = code == 0
                    let dur = session.lastDuration.map { " · " + TerminalSession.format(duration: $0) } ?? ""
                    chip(icon: ok ? "checkmark" : "xmark", text: (ok ? "" : "exit \(code)") + dur,
                         color: Color(nsColor: theme.palette[ok ? 2 : 1].nsColor), palette: palette)
                }
            }
            Spacer()
            if session.state == .starting {
                ProgressView().controlSize(.mini)
            }
            if bar.suggestedFix, bar.flashMessage == nil {
                Label("Suggested fix · → to accept", systemImage: "sparkles")
                    .foregroundStyle(palette.dim)
                    .help("Suggested by Apple Intelligence on this Mac. Esc dismisses it.")
            }
            if let message = bar.flashMessage {
                Text(message)
                    .foregroundStyle(bar.flashSuccess ? Color(nsColor: theme.palette[2].nsColor) : palette.dim)
                    .transition(.opacity)
            }
            AgentLaunchButton(session: session, bar: bar, palette: palette)
            CopyMenuButton(palette: palette, copied: bar.flashMessage != nil && bar.flashSuccess, onCopy: onCopy)
        }
        .font(.system(size: 11, weight: .medium))
        .animation(.easeOut(duration: 0.15), value: bar.flashMessage)
    }

    private func chip(icon: String, text: String, color: Color, palette: EditorPalette) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(color)
            if !text.isEmpty {
                Text(text).foregroundStyle(palette.foreground.opacity(0.85)).lineLimit(1).truncationMode(.head)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(palette.surface))
        .overlay(Capsule().strokeBorder(palette.border, lineWidth: 0.5))
    }
}

/// "Copy" with a dropdown: click copies the command; the menu offers the
/// last command and the last command's output.
struct CopyMenuButton: View {
    let palette: EditorPalette
    let copied: Bool
    let onCopy: (InputEditorView.CopyKind) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button { onCopy(.command) } label: {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    Text("Copy")
                }
                .padding(.leading, 8)
                .padding(.trailing, 6)
                .frame(height: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy command")

            Rectangle().fill(palette.border).frame(width: 1, height: 12)

            Menu {
                Button("Copy Command") { onCopy(.command) }
                Button("Copy Last Command") { onCopy(.lastCommand) }
                Button("Copy Last Output") { onCopy(.lastOutput) }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 5)
            .frame(height: 20)
            .help("More copy options")
            .accessibilityLabel("More copy options")
        }
        .foregroundStyle(palette.foreground.opacity(0.85))
        .background(Capsule().fill(hovering ? palette.selection : palette.surface))
        .overlay(Capsule().strokeBorder(palette.border, lineWidth: 0.5))
        .onHover { hovering = $0 }
    }
}

/// "Claude" with a dropdown: click starts the default agent in this pane;
/// in a git repository the menu also starts it in a worktree: a new branch
/// (named in the picker, or random) off the default branch, or an existing branch.
struct AgentLaunchButton: View {
    let session: TerminalSession
    let bar: EditorBarState
    let palette: EditorPalette
    @State private var hovering = false

    var body: some View {
        let agent = SettingsStore.shared.settings.defaultAgent
        let inRepo = session.gitBranch != nil
        HStack(spacing: 0) {
            Button { launch(.here) } label: {
                HStack(spacing: 4) {
                    if agent == .claude { ClaudeLogo(size: 11) } else { Image(systemName: "sparkles") }
                    Text(agent.shortName)
                }
                .padding(.leading, 8)
                .padding(.trailing, 6)
                .frame(height: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Start \(agent.displayName) here")

            Rectangle().fill(palette.border).frame(width: 1, height: 12)

            Menu {
                Button("Start \(agent.shortName) Here") { launch(.here) }
                if inRepo {
                    Button("Start \(agent.shortName) in Worktree…") { pickBranch(agent) }
                    Button("Start \(agent.shortName) in New Worktree (Random Name)") { launch(.worktree) }
                } else {
                    Text("Worktree options need a git repository")
                }
                Divider()
                Button("Default Agent: \(agent.displayName)…") { SettingsWindowController.shared.show(pane: .integrations) }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 5)
            .frame(height: 20)
            .help("More ways to start \(agent.displayName)")
            .accessibilityLabel("More ways to start \(agent.displayName)")
        }
        .foregroundStyle(palette.foreground.opacity(0.85))
        .background(Capsule().fill(hovering ? palette.selection : palette.surface))
        .overlay(Capsule().strokeBorder(palette.border, lineWidth: 0.5))
        .onHover { hovering = $0 }
    }

    private func launch(_ mode: AgentLauncher.Mode) {
        AgentLauncher.start(mode, from: session) { [bar] message, ok in bar.flash(message, success: ok) }
    }

    private func pickBranch(_ agent: CodingAgent) {
        guard let controller = AgentLauncher.controller(for: session) else { return }
        BranchPicker.show(directory: session.workingDirectory ?? NSHomeDirectory(), agent: agent, in: controller) { choice in
            switch choice {
            case .create(let name): launch(.newBranch(name))
            case .existing(let b): launch(.existingBranch(name: b.name, remote: b.remote))
            }
        }
    }
}
