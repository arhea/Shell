import AppKit
import SwiftUI
import XCTest
@testable import Shell

@MainActor
private func allSubviews(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(allSubviews) }

@MainActor
private func paneKeyEvent(_ chars: String, window: NSWindow?) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                     windowNumber: window?.windowNumber ?? 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                     isARepeat: false, keyCode: 0)!
}

// MARK: - Pane view

@MainActor
final class PaneViewTests: XCTestCase {
    private func pane(_ fx: TabsFixture, idle: Bool = true) throws -> (TerminalTab, TerminalSession, PaneView) {
        let tab = fx.tab("Pane", idle: idle)
        let session = try XCTUnwrap(tab.focusedSession)
        let pane = try XCTUnwrap(fx.controller.paneView(for: session))
        return (tab, session, pane)
    }

    func testEditorShowsAtThePromptAndHidesWhileACommandRuns() throws {
        let fx = try tabsFixture()
        let (_, session, pane) = try pane(fx)
        render(pane, size: CGSize(width: 800, height: 600))
        XCTAssertFalse(pane.editor.isHidden)
        XCTAssertEqual(pane.editor.frame.maxY, 600, accuracy: 0.5, "pinned to the bottom")
        XCTAssertEqual(session.surfaceView.frame.minY, 0)
        session.commandStarted("sleep 5", directory: nil)
        XCTAssertTrue(waitUntil(timeout: 2) { pane.editor.isHidden })
        render(pane, size: CGSize(width: 800, height: 600))
        XCTAssertEqual(session.surfaceView.frame, pane.bounds)
        session.promptReady(exitCode: 0, directory: fx.dir, branch: nil, duration: 5)
        XCTAssertFalse(pane.editor.isHidden)
    }

    func testAQuickCommandDoesntHideTheEditor() throws {
        let fx = try tabsFixture()
        let (_, session, pane) = try pane(fx)
        session.commandStarted("true", directory: nil)
        session.promptReady(exitCode: 0, directory: fx.dir, branch: nil, duration: 0.01)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertFalse(pane.editor.isHidden)
    }

    func testEditorCanBePinnedToTheTopOrTurnedOff() throws {
        let fx = try tabsFixture()
        let (_, session, pane) = try pane(fx)
        SettingsStore.shared.settings.inputPosition = .top
        pane.settingsChanged()
        render(pane, size: CGSize(width: 800, height: 600))
        XCTAssertEqual(pane.editor.frame.minY, 0)
        XCTAssertEqual(session.surfaceView.frame.minY, pane.editor.frame.maxY)
        SettingsStore.shared.settings.inputEditor = false
        pane.settingsChanged()
        XCTAssertTrue(pane.editor.isHidden)
        render(pane, size: CGSize(width: 800, height: 600))
        XCTAssertEqual(session.surfaceView.frame, pane.bounds)
    }

    func testUnmanagedShellsHaveNoEditor() throws {
        let fx = try tabsFixture()
        SettingsStore.shared.settings.shellIntegration = false
        let (_, _, pane) = try pane(fx, idle: false)
        XCTAssertTrue(pane.editor.isHidden)
        pane.sessionStateDidChange(pane.session) // .unmanaged
        XCTAssertTrue(pane.editor.isHidden)
    }

    func testFocusGoesToTheEditorAtAPromptAndTheTerminalOtherwise() throws {
        let fx = try tabsFixture()
        let (_, session, pane) = try pane(fx)
        let window = try XCTUnwrap(fx.controller.window)
        pane.focus()
        XCTAssertTrue(window.firstResponder === pane.editor.textView)
        XCTAssertTrue(pane.containsFirstResponder)
        session.commandStarted("vim", directory: nil)
        XCTAssertTrue(window.firstResponder === session.surfaceView, "keys go to the program right away")
        XCTAssertTrue(pane.containsFirstResponder)
        pane.focus()
        XCTAssertTrue(window.firstResponder === session.surfaceView)
        // Back at the prompt, focus returns to the editor.
        session.promptReady(exitCode: 0, directory: fx.dir, branch: nil, duration: 1)
        XCTAssertTrue(window.firstResponder === pane.editor.textView)
        window.makeFirstResponder(nil)
        XCTAssertFalse(pane.containsFirstResponder)
    }

