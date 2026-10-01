import AppKit
import SwiftUI
import XCTest
@testable import Shell

/// A real, never-shown terminal window with tabs, registered with the app
/// delegate (libghostty isn't running, so no shells start). Settings are
/// restored and the window is closed (and checked to have left the app
/// delegate) when the test ends.
@MainActor
final class TabsFixture {
    let controller: TerminalWindowController
    let dir: String
    private var extra: [TerminalWindowController] = []
    private let originalSettings: AppSettings

    init(dir: String) {
        self.dir = dir
        originalSettings = SettingsStore.shared.settings
        // No dashboard chip unless a test asks for it.
        SettingsStore.shared.settings.claudeSessionsButton = .never
        controller = AppDelegate.shared.newWindowController()
    }

    var workspace: Workspace { controller.workspace }

    @discardableResult
    func tab(_ title: String? = nil, idle: Bool = true, select: Bool = true) -> TerminalTab {
        let tab = controller.newTab(directory: dir, select: select)
        tab.customTitle = title
        if idle { tab.focusedSession?.promptReady(exitCode: nil, directory: dir, branch: nil, duration: nil) }
        return tab
    }

    func track(_ c: TerminalWindowController) { extra.append(c) }

    /// Lays out and draws the window's real content (tab bar, panes).
    func renderWindow() {
        guard let content = controller.window?.contentView else { return }
        content.layoutSubtreeIfNeeded()
        content.display()
    }

    func close() {
        let all = [controller] + extra
        for c in all { c.close() }
        SettingsStore.shared.settings = originalSettings
        XCTAssertFalse(AppDelegate.shared.controllers.contains { c in all.contains { $0 === c } },
                       "closed windows leave the app delegate")
    }
}

extension XCTestCase {
    @MainActor
    func tabsFixture() throws -> TabsFixture {
        let fx = TabsFixture(dir: try makeTemporaryDirectory().path)
        addTeardownBlock { @MainActor in fx.close() }
        return fx
    }
}

@MainActor
final class TabViewsTests: XCTestCase {
    private var palette: ChromePalette { .current }

    // MARK: Status icon

    func testStatusIconReflectsTheTabsMostImportantState() throws {
        let fx = try tabsFixture()
        let tab = fx.tab("Status")
        let session = try XCTUnwrap(tab.focusedSession)
        func check(_ expected: String?, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(TabPresentation.accessibilityStatus(tab), expected, file: file, line: line)
            render(TabTrailingStatus(tab: tab, index: 0, hovering: false) {}, size: CGSize(width: 40, height: 20))
            render(SidebarTabRow(controller: fx.controller, workspace: fx.workspace, tab: tab, group: nil),
                   size: CGSize(width: 240, height: 50))
        }
        check(nil)
        session.hasUnseenOutput = true
        check("New output")
        session.commandStarted("false", directory: nil)
        check("Running")
        session.promptReady(exitCode: 1, directory: fx.dir, branch: "main", duration: 1)
        check("Last command failed")
        session.bell = true
        check("Bell")
        session.agent = .finished(.codex, "Codex finished")
        check("Codex done")
        session.agent = .needsInput(.claude, "Claude needs your permission")
        check("Claude needs input")
        session.agent = .working(.other)
        check("Agent working")
    }

    // MARK: Horizontal tab bar

    func testRendersTheHorizontalTabBarWithGroups() throws {
        let fx = try tabsFixture()
        let first = fx.tab("First")
        let second = fx.tab("Second")
        fx.tab("Third")
        let group = fx.workspace.createGroup(name: "Work", with: second)
        _ = fx.workspace.createGroup(name: "", with: first)
        fx.renderWindow()
        XCTAssertEqual(fx.workspace.items.count, 3)
        render(HorizontalTabBar(controller: fx.controller, workspace: fx.workspace, chrome: fx.controller.chrome),
               size: CGSize(width: 900, height: 40))
        group.isCollapsed = true
        fx.controller.chrome.isFullScreen = true
        render(HorizontalTabBar(controller: fx.controller, workspace: fx.workspace, chrome: fx.controller.chrome),
               size: CGSize(width: 900, height: 40))
        // Many tabs: the ones past ⌘9 have no shortcut hint.
        for i in 0..<9 { fx.tab("T\(i)", select: false) }
        render(HorizontalTabBar(controller: fx.controller, workspace: fx.workspace, chrome: fx.controller.chrome),
               size: CGSize(width: 2400, height: 40))
    }

    func testTabBarShowsTheDashboardAndGitHubChips() throws {
        let fx = try tabsFixture()
        fx.tab("Shell")
        fx.workspace.showsDashboard = true
        fx.workspace.githubTabOpen = true
        render(HorizontalTabBar(controller: fx.controller, workspace: fx.workspace, chrome: fx.controller.chrome),
               size: CGSize(width: 900, height: 40))
        render(VerticalTabSidebar(controller: fx.controller, workspace: fx.workspace, chrome: fx.controller.chrome),
               size: CGSize(width: 240, height: 500))
        fx.workspace.showsDashboard = false
        fx.workspace.showsGitHub = true
        render(HorizontalTabBar(controller: fx.controller, workspace: fx.workspace, chrome: fx.controller.chrome),
               size: CGSize(width: 900, height: 40))
        fx.workspace.showsGitHub = false
        fx.workspace.githubTabOpen = false
    }

