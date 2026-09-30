import AppKit
import SwiftUI

/// Hosts one session: the terminal surface, the Warp-style input editor
/// (pinned top or bottom), and overlays (completions, find, link hover).
@MainActor
final class PaneView: NSView, TerminalSessionUI {
    let session: TerminalSession
    let editor: InputEditorView
    private var popupHost: NSHostingView<CompletionPopupView>?
    private var findHost: NSHostingView<FindBar>?
    private let dimView = PassthroughView()
    private let linkOverlay = LinkOverlayView(frame: .zero)
    private var linkTimer: Timer?
    private var occlusionObserver: NSObjectProtocol?
    private var activationObservers: [NSObjectProtocol] = []
    private var lastLinkText = ""
    private var linkRefreshWork: DispatchWorkItem?
    private var lastEditorHeight: CGFloat = -1
    private var lastLinkDirectory: String?
    private let fileChecks = FileCheckCache()
    private let linkLabel = NSTextField(labelWithString: "")
    private var editorVisible = false
    private var claudeHost: NSHostingView<ClaudePaneView>?
    private(set) var claudeComposer = ClaudeComposerModel()
    private var hideEditorWork: DispatchWorkItem?

    var onFocus: ((PaneView) -> Void)?
    var isActivePane = true {
        didSet { updateDim() }
    }
    var showsDimming = false {
        didSet { updateDim() }
    }

    init(session: TerminalSession) {
        self.session = session
        editor = InputEditorView(session: session)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true

        addSubview(session.surfaceView)
        addSubview(linkOverlay)
        addSubview(editor)
        dimView.wantsLayer = true
        addSubview(dimView)

        linkLabel.font = .systemFont(ofSize: 11)
        linkLabel.wantsLayer = true
        linkLabel.drawsBackground = true
        linkLabel.isBordered = false
        linkLabel.isHidden = true
        linkLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(linkLabel)

        session.ui = self
        session.surfaceView.keyInterceptor = { [weak self] event in self?.interceptTerminalKey(event) ?? false }
        session.surfaceView.onFocusChange = { [weak self] focused in
            guard let self, focused else { return }
            self.onFocus?(self)
        }
        session.surfaceView.onMouseDown = { [weak self] in
            guard let self else { return }
            self.onFocus?(self)
        }
        session.surfaceView.onHoverURLChange = { [weak self] url in self?.showLink(url) }
        session.surfaceView.onPointerMove = { [weak self] point, flags in
            guard let self, SettingsStore.shared.settings.highlightLinks else { return }
            self.linkOverlay.mouseMoved(to: point, modifiers: flags)
            // Our hint replaces the bottom-left URL label for http(s) links.
            if self.linkOverlay.hovered != nil { self.linkLabel.isHidden = true }
        }
        // ⌘-click on anything Shell underlined: URLs open, paths reveal in Finder.
        session.surfaceView.linkClickHandler = { [weak self] point, flags in
            guard let self, SettingsStore.shared.settings.highlightLinks, flags.contains(.command),
                  let link = self.linkOverlay.link(at: point) else { return false }
            link.activate()
            return true
        }
        session.surfaceView.onScroll = { [weak self] in self?.scheduleLinkRefresh() }
        editor.onHeightChange = { [weak self] in
            guard let self else { return }
            // Fires on every keystroke; only re-lay out when the height moves.
            let h = self.editor.preferredHeight
            if h != self.lastEditorHeight {
                self.lastEditorHeight = h
                self.needsLayout = true
            } else if self.editor.completion.isVisible {
                self.layoutPopup() // filtered items may change its size
            }
        }
        editor.onCompletionVisibilityChange = { [weak self] in self?.updatePopup() }
        editor.onFocus = { [weak self] in
            guard let self else { return }
            self.onFocus?(self)
        }

        editorVisible = wantsEditor
        editor.isHidden = !editorVisible
        applyTheme()
        updateClaudeView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var wantsEditor: Bool {
        guard SettingsStore.shared.settings.inputEditor else { return false }
        switch session.state {
        case .idle, .starting: return true
        case .running, .unmanaged: return false
        }
    }

    func applyTheme() {
        let t = ConfigController.shared.theme
        let opacity = SettingsStore.shared.settings.backgroundOpacity
        layer?.backgroundColor = (session.backgroundOverride ?? t.background.nsColor).withAlphaComponent(opacity).cgColor
        dimView.layer?.backgroundColor = t.background.nsColor.withAlphaComponent(0.4).cgColor
        linkOverlay.color = t.accent.nsColor
        linkLabel.backgroundColor = t.background.mixed(with: t.foreground, 0.1).nsColor
        linkLabel.textColor = t.foreground.nsColor
        editor.applyTheme()
        popupHost?.rootView = makePopup()
    }

    private func updateDim() {
        dimView.isHidden = !(showsDimming && !isActivePane && SettingsStore.shared.settings.dimUnfocusedSplits)
    }

    // MARK: Focus

    /// Gives keyboard focus to the editor when the shell is at a prompt,
    /// otherwise to the terminal.
    func focus() {
        guard let window else { return }
        if claudeHost != nil {
            claudeComposer.focus()
            return
        }
        if editorVisible && session.acceptsEditorInput || (editorVisible && session.state == .starting) {
            window.makeFirstResponder(editor.textView)
        } else {
            window.makeFirstResponder(session.surfaceView)
        }
    }

    var containsFirstResponder: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        if let claudeHost, responder.isDescendant(of: claudeHost) { return true }
        return responder === session.surfaceView || responder.isDescendant(of: editor)
    }