    func testFocusWithoutAWindowDoesNothing() {
        let session = TerminalSession(workingDirectory: NSTemporaryDirectory())
        defer { session.close() }
        let pane = PaneView(session: session)
        pane.focus()
        XCTAssertFalse(pane.containsFirstResponder)
    }

    func testTypingIntoTheTerminalAtAPromptGoesToTheEditor() throws {
        let fx = try tabsFixture()
        let (_, session, pane) = try pane(fx)
        let intercept = try XCTUnwrap(session.surfaceView.keyInterceptor)
        XCTAssertTrue(intercept(paneKeyEvent("l", window: fx.controller.window)))
        XCTAssertEqual(pane.editor.text, "l")
        session.commandStarted("cat", directory: nil)
        XCTAssertTrue(waitUntil(timeout: 2) { pane.editor.isHidden })
        XCTAssertFalse(intercept(paneKeyEvent("x", window: fx.controller.window)), "a running program gets its keys")
    }

    func testSurfaceCallbacksFocusThePaneAndShowHoveredLinks() throws {
        let fx = try tabsFixture()
        fx.tab("Other")
        let (tab, session, pane) = try pane(fx)
        var focused = 0
        let original = pane.onFocus
        pane.onFocus = { focused += 1; original?($0) }
        session.surfaceView.onFocusChange?(false)
        session.surfaceView.onFocusChange?(true)
        session.surfaceView.onMouseDown?()
        pane.editor.onFocus?()
        XCTAssertEqual(focused, 3)
        XCTAssertEqual(fx.workspace.selectedTabID, tab.id)

        session.surfaceView.onHoverURLChange?("https://example.com/a/very/long/path")
        render(pane, size: CGSize(width: 800, height: 600))
        let label = try XCTUnwrap(pane.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("https://") })
        XCTAssertFalse(label.isHidden)
        XCTAssertEqual(label.frame.minX, 8)
        session.surfaceView.onHoverURLChange?(nil)
        XCTAssertTrue(label.isHidden)