    func testClosingTheSelectedChipClosesItsTab() throws {
        let fx = try tabsFixture()
        fx.tab("Keep")
        let doomed = fx.tab("Close me")
        XCTAssertEqual(fx.workspace.selectedTabID, doomed.id)
        let w = claudeWindow(HorizontalTabChip(controller: fx.controller, workspace: fx.workspace, tab: doomed, group: nil, palette: palette),
                             width: 200, height: 30)
        w.press(0)
        XCTAssertFalse(fx.workspace.tabs.contains { $0.id == doomed.id })
        XCTAssertEqual(fx.workspace.tabs.count, 1)
    }

    func testClickingAChipSelectsItsTab() throws {
        let fx = try tabsFixture()
        let first = fx.tab("First")
        fx.tab("Second")
        let w = claudeWindow(HorizontalTabChip(controller: fx.controller, workspace: fx.workspace, tab: first, group: nil, palette: palette),
                             width: 200, height: 30)
        w.click(x: 40, y: 14)
        XCTAssertTrue(waitUntil(timeout: 2) { fx.workspace.selectedTabID == first.id })
    }

    func testRendersGroupChipsExpandedAndCollapsed() throws {
        let fx = try tabsFixture()
        let tab = fx.tab("Grouped")
        let group = fx.workspace.createGroup(name: "Build", with: tab)
        render(GroupChip(controller: fx.controller, workspace: fx.workspace, group: group, count: 1, palette: palette))
        group.isCollapsed = true
        group.name = ""
        render(GroupChip(controller: fx.controller, workspace: fx.workspace, group: group, count: 3, palette: palette))
    }

    func testChromeButtonsRunTheirActions() throws {
        let fx = try tabsFixture()
        fx.tab()
        var pressed = 0
        let w = claudeWindow(ChromeIconButton(symbol: "bell", help: "Agent Activity (⌥⌘N)", palette: palette) { pressed += 1 },
                             width: 40, height: 30)
        w.press(0)
        XCTAssertEqual(pressed, 1)
        w.hover(x: 10, y: 10)
        render(ChromeButtons(controller: fx.controller, palette: palette, vertical: true), size: CGSize(width: 80, height: 30))
        render(ChromeButtons(controller: fx.controller, palette: palette, vertical: false), size: CGSize(width: 80, height: 30))
    }

    // MARK: Vertical sidebar

    func testRendersTheVerticalSidebarWithGroupsAndSubtitles() throws {
        let fx = try tabsFixture()
        let plain = fx.tab("Plain")
        plain.focusedSession?.promptReady(exitCode: 0, directory: fx.dir, branch: "feature/x", duration: 0.1)
        let split = fx.tab("Split")
        fx.controller.split(.horizontal)
        XCTAssertEqual(split.sessions.count, 2)
        let busy = fx.tab("Agent")
        busy.focusedSession?.agent = .working(.claude)
        let group = fx.workspace.createGroup(name: "Agents", with: busy)
        render(VerticalTabSidebar(controller: fx.controller, workspace: fx.workspace, chrome: fx.controller.chrome),
               size: CGSize(width: 240, height: 500))
        for agent: AgentStatus in [.needsInput(.claude, "Approve the edit?"), .finished(.claude, "Done")] {
            busy.focusedSession?.agent = agent
            render(SidebarTabRow(controller: fx.controller, workspace: fx.workspace, tab: busy, group: group),
                   size: CGSize(width: 240, height: 60))
        }
        group.isCollapsed = true
        fx.controller.chrome.isFullScreen = true
        render(VerticalTabSidebar(controller: fx.controller, workspace: fx.workspace, chrome: fx.controller.chrome),
               size: CGSize(width: 240, height: 500))
        render(SidebarGroupHeader(controller: fx.controller, workspace: fx.workspace, group: group, count: 1))
        group.name = ""
        render(SidebarGroupHeader(controller: fx.controller, workspace: fx.workspace, group: group, count: 2))
    }

    func testVerticalTabBarStyleBuildsTheSidebarChrome() throws {
        let fx = try tabsFixture()
        SettingsStore.shared.settings.tabBarStyle = .vertical
        fx.controller.rebuildChrome()
        fx.tab("One")
        fx.tab("Two")
        fx.renderWindow()
        SettingsStore.shared.settings.tabBarStyle = .horizontal
        fx.controller.rebuildChrome()
        fx.renderWindow()
    }