    /// Typing into the terminal while the shell is idle goes to the editor.
    private func interceptTerminalKey(_ event: NSEvent) -> Bool {
        guard claudeHost == nil, editorVisible, session.acceptsEditorInput || session.state == .starting else { return false }
        window?.makeFirstResponder(editor.textView)
        editor.textView.keyDown(with: event)
        return true
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let b = bounds
        var terminalFrame = b
        if editorVisible {
            let h = min(editor.preferredHeight, b.height * 0.6)
            if SettingsStore.shared.settings.inputPosition == .top {
                editor.frame = NSRect(x: 0, y: 0, width: b.width, height: h)
                terminalFrame = NSRect(x: 0, y: h, width: b.width, height: b.height - h)
            } else {
                editor.frame = NSRect(x: 0, y: b.height - h, width: b.width, height: h)
                terminalFrame = NSRect(x: 0, y: 0, width: b.width, height: b.height - h)
            }
        }
        if session.surfaceView.frame != terminalFrame { session.surfaceView.frame = terminalFrame }
        if linkOverlay.frame != terminalFrame {
            linkOverlay.frame = terminalFrame
            scheduleLinkRefresh()
        }
        dimView.frame = b
        claudeHost?.frame = b
        layoutPopup()
        layoutFindBar()
        if !linkLabel.isHidden {
            linkLabel.sizeToFit()
            let w = min(linkLabel.frame.width + 12, b.width - 16)
            linkLabel.frame = NSRect(x: 8, y: terminalFrame.maxY - 24, width: w, height: 18)
        }
    }

    private func setEditorVisible(_ visible: Bool) {
        guard visible != editorVisible else { return }
        editorVisible = visible
        editor.isHidden = !visible || claudeHost != nil
        if !visible { editor.hideCompletions() }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    // MARK: TerminalSessionUI

    func sessionStateDidChange(_ session: TerminalSession) {
        hideEditorWork?.cancel()
        let wasFocused = containsFirstResponder
        switch session.state {
        case .running:
            // Short commands finish before the editor would visibly hide; wait
            // a beat to avoid flicker, but hand keys to the terminal immediately.
            if wasFocused { window?.makeFirstResponder(session.surfaceView) }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.session.state == .running else { return }
                self.setEditorVisible(false)
            }
            hideEditorWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        case .idle:
            setEditorVisible(wantsEditor)
            editor.refreshContext()
            editor.shellBecameIdle()
            if wasFocused { focus() }
        case .unmanaged, .starting:
            setEditorVisible(wantsEditor)
            if wasFocused { focus() }
        }
    }

    func sessionInsertIntoEditor(_ text: String) {
        editor.insert(text)
    }

    func sessionCompletionsReceived(_ result: CompletionResult) {
        editor.completionsReceived(result)
    }

    func sessionSearchDidChange(_ session: TerminalSession) {
        updateFindBar()
    }

    func sessionAppearanceDidChange(_ session: TerminalSession) {
        applyTheme()
    }

    func sessionNativeClaudeDidChange(_ session: TerminalSession) {
        let wasFocused = containsFirstResponder
        updateClaudeView()
        // The composer's text view exists only after SwiftUI lays out the host.
        if wasFocused || window?.firstResponder === window || window?.firstResponder == nil {
            DispatchQueue.main.async { [weak self] in
                self?.layoutSubtreeIfNeeded()
                self?.focus()
            }
        }
    }