        session.surfaceView.onPointerMove?(CGPoint(x: 10, y: 10), [])
        session.surfaceView.onScroll?()
        XCTAssertFalse(session.surfaceView.linkClickHandler?(CGPoint(x: 10, y: 10), []) ?? true)
        XCTAssertFalse(session.surfaceView.linkClickHandler?(CGPoint(x: 10, y: 10), .command) ?? true, "nothing underlined there")
        XCTAssertTrue(pane.debugLinks.isEmpty)
        pane.debugHover(nil)
        SettingsStore.shared.settings.highlightLinks = false
        session.surfaceView.onPointerMove?(CGPoint(x: 10, y: 10), [])
        pane.refreshLinks()
    }

    func testDimsInactiveSplitsWhenEnabled() throws {
        let fx = try tabsFixture()
        let (_, _, pane) = try pane(fx)
        let dim = try XCTUnwrap(pane.subviews.first { $0 is PassthroughView })
        XCTAssertNil(dim.hitTest(NSPoint(x: 1, y: 1)))
        pane.showsDimming = true
        pane.isActivePane = false
        XCTAssertFalse(dim.isHidden)
        SettingsStore.shared.settings.dimUnfocusedSplits = false
        pane.isActivePane = false
        XCTAssertTrue(dim.isHidden)
        SettingsStore.shared.settings.dimUnfocusedSplits = true
        pane.isActivePane = true
        XCTAssertTrue(dim.isHidden)
    }

    func testCompletionsFromTheShellOpenThePopupAboveOrBelowTheEditor() throws {
        let fx = try tabsFixture()
        let (_, session, pane) = try pane(fx)
        render(pane, size: CGSize(width: 800, height: 600))
        pane.editor.text = "git ch"
        let id = session.requestCompletions(for: "git ch")
        let items = [CompletionItem(id: 0, insertion: "checkout", display: "checkout", description: "switch branches", tag: "git-commands",
                                    isDirectory: false, isFile: false),
                     CompletionItem(id: 1, insertion: "cherry-pick", display: "cherry-pick", description: "", tag: "git-commands",
                                    isDirectory: false, isFile: false)]
        session.completionsReceived(CompletionResult(requestID: id - 1, items: items)) // stale: ignored
        XCTAssertFalse(pane.editor.completion.isVisible)
        session.completionsReceived(CompletionResult(requestID: id, items: items))
        XCTAssertTrue(pane.editor.completion.isVisible)
        let popup = try XCTUnwrap(pane.subviews.first { $0 is NSHostingView<CompletionPopupView> })
        XCTAssertFalse(popup.isHidden)
        XCTAssertLessThanOrEqual(popup.frame.maxY, pane.editor.frame.minY, "above a bottom editor")
        // Typing re-lays out the popup without changing the editor height.
        pane.editor.textView.insertText("e", replacementRange: pane.editor.textView.selectedRange())
        SettingsStore.shared.settings.inputPosition = .top
        pane.settingsChanged()
        render(pane, size: CGSize(width: 800, height: 600))
        XCTAssertGreaterThanOrEqual(popup.frame.minY, pane.editor.frame.maxY, "below a top editor")
        pane.editor.hideCompletions()
        XCTAssertTrue(popup.isHidden)
    }

    func testInsertIntoEditorAndAppearanceChanges() throws {
        let fx = try tabsFixture()
        let (_, session, pane) = try pane(fx)
        session.insertIntoEditor("/tmp/file.txt")
        XCTAssertEqual(pane.editor.text, "/tmp/file.txt")
        pane.sessionAppearanceDidChange(session)
        SettingsStore.shared.settings.fontFamily = "Menlo"
        pane.applyTheme()
    }

    func testFindBarOpensAndCloses() throws {
        let fx = try tabsFixture()
        let (_, session, pane) = try pane(fx)
        pane.showFind()
        XCTAssertNotNil(session.search)
        render(pane, size: CGSize(width: 800, height: 600))
        let bar = try XCTUnwrap(pane.subviews.first { $0 is NSHostingView<FindBar> })
        XCTAssertEqual(bar.frame.width, 360)
        XCTAssertEqual(bar.frame.minY, 8)
        pane.showFind() // already open
        SettingsStore.shared.settings.inputPosition = .top
        pane.settingsChanged()
        render(pane, size: CGSize(width: 800, height: 600))
        XCTAssertEqual(bar.frame.minY, pane.editor.frame.maxY + 8)
        session.search = nil
        XCTAssertNil(bar.superview)
    }

    func testFindBarControls() throws {
        let fx = try tabsFixture()
        let (_, session, _) = try pane(fx)
        session.search = SearchState(needle: "error", total: 12, selected: 2)
        let w = claudeWindow(FindBar(session: session), width: 360, height: 36)
        session.search?.selected = nil
        w.layout()
        w.pressAll()
        // Esc is the close button's shortcut.
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            w.window.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: w.window.windowNumber, context: nil, characters: "\u{1B}",
                                                charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!)
        }
        w.layout(settle: 0.02)
        XCTAssertNil(session.search, "the close button ends the search")
        session.search = SearchState()
        let field = try XCTUnwrap(w.subview(NSTextField.self))
        w.type("warn", into: field)
        w.layout()
    }

    func testNativeClaudeCoversTheTerminalAndEditor() throws {
        let fx = try tabsFixture()
        let (_, session, pane) = try pane(fx)
        render(pane, size: CGSize(width: 800, height: 600))
        session.startNativeClaude(ClaudeLaunchRequest(directory: fx.dir, binary: "/usr/bin/false", arguments: ClaudeArguments(), environment: [:]))
        session.nativeClaude?.onEvent = nil
        let host = try XCTUnwrap(pane.subviews.first { $0 is NSHostingView<ClaudePaneView> })
        XCTAssertTrue(session.surfaceView.isHidden)
        XCTAssertTrue(pane.editor.isHidden)
        render(pane, size: CGSize(width: 800, height: 600))
        XCTAssertEqual(host.frame, pane.bounds)
        pane.focus()
        XCTAssertFalse(try XCTUnwrap(session.surfaceView.keyInterceptor)(paneKeyEvent("a", window: fx.controller.window)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        // A second session replaces the view.
        session.startNativeClaude(ClaudeLaunchRequest(directory: fx.dir, binary: "/usr/bin/false", arguments: ClaudeArguments(), environment: [:]))
        session.nativeClaude?.onEvent = nil
        XCTAssertNil(host.superview)
        session.endNativeClaude()
        XCTAssertFalse(pane.subviews.contains { $0 is NSHostingView<ClaudePaneView> })
        XCTAssertFalse(session.surfaceView.isHidden)
        XCTAssertFalse(pane.editor.isHidden)
    }

    func testLinkPollingFollowsVisibility() throws {
        let fx = try tabsFixture()
        let (_, _, pane) = try pane(fx)
        pane.isHidden = true
        pane.isHidden = false
        pane.removeFromSuperview()
        pane.refreshLinks()
        XCTAssertTrue(pane.debugLinks.isEmpty)
    }
}

// MARK: - Split container

@MainActor
final class SplitContainerTests: XCTestCase {
    private var sessions: [TerminalSession] = []

    private func panes(_ n: Int) -> [PaneView] {
        (0..<n).map { _ in
            let s = TerminalSession(workingDirectory: NSTemporaryDirectory())
            sessions.append(s)
            addTeardownBlock { @MainActor in s.close() }
            return PaneView(session: s)
        }
    }

    private func dividers(_ c: SplitContainerView) -> [DividerView] { c.subviews.compactMap { $0 as? DividerView } }

    func testLaysOutSideBySideAndStackedSplits() throws {
        let p = panes(3)
        let container = SplitContainerView()
        let inner = UUID(), outer = UUID()
        let tree = PaneTree.split(id: outer, direction: .horizontal, ratio: 0.5,
                                  first: .leaf(p[0].session.id),
                                  second: .split(id: inner, direction: .vertical, ratio: 0.25, first: .leaf(p[1].session.id), second: .leaf(p[2].session.id)))
        container.update(tree: tree, panes: Dictionary(uniqueKeysWithValues: p.map { ($0.session.id, $0) }), zoomed: nil)
        render(container, size: CGSize(width: 801, height: 401))
        XCTAssertEqual(container.tree, tree)
        XCTAssertEqual(p[0].frame, NSRect(x: 0, y: 0, width: 400, height: 401))
        XCTAssertEqual(p[1].frame, NSRect(x: 401, y: 0, width: 400, height: 100))
        XCTAssertEqual(p[2].frame, NSRect(x: 401, y: 101, width: 400, height: 300))
        XCTAssertTrue(p.allSatisfy(\.showsDimming))
        let ds = dividers(container)
        XCTAssertEqual(ds.count, 2)
        let vertical = try XCTUnwrap(ds.first { $0.direction == .horizontal })
        XCTAssertEqual(vertical.frame, NSRect(x: 396, y: 0, width: 9, height: 401))
        let horizontal = try XCTUnwrap(ds.first { $0.direction == .vertical })
        XCTAssertEqual(horizontal.frame, NSRect(x: 401, y: 96, width: 400, height: 9))

        // Dividers are reused across layouts and recolored together.
        container.dividerColor = .red
        render(container, size: CGSize(width: 1001, height: 401))
        XCTAssertTrue(dividers(container).contains { $0 === vertical })
        XCTAssertTrue(dividers(container).allSatisfy { $0.lineColor == .red })
    }

    func testZoomShowsOnlyOnePaneAndHidesDividers() {
        let p = panes(2)
        let container = SplitContainerView()
        let tree = PaneTree.split(id: UUID(), direction: .horizontal, ratio: 0.5, first: .leaf(p[0].session.id), second: .leaf(p[1].session.id))
        let map = Dictionary(uniqueKeysWithValues: p.map { ($0.session.id, $0) })
        container.update(tree: tree, panes: map, zoomed: nil)
        render(container, size: CGSize(width: 600, height: 400))
        XCTAssertEqual(dividers(container).count, 1)
        container.update(tree: tree, panes: map, zoomed: p[1].session.id)
        render(container, size: CGSize(width: 600, height: 400))
        XCTAssertTrue(p[0].isHidden)
        XCTAssertFalse(p[1].isHidden)
        XCTAssertEqual(p[1].frame, container.bounds)
        XCTAssertFalse(p[0].showsDimming)
        XCTAssertTrue(dividers(container).isEmpty)
        // Unzoomed with one pane closed: it's removed and the divider goes.
        container.update(tree: .leaf(p[1].session.id), panes: [p[1].session.id: p[1]], zoomed: nil)
        render(container, size: CGSize(width: 600, height: 400))
        XCTAssertNil(p[0].superview)
        XCTAssertFalse(p[1].isHidden)
        XCTAssertEqual(p[1].frame, container.bounds)
    }

    func testChangingASplitsDirectionReplacesItsDivider() throws {
        let p = panes(2)
        let container = SplitContainerView()
        let id = UUID()
        let map = Dictionary(uniqueKeysWithValues: p.map { ($0.session.id, $0) })
        container.update(tree: .split(id: id, direction: .horizontal, ratio: 0.5, first: .leaf(p[0].session.id), second: .leaf(p[1].session.id)),
                         panes: map, zoomed: nil)
        render(container, size: CGSize(width: 600, height: 400))
        let first = try XCTUnwrap(dividers(container).first)
        container.update(tree: .split(id: id, direction: .vertical, ratio: 0.5, first: .leaf(p[0].session.id), second: .leaf(p[1].session.id)),
                         panes: map, zoomed: nil)
        render(container, size: CGSize(width: 600, height: 400))
        XCTAssertNil(first.superview)
        XCTAssertEqual(dividers(container).first?.direction, .vertical)
    }

    func testDraggingADividerReportsAClampedRatio() throws {
        let p = panes(2)
        let window = ClaudeTestKeyWindow(contentRect: NSRect(x: -20000, y: -20000, width: 600, height: 400),
                                         styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
        let container = SplitContainerView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = container
        let id = UUID()
        container.update(tree: .split(id: id, direction: .horizontal, ratio: 0.5, first: .leaf(p[0].session.id), second: .leaf(p[1].session.id)),
                         panes: Dictionary(uniqueKeysWithValues: p.map { ($0.session.id, $0) }), zoomed: nil)
        var reported: [(UUID, Double)] = []
        container.onRatioChange = { reported.append(($0, $1)) }
        container.layoutSubtreeIfNeeded()
        let divider = try XCTUnwrap(dividers(container).first)
        func mouse(_ type: NSEvent.EventType, x: CGFloat, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 200), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        divider.mouseDown(with: mouse(.leftMouseDown, x: 300))
        divider.mouseDragged(with: mouse(.leftMouseDragged, x: 150))
        divider.mouseDragged(with: mouse(.leftMouseDragged, x: 1))
        divider.mouseDragged(with: mouse(.leftMouseDragged, x: 599))
        divider.mouseUp(with: mouse(.leftMouseUp, x: 599))
        divider.mouseUp(with: mouse(.leftMouseUp, x: 599, clicks: 2))
        XCTAssertEqual(reported.map(\.0), [id, id, id, id])
        XCTAssertEqual(reported.map(\.1), [0.25, 0.08, 0.92, 0.5])
        divider.resetCursorRects()
        window.invalidateCursorRects(for: divider)
        if let rep = divider.bitmapImageRepForCachingDisplay(in: divider.bounds) { divider.cacheDisplay(in: divider.bounds, to: rep) }
    }

    func testStackedDividerDragsVertically() throws {
        let window = ClaudeTestKeyWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 400),
                                         styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
        let container = SplitContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        window.contentView = container
        let divider = DividerView(splitID: UUID(), direction: .vertical)
        divider.frame = NSRect(x: 0, y: 196, width: 400, height: 9)
        divider.parentRect = container.bounds
        container.addSubview(divider)
        var ratios: [Double] = []
        divider.onDrag = { ratios.append($0) }
        // Window coordinates are bottom-up; the container is flipped.
        let event = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 10, y: 300), modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        divider.mouseDragged(with: event)
        XCTAssertEqual(ratios, [0.25])
        divider.resetCursorRects()
        if let rep = divider.bitmapImageRepForCachingDisplay(in: divider.bounds) { divider.cacheDisplay(in: divider.bounds, to: rep) }
        // Detached from a superview, a drag is ignored.
        divider.removeFromSuperview()
        divider.mouseDragged(with: event)
        XCTAssertEqual(ratios.count, 1)
    }

    func testRealSplitsAndZoomInAWindow() throws {
        let fx = try tabsFixture()
        let tab = fx.tab("Splits")
        fx.controller.split(.horizontal)
        fx.controller.split(.vertical)
        XCTAssertEqual(tab.sessions.count, 3)
        fx.renderWindow()
        let content = try XCTUnwrap(fx.controller.window?.contentView)
        let container = try XCTUnwrap(allSubviews(content).compactMap { $0 as? SplitContainerView }.first { !$0.isHidden })
        XCTAssertEqual(container.tree.leaves.count, 3)
        fx.controller.toggleZoom()
        fx.renderWindow()
        fx.controller.toggleZoom()
        fx.renderWindow()
    }
}