    func testSidebarNewTabButtonOpensATab() throws {
        let fx = try tabsFixture()
        fx.tab("Only")
        let w = claudeWindow(VerticalTabSidebar(controller: fx.controller, workspace: fx.workspace, chrome: fx.controller.chrome),
                             width: 240, height: 400)
        let controls = w.controls()
        // Reading order ends with the footer: "New Tab", then "Claude in New Worktree…".
        XCTAssertGreaterThanOrEqual(controls.count, 4)
        w.press(controls.count - 2)
        XCTAssertEqual(fx.workspace.tabs.count, 2)
    }

    func testClickingASidebarRowSelectsItsTab() throws {
        let fx = try tabsFixture()
        let first = fx.tab("First")
        fx.tab("Second")
        let w = claudeWindow(SidebarTabRow(controller: fx.controller, workspace: fx.workspace, tab: first, group: nil),
                             width: 240, height: 44)
        w.click(x: 80, y: 14)
        XCTAssertTrue(waitUntil(timeout: 2) { fx.workspace.selectedTabID == first.id })
        w.hover(x: 80, y: 14)
    }

    // MARK: Context menus

    func testTabContextMenuDuplicatesAndClosesTabs() throws {
        let fx = try tabsFixture()
        let keep = fx.tab("Keep")
        fx.tab("Other")
        let grouped = fx.tab("Grouped")
        _ = fx.workspace.createGroup(name: "G", with: grouped)
        render(VStack { TabContextMenu(controller: fx.controller, workspace: fx.workspace, tab: grouped) }, size: CGSize(width: 300, height: 400))
        render(VStack { TabContextMenu(controller: fx.controller, workspace: fx.workspace, tab: keep) }, size: CGSize(width: 300, height: 400))
        fx.controller.duplicate(keep)
        XCTAssertEqual(fx.workspace.tabs.count, 4)
        fx.controller.closeOtherTabs(except: keep)
        XCTAssertEqual(fx.workspace.tabs.map(\.id), [keep.id])
    }

    func testGroupContextMenuRendersForEachState() throws {
        let fx = try tabsFixture()
        let tab = fx.tab("Grouped")
        let group = fx.workspace.createGroup(name: "Team", with: tab)
        render(VStack { GroupContextMenu(controller: fx.controller, workspace: fx.workspace, group: group) }, size: CGSize(width: 300, height: 300))
        group.isCollapsed = true
        render(VStack { GroupContextMenu(controller: fx.controller, workspace: fx.workspace, group: group) }, size: CGSize(width: 300, height: 300))
    }

    // MARK: Activity

    func testActivityPopoverListsPanesThatNeedAttention() throws {
        let fx = try tabsFixture()
        // Nothing to report (from this window, at least).
        render(ActivityPopover(controller: fx.controller), size: CGSize(width: 320, height: 300))
        let a = try XCTUnwrap(fx.tab("A").focusedSession)
        let b = try XCTUnwrap(fx.tab("B").focusedSession)
        let c = try XCTUnwrap(fx.tab("C").focusedSession)
        let d = try XCTUnwrap(fx.tab("D").focusedSession)
        let e = try XCTUnwrap(fx.tab("E").focusedSession)
        a.agent = .working(.claude)
        b.agent = .needsInput(.codex, "Codex wants to run a command")
        c.agent = .finished(.claude, "All done")
        d.bell = true
        e.commandStarted("make", directory: nil)
        e.promptReady(exitCode: 2, directory: fx.dir, branch: nil, duration: 1)
        e.hasUnseenOutput = true
        fx.controller.chrome.showActivity = true
        let w = claudeWindow(ActivityPopover(controller: fx.controller), width: 320)
        XCTAssertGreaterThanOrEqual(w.controls().count, 5)
        w.press(0)
        XCTAssertFalse(fx.controller.chrome.showActivity, "picking a pane closes the popover")
        for s in [a, b, c] { s.agent = nil }
        d.bell = false
        e.hasUnseenOutput = false
    }

    // MARK: Window dragging

    func testDoubleClickingTheDragAreaZoomsTheWindow() throws {
        let window = ClaudeTestKeyWindow(contentRect: NSRect(x: -20000, y: -20000, width: 300, height: 200),
                                         styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in window.orderOut(nil); window.close() }
        let drag = WindowDragArea.DragView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        window.contentView?.addSubview(drag)
        XCTAssertTrue(drag.mouseDownCanMoveWindow)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        drag.mouseDown(with: event)
        render(WindowDragArea().frame(width: 80, height: 20), size: CGSize(width: 80, height: 20))
    }

    // MARK: Accessibility

    func testTabAccessibilityDescribesTitleStatusAndGroup() throws {
        let fx = try tabsFixture()
        let tab = fx.tab("Server")
        tab.focusedSession?.bell = true
        let group = fx.workspace.createGroup(name: "", with: tab)
        render(Text("x").tabAccessibility(tab: tab, index: 10, selected: false, group: group) {}, size: CGSize(width: 40, height: 20))
        render(Text("x").tabAccessibility(tab: tab, index: 0, selected: true, group: nil) {}, size: CGSize(width: 40, height: 20))
        XCTAssertEqual(TabPresentation.accessibilityStatus(tab), "Bell")
    }
}