    /// Shows the native Claude view over the terminal while it's open.
    private func updateClaudeView() {
        if let claude = session.nativeClaude {
            if claudeHost?.rootView.claude !== claude {
                claudeHost?.removeFromSuperview()
                claudeComposer = ClaudeComposerModel()
                let composer = claudeComposer
                claude.insertIntoPrompt = { [weak composer] text in composer?.insert(text) }
                let host = NSHostingView(rootView: ClaudePaneView(
                    claude: claude, composer: composer,
                    onClose: { [weak self] in self?.session.endNativeClaude() },
                    onContinueInTerminal: { [weak self] in self?.session.continueClaudeInTerminal() },
                    onToggleExplorer: { [weak claude] in
                        guard let claude else { return }
                        claude.showExplorer.toggle()
                        SettingsStore.shared.settings.claudeFileExplorer = claude.showExplorer
                    },
                    onFocus: { [weak self] in
                        guard let self else { return }
                        self.onFocus?(self)
                    }))
                host.sizingOptions = []
                // Clicking anywhere in the view focuses this pane.
                let click = NSClickGestureRecognizer(target: self, action: #selector(claudeClicked))
                click.delaysPrimaryMouseButtonEvents = false
                host.addGestureRecognizer(click)
                addSubview(host, positioned: .below, relativeTo: dimView)
                claudeHost = host
            }
            session.surfaceView.isHidden = true
            linkOverlay.isHidden = true
            editor.isHidden = true
            editor.hideCompletions()
        } else if let host = claudeHost {
            host.removeFromSuperview()
            claudeHost = nil
            session.surfaceView.isHidden = false
            linkOverlay.isHidden = false
            editor.isHidden = !editorVisible
        }
        needsLayout = true
    }

    @objc private func claudeClicked() { onFocus?(self) }

    func settingsChanged() {
        lastLinkText = ""
        updateLinkTimer()
        refreshLinks()
        setEditorVisible(wantsEditor)
        applyTheme()
        needsLayout = true
    }

    // MARK: Completion popup

    private func makePopup() -> CompletionPopupView {
        let s = SettingsStore.shared.settings
        let size = CGFloat(s.editorFontSize > 0 ? s.editorFontSize : s.fontSize) - 1
        return CompletionPopupView(model: editor.completion, onAccept: { [weak self] item in
            self?.editor.accept(item)
        }, fontName: s.fontFamily.isEmpty ? nil : editor.editorFont.fontName, fontSize: size)
    }

    private func updatePopup() {
        if editor.completion.isVisible {
            if popupHost == nil {
                let host = NSHostingView(rootView: makePopup())
                host.wantsLayer = true
                addSubview(host)
                popupHost = host
            }
            popupHost?.isHidden = false
            layoutPopup()
        } else {
            popupHost?.isHidden = true
        }
    }

    private func layoutPopup() {
        guard let host = popupHost, !host.isHidden else { return }
        let size = host.fittingSize
        let w = min(size.width, bounds.width - 24)
        let h = min(max(size.height, 40), 262)
        let x: CGFloat = 16
        if SettingsStore.shared.settings.inputPosition == .top {
            host.frame = NSRect(x: x, y: editor.frame.maxY + 4, width: w, height: h)
        } else {
            host.frame = NSRect(x: x, y: max(4, editor.frame.minY - h - 4), width: w, height: h)
        }
    }

    // MARK: Find bar

    func showFind() {
        if session.search == nil {
            session.surfaceView.perform("start_search")
            if session.search == nil { session.search = SearchState() }
        }
        updateFindBar()
    }

    private func updateFindBar() {
        if session.search != nil {
            if findHost == nil {
                let host = NSHostingView(rootView: FindBar(session: session))
                addSubview(host)
                findHost = host
            }
            findHost?.isHidden = false
            layoutFindBar()
        } else if let host = findHost {
            host.removeFromSuperview()
            findHost = nil
            focus()
        }
    }

    private func layoutFindBar() {
        guard let host = findHost else { return }
        let w: CGFloat = min(360, bounds.width - 20)
        let y = SettingsStore.shared.settings.inputPosition == .top && editorVisible ? editor.frame.maxY + 8 : 8
        host.frame = NSRect(x: bounds.width - w - 10, y: y, width: w, height: 36)
    }

    // MARK: Links

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        activationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        activationObservers = []
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateLinkTimer() }
            }
            // Links are only clickable in the active app, so don't poll in the background.
            activationObservers = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification].map {
                NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateLinkTimer() }
                }
            }
        }
        updateLinkTimer()
    }

    // Hidden tabs (an ancestor container is hidden) and covered windows don't poll.
    override func viewDidHide() {
        super.viewDidHide()
        updateLinkTimer()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateLinkTimer()
    }

    /// Terminal output doesn't notify us, so poll the (cheap) viewport text,
    /// but only while this pane can actually be seen, the app is frontmost and
    /// link highlighting is on.
    private func updateLinkTimer() {
        let visible = window != nil && !isHiddenOrHasHiddenAncestor && window?.occlusionState.contains(.visible) == true
            && NSApp.isActive && SettingsStore.shared.settings.highlightLinks
        guard visible != (linkTimer != nil) else { return }
        linkTimer?.invalidate()
        linkTimer = nil
        guard visible else {
            if !linkOverlay.links.isEmpty { linkOverlay.update(links: []) }
            lastLinkText = ""
            return
        }
        linkTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLinks() }
        }
        linkTimer?.tolerance = 0.15
        refreshLinks()
    }

    var debugLinks: [DetectedLink] { linkOverlay.links }
    func debugHover(_ link: DetectedLink?) {
        let p = link?.rects.first.map { CGPoint(x: $0.midX, y: $0.midY) }
        linkOverlay.mouseMoved(to: p, modifiers: [])
    }

    /// Coalesces refreshes during scrolling and live resize, where the
    /// viewport changes on every event. Stale underlines are hidden meanwhile.
    private func scheduleLinkRefresh(after delay: TimeInterval = 0.12) {
        linkRefreshWork?.cancel()
        if !linkOverlay.links.isEmpty { linkOverlay.update(links: []) }
        lastLinkText = ""
        let work = DispatchWorkItem { [weak self] in self?.refreshLinks() }
        linkRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func refreshLinks() {
        guard SettingsStore.shared.settings.highlightLinks, !isHiddenOrHasHiddenAncestor,
              window?.isVisible == true, window?.isMiniaturized == false,
              window?.occlusionState.contains(.visible) == true else {
            if !linkOverlay.links.isEmpty { linkOverlay.update(links: []) }
            lastLinkText = "" // detect again once visible
            return
        }
        let text = session.surfaceView.readText()
        let cwd = session.workingDirectory
        guard text != lastLinkText || cwd != lastLinkDirectory else { return }
        lastLinkText = text
        lastLinkDirectory = cwd
        guard let g = LinkDetector.geometry(for: session.surfaceView) else {
            linkOverlay.update(links: [])
            return
        }
        let resolver = LinkDetector.fileSystemResolver(cwd: cwd, cache: fileChecks)
        linkOverlay.update(links: LinkDetector.detect(text: text, geometry: g, resolvePath: resolver))
    }

    private func showLink(_ url: String?) {
        linkLabel.stringValue = url ?? ""
        linkLabel.isHidden = url == nil
        needsLayout = true
    }
}

/// A view that never intercepts mouse events (for overlays).
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Inline find bar backed by Ghostty's search.
struct FindBar: View {
    let session: TerminalSession
    @State private var needle = ""
    @FocusState private var focused: Bool

    var body: some View {
        let palette = EditorPalette.current
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(palette.dim)
            TextField("Find", text: $needle)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { session.surfaceView.perform("navigate_search:next") }
                .onChange(of: needle) { _, new in
                    session.surfaceView.perform(new.isEmpty ? "end_search" : "search:\(new)")
                    if new.isEmpty { session.search = SearchState() }
                }
            if let total = session.search?.total {
                let sel = session.search?.selected.map { "\($0 + 1)" } ?? "–"
                Text("\(sel)/\(total)").font(.system(size: 11).monospacedDigit()).foregroundStyle(palette.dim)
            }
            Button { session.surfaceView.perform("navigate_search:previous") } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
            Button { session.surfaceView.perform("navigate_search:next") } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
            Button {
                session.surfaceView.perform("end_search")
                session.search = nil
            } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
        }
        .font(.system(size: 12))
        .foregroundStyle(palette.foreground)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8).fill(palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.border))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        .onAppear {
            needle = session.search?.needle ?? ""
            focused = true
        }
    }
}