// MARK: - Link overlay

@MainActor
final class LinkOverlayTests: XCTestCase {
    private let url = DetectedLink(target: "https://example.com/docs", text: "https://example.com/docs", kind: .url,
                                   rects: [CGRect(x: 10, y: 40, width: 120, height: 16)])
    private let file = DetectedLink(target: NSHomeDirectory() + "/code/project", text: "~/code/project", kind: .file(isDirectory: true),
                                    rects: [CGRect(x: 10, y: 80, width: 80, height: 16), CGRect(x: 0, y: 96, width: 40, height: 16)])
    private let topFile = DetectedLink(target: "/tmp/" + String(repeating: "deep/", count: 20) + "file.txt", text: "file.txt",
                                       kind: .file(isDirectory: false), rects: [CGRect(x: 300, y: 0, width: 60, height: 16)])

    private func hint(_ overlay: LinkOverlayView) -> HintBubble? { overlay.subviews.compactMap { $0 as? HintBubble }.first }

    private func draw(_ v: NSView) {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return XCTFail("no bitmap") }
        v.cacheDisplay(in: v.bounds, to: rep)
    }

    func testHoveringALinkShowsAHintAbove() throws {
        let overlay = LinkOverlayView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        XCTAssertNil(overlay.hitTest(NSPoint(x: 20, y: 45)))
        overlay.color = .systemBlue
        overlay.update(links: [url, file, topFile])
        overlay.update(links: [url, file, topFile]) // unchanged
        XCTAssertEqual(overlay.links.count, 3)
        draw(overlay)
        XCTAssertEqual(overlay.link(at: CGPoint(x: 20, y: 45)), url)
        XCTAssertEqual(overlay.link(at: CGPoint(x: 5, y: 100)), file)
        XCTAssertNil(overlay.link(at: CGPoint(x: 500, y: 200)))

        overlay.mouseMoved(to: CGPoint(x: 20, y: 45), modifiers: [])
        XCTAssertEqual(overlay.hovered, url)
        let bubble = try XCTUnwrap(hint(overlay))
        XCTAssertFalse(bubble.isHidden)
        XCTAssertLessThan(bubble.frame.maxY, 40, "above the link")
        XCTAssertGreaterThanOrEqual(bubble.frame.minX, 8)
        draw(overlay)
        // Same link, ⌘ now down: the bubble's text changes.
        overlay.mouseMoved(to: CGPoint(x: 30, y: 45), modifiers: .command)
        XCTAssertEqual(overlay.hovered, url)
        overlay.mouseMoved(to: CGPoint(x: 30, y: 46), modifiers: .command) // nothing changed
        overlay.mouseMoved(to: nil, modifiers: [])
        XCTAssertNil(overlay.hovered)
        XCTAssertTrue(bubble.isHidden)
    }

    func testAHintNearTheTopGoesBelowTheLink() throws {
        let overlay = LinkOverlayView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        overlay.update(links: [topFile, file])
        overlay.mouseMoved(to: CGPoint(x: 320, y: 5), modifiers: .command)
        let bubble = try XCTUnwrap(hint(overlay))
        XCTAssertGreaterThanOrEqual(bubble.frame.minY, 16, "below the link")
        XCTAssertGreaterThanOrEqual(bubble.frame.minX, 8)
        overlay.mouseMoved(to: CGPoint(x: 20, y: 85), modifiers: [])
        XCTAssertEqual(overlay.hovered, file)
        draw(overlay)
    }

    func testLinksThatDisappearAreUnhovered() {
        let overlay = LinkOverlayView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        overlay.update(links: [url])
        overlay.mouseMoved(to: CGPoint(x: 20, y: 45), modifiers: [])
        XCTAssertNotNil(overlay.hovered)
        overlay.update(links: [file])
        XCTAssertNil(overlay.hovered)
        overlay.update(links: [])
        XCTAssertTrue(overlay.links.isEmpty)
    }

    func testHintBubbleSizesToItsText() {
        let bubble = HintBubble(frame: .zero)
        bubble.set(link: url, commandDown: false)
        let short = bubble.fittingSize
        bubble.set(link: topFile, commandDown: true)
        let long = bubble.fittingSize
        XCTAssertGreaterThan(long.width, short.width)
        XCTAssertLessThanOrEqual(long.width, 460)
        bubble.set(link: file, commandDown: false)
        bubble.frame = NSRect(origin: .zero, size: bubble.fittingSize)
        bubble.layoutSubtreeIfNeeded()
        let label = bubble.subviews.compactMap { $0 as? NSTextField }.first
        XCTAssertEqual(label?.stringValue, "⌘-click to show in Finder  ~/code/project/")
        bubble.set(link: url, commandDown: true)
        XCTAssertEqual(label?.stringValue, "Click to open  example.com/docs")
        bubble.set(link: topFile, commandDown: false)
        XCTAssertTrue(label?.stringValue.contains("  …") == true, "long paths are shortened")
    }
}

// MARK: - Link detection

@MainActor
final class LinkResolverTests: XCTestCase {
    private let g = LinkDetector.Geometry(originX: 0, baseline0: 16, cellWidth: 8, cellHeight: 16, columns: 80, rows: 24)

    func testFileSystemResolverFindsFilesAndFoldersRelativeToTheDirectory() throws {
        let dir = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let resolve = LinkDetector.fileSystemResolver(cwd: dir.path, cache: FileCheckCache())
        let readme = try XCTUnwrap(resolve("README.md"))
        XCTAssertEqual(readme.path, dir.appendingPathComponent("README.md").standardizedFileURL.path)
        XCTAssertFalse(readme.isDirectory)
        XCTAssertEqual(resolve("./Sources/../Sources")?.isDirectory, true)
        XCTAssertNil(resolve("missing.txt"))
        XCTAssertEqual(resolve(dir.path)?.isDirectory, true)
        XCTAssertNotNil(LinkDetector.fileSystemResolver(cwd: nil, cache: FileCheckCache())("~"))
    }

    func testDetectsCompilerStylePathsAndStripsPunctuation() throws {
        let dir = try makeTemporaryDirectory()
        try "x".write(to: dir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        let resolve = LinkDetector.fileSystemResolver(cwd: dir.path, cache: FileCheckCache())
        let text = "main.swift:12:5: error\nsee main.swift. and (main.swift:3)\n-flag.txt"
        let links = LinkDetector.detect(text: text, geometry: g, resolvePath: resolve)
        XCTAssertEqual(links.map(\.text), ["main.swift", "main.swift", "main.swift"])
        XCTAssertTrue(links.allSatisfy(\.isFile))
        XCTAssertEqual(links.first?.rects.first, CGRect(x: 0, y: 16 - 12.8, width: 80, height: 16))
        XCTAssertEqual(links.first?.url, links.first?.target)
    }

    func testFileCheckCacheRemembersResults() throws {
        let dir = try makeTemporaryDirectory()
        let path = dir.appendingPathComponent("later.txt").path
        let cache = FileCheckCache()
        XCTAssertNil(cache.check(path))
        try "x".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertNil(cache.check(path), "cached until it expires")
        XCTAssertEqual(FileCheckCache().check(path), false)
        XCTAssertEqual(FileCheckCache().check(dir.path), true)
    }

    func testCellWidths() {
        XCTAssertEqual(LinkDetector.cellWidth("a"), 1)
        XCTAssertEqual(LinkDetector.cellWidth("日"), 2)
        XCTAssertEqual(LinkDetector.cellWidth("😀"), 2)
        XCTAssertEqual(LinkDetector.cellWidth("한"), 2)
        XCTAssertEqual(LinkDetector.cellWidth("é"), 1)
    }

    func testRowsPastTheViewportAreIgnored() {
        let small = LinkDetector.Geometry(originX: 0, baseline0: 16, cellWidth: 8, cellHeight: 16, columns: 10, rows: 1)
        let links = LinkDetector.detect(text: "first\nhttps://example.com/x", geometry: small)
        XCTAssertTrue(links.isEmpty)
        let wrapped = LinkDetector.detect(text: "https://example.com/abcdef", geometry: small)
        XCTAssertEqual(wrapped.first?.rects.count, 1, "the wrapped row is off screen")
    }

    func testNoGeometryWithoutATerminal() {
        let session = TerminalSession(workingDirectory: NSTemporaryDirectory())
        defer { session.close() }
        XCTAssertNil(LinkDetector.geometry(for: session.surfaceView))
        let link = DetectedLink(target: "/tmp", text: "/tmp", kind: .file(isDirectory: true), rects: [CGRect(x: 0, y: 0, width: 10, height: 10)])
        XCTAssertTrue(link.contains(CGPoint(x: 5, y: 5)))
        XCTAssertFalse(link.contains(CGPoint(x: 15, y: 5)))
        XCTAssertTrue(link.isFile)
    }
}
