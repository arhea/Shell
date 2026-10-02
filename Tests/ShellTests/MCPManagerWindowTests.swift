import AppKit
import SwiftUI
import XCTest
@testable import Shell

/// The MCP Servers window, rendered in every state against a fake `claude`.
/// Nothing here renders an https icon (that would start a download) or
/// presents a sheet or dialog.
@MainActor
final class MCPManagerWindowTests: XCTestCase {
    private var dir: URL!
    private var fake: FakeMCPClaude!
    private let palette = ClaudePalette.current
    private let size = CGSize(width: 1000, height: 1600)

    override func setUp() async throws {
        dir = try makeTemporaryDirectory()
        fake = try FakeMCPClaude(in: dir)
    }

    private func loaded(_ servers: [[String: Any]] = MCPFixtures.all, trusted: Bool = true) async throws -> MCPManager {
        try fake.setStatus(servers)
        let manager = makeMCPManager(fake, directory: dir, trusted: trusted)
        await manager.load()
        XCTAssertNil(manager.lastError)
        return manager
    }

    private func entry(_ s: [String: Any]) -> MCPServerEntry { MCPServerEntry.parse(s) }

    @discardableResult
    private func renderManager(_ manager: MCPManager, select: String? = nil) -> (NSHostingView<MCPManagerView>, MCPSelection) {
        let selection = MCPSelection()
        selection.name = select
        return (render(MCPManagerView(manager: manager, selection: selection), size: size), selection)
    }

    private func renderDetail(_ manager: MCPManager, _ server: MCPServerEntry) {
        render(MCPServerDetail(manager: manager, server: server, palette: palette), size: size)
    }

    // MARK: Helpers on the views

    func testNormalizedToolNamesMatchClaudeCode() {
        XCTAssertEqual(MCPServerDetail.normalized("claude.ai Notion"), "claude_ai_Notion")
        XCTAssertEqual(MCPServerDetail.normalized("plugin:a:b-c_d"), "plugin_a_b-c_d")
        XCTAssertEqual(MCPServerDetail.normalized("héllo"), "h_llo")
    }

    func testStatusColors() {
        let p = palette
        XCTAssertEqual(MCPServerDetail.statusColor(.connected, p), p.green)
        XCTAssertEqual(MCPServerDetail.statusColor(.needsAuth, p), p.yellow)
        XCTAssertEqual(MCPServerDetail.statusColor(.failed, p), p.red)
        XCTAssertEqual(MCPServerDetail.statusColor(.pending, p), p.blue)
        XCTAssertEqual(MCPServerDetail.statusColor(.disabled, p), p.dim)
        XCTAssertEqual(MCPServerDetail.statusColor(.untrusted, p), p.yellow)
    }

    func testSplitCommandHonorsQuotes() {
        XCTAssertEqual(MCPAddServerSheet.splitCommand("npx -y @scope/server"), ["npx", "-y", "@scope/server"])
        XCTAssertEqual(MCPAddServerSheet.splitCommand("  run   'two words' \"and more\"  "), ["run", "two words", "and more"])
        XCTAssertEqual(MCPAddServerSheet.splitCommand("a\"b c\"d"), ["ab cd"])
        XCTAssertEqual(MCPAddServerSheet.splitCommand("it's"), ["its"], "an unterminated quote runs to the end")
        XCTAssertEqual(MCPAddServerSheet.splitCommand(""), [])
        XCTAssertEqual(MCPAddServerSheet.splitCommand("''"), [])
    }

    // MARK: Whole window

    func testEmptyStateWithoutServers() {
        let manager = makeMCPManager(fake, directory: dir)
        let (host, selection) = renderManager(manager)
        XCTAssertNil(selection.name)
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fake.dir.appendingPathComponent("launch.log").path),
                       "rendering never starts claude")
    }

    func testEmptyStateWhileLoading() async throws {
        try fake.set("initialize.silent", "")
        let manager = makeMCPManager(fake, directory: dir)
        let task = Task { await manager.load() }
        await assertEventually { manager.isLoading }
        renderManager(manager)
        manager.stop()
        await task.value
        XCTAssertFalse(manager.isLoading)
    }

    func testEmptyStateWithAnError() async throws {
        try fake.set("initialize.error", "claude is not logged in")
        let manager = makeMCPManager(fake, directory: dir)
        await manager.load()
        XCTAssertEqual(manager.lastError, "claude is not logged in")
        renderManager(manager)
    }

    func testEveryServerRendersSelectedInTheWindow() async throws {
        let manager = try await loaded()
        renderManager(manager)
        for server in manager.servers {
            let (_, selection) = renderManager(manager, select: server.name)
            XCTAssertEqual(selection.name, server.name)
        }
        renderManager(manager, select: "not-there")
    }

    func testSelectsTheFirstServerWhenServersArrive() async throws {
        try fake.setStatus(MCPFixtures.all)
        let manager = makeMCPManager(fake, directory: dir)
        let (host, selection) = renderManager(manager)
        await manager.load()
        await assertEventually {
            host.layoutSubtreeIfNeeded()
            host.display()
            return selection.name != nil
        }
        XCTAssertEqual(selection.name, "repo-db", "first server of the first group")
    }

    func testErrorWithServersShowsInTheDetailAndTheServer() async throws {
        let manager = try await loaded()
        try fake.set("mcp_toggle.error", "toggle failed")
        manager.setEnabled("notes", false)
        await assertEventually { manager.busy.isEmpty }
        XCTAssertEqual(manager.lastError, "notes: toggle failed")
        renderManager(manager)
        renderManager(manager, select: "notes")
    }

    func testRepositoryContextChip() async throws {
        let git = await ProcessRunner.run("/usr/bin/git", ["init", "-q", "-b", "main", dir.path], environment: ["PATH": "/usr/bin:/bin"],
                                          directory: dir.path, timeout: 30)
        try XCTSkipUnless(git.succeeded, "git unavailable")
        let manager = try await loaded([MCPFixtures.server("repo", scope: "project", config: ["command": "/usr/bin/true"])])
        XCTAssertNotNil(manager.repository)
        renderManager(manager, select: "repo")
    }

    func testUntrustedFolderRendersTheProjectServers() async throws {
        try JSONSerialization.data(withJSONObject: ["mcpServers": ["repo-tool": ["command": "npx"]]])
            .write(to: dir.appendingPathComponent(".mcp.json"))
        let manager = try await loaded([], trusted: false)
        XCTAssertEqual(manager.server("repo-tool")?.status, .untrusted)
        renderManager(manager, select: "repo-tool")
    }

    // MARK: Rows and icons

    func testRowsInEveryState() {
        let servers = MCPFixtures.all.map(entry) + [
            entry(MCPFixtures.server("pending", status: "pending", tools: [["name": "a"]])),
            entry(MCPFixtures.server("failing", status: "failed", config: ["type": "sse", "url": "https://x"])),
        ]
        for server in servers {
            for (busy, waiting, selected) in [(false, false, false), (true, false, true), (false, true, false)] {
                render(MCPServerRow(server: server, selected: selected, busy: busy, waiting: waiting, palette: palette) {}, size: CGSize(width: 300, height: 44))
            }
        }
    }

    func testIconsForEveryKindOfServer() {
        let icons: [[String: Any]] = [
            MCPFixtures.all[0], // data: icon
            MCPFixtures.server("svg", info: ["icons": [["src": "https://example.com/icon.svg"]]]),
            MCPFixtures.server("insecure", info: ["icons": [["src": "http://example.com/icon.png"]]]),
            MCPFixtures.server("bad-data", info: ["icons": [["src": "data:image/png;base64,@@@"]]]),
            MCPFixtures.all[1], MCPFixtures.all[4], MCPFixtures.all[5], MCPFixtures.all[2],
        ]
        for s in icons {
            render(MCPServerIcon(server: entry(s), palette: palette, size: 44), size: CGSize(width: 44, height: 44))
        }
    }

    // MARK: Detail

    func testDetailForEveryServer() async throws {
        let manager = try await loaded()
        for server in manager.servers { renderDetail(manager, server) }
    }

    func testDetailForEdgeCaseServers() throws {
        let manager = makeMCPManager(fake, directory: dir)
        let servers = [
            MCPFixtures.server("failed-no-message", status: "failed"),
            MCPFixtures.server("connected-empty", status: "connected"),
            MCPFixtures.server("waiting", status: "pending"),
            MCPFixtures.server("claude.ai Gmail", status: "needs-auth", scope: "claudeai", source: "claudeai",
                               config: ["type": "claudeai-proxy"], tools: [["name": "send"]]),
            MCPFixtures.server("oauth", status: "connected", config: ["type": "http", "url": "https://x", "oauth": [:]], tools: [["name": "t"]]),
            MCPFixtures.server("sse-tools", config: ["type": "sse", "url": "https://x"], tools: [["name": "t"]]),
            MCPFixtures.server("plain", info: ["name": "Plain", "description": ""]),
            MCPFixtures.server("stdio-no-command", config: ["type": "stdio"]),
        ]
        for s in servers { renderDetail(manager, entry(s)) }
    }

    func testDetailWhileBusyAndLoadingTools() async throws {
        let script = try FakeMCPServer.write(in: dir)
        let manager = try await loaded([MCPFixtures.server("broken", config: ["command": script, "args": ["initerror"]], tools: [["name": "t"]])])
        try fake.set("mcp_reconnect.silent", "")
        manager.reconnect("broken")
        XCTAssertTrue(manager.busy.contains("broken"))
        let server = try XCTUnwrap(manager.server("broken"))
        manager.loadToolDetails(server)
        XCTAssertTrue(manager.loadingTools.contains("broken"))
        renderDetail(manager, server)
        renderManager(manager, select: "broken")
        await assertEventually(timeout: 10) { manager.loadingTools.isEmpty }
        XCTAssertEqual(manager.toolErrors["broken"], "bad init")
        renderDetail(manager, server)
        manager.stop()
        await assertEventually { manager.busy.isEmpty }
    }

    func testDetailWithToolDescriptionsFromTheServer() async throws {
        let script = try FakeMCPServer.write(in: dir)
        let manager = try await loaded([
            MCPFixtures.server("fake", config: ["command": script, "args": ["ok", "x"]],
                               tools: [["name": "first", "annotations": ["destructiveHint": true]], ["name": "second"]]),
        ])
        let server = try XCTUnwrap(manager.server("fake"))
        renderDetail(manager, server) // names from Claude Code
        manager.loadToolDetails(server)
        await assertEventually(timeout: 10) { manager.loadingTools.isEmpty }
        XCTAssertNil(manager.toolErrors["fake"])
        XCTAssertEqual(manager.toolDetails["fake"]?.count, 2)
        renderDetail(manager, server) // descriptions from the server
    }

    // MARK: Tool rows

    func testToolRows() {
        let info = MCPToolInfo.parse([
            "name": "search", "title": "Search Everything", "description": "Finds things",
            "inputSchema": ["required": ["q"], "properties": ["q": ["type": "string", "description": "Query"], "n": ["type": "integer"]]],
        ])
        let single = MCPToolInfo.parse(["name": "one", "title": "one", "inputSchema": ["properties": ["x": ["type": "string"]]]])
        let rows = [
            MCPToolRow(name: "search", info: info, readOnly: true, destructive: true, qualified: "mcp__s__search", palette: palette),
            MCPToolRow(name: "one", info: single, readOnly: false, destructive: false, qualified: "mcp__s__one", palette: palette),
            MCPToolRow(name: "bare", info: nil, readOnly: false, destructive: false, qualified: "mcp__s__bare", palette: palette),
        ]
        for row in rows { render(row, size: CGSize(width: 600, height: 200)) }
    }

    // MARK: Add server sheet

    func testAddServerSheetRendersWithAndWithoutARepository() {
        let manager = makeMCPManager(fake, directory: dir)
        for hasRepository in [true, false] {
            render(MCPAddServerSheet(manager: manager, hasRepository: hasRepository) { _ in }, size: CGSize(width: 540, height: 520))
        }
        XCTAssertEqual(fake.log("cli.log"), "", "rendering adds nothing")
    }

    // MARK: Window controller

    private var openControllers: [MCPManagerWindowController] {
        NSApp.windows.compactMap { $0.windowController as? MCPManagerWindowController }
    }

    func testShowOpensOneWindowAndReusesIt() async throws {
        try fake.setStatus(MCPFixtures.all)
        MCPManagerWindowController.show(directory: dir.path, binary: fake.binary, environment: fake.environment, select: "linear")
        let controller = try XCTUnwrap(openControllers.first { $0.window?.isVisible == true })
        addTeardownBlock { @MainActor in controller.close() }
        controller.manager.isTrusted = { _ in true }
        XCTAssertEqual(openControllers.filter { $0.window?.isVisible == true }.count, 1)
        XCTAssertEqual(controller.window?.title, "MCP Servers")
        XCTAssertEqual(controller.selection.name, "linear")
        XCTAssertTrue(controller.window?.contentView is NSHostingView<MCPManagerView>)
        await assertEventually { !controller.manager.servers.isEmpty && !controller.manager.isLoading }

        let other = try makeTemporaryDirectory()
        MCPManagerWindowController.show(directory: other.path, select: "notes")
        XCTAssertEqual(openControllers.filter { $0.window?.isVisible == true }.count, 1, "the window is reused")
        XCTAssertEqual(controller.manager.directory, other.path)
        XCTAssertEqual(controller.selection.name, "notes")
        await assertEventually { !controller.manager.servers.isEmpty && !controller.manager.isLoading }

        controller.close()
        XCTAssertFalse(controller.window?.isVisible ?? true)
        XCTAssertNil(controller.manager.repository)

        // Closing forgets the window: the next show makes a new one.
        MCPManagerWindowController.show(directory: dir.path, binary: fake.binary, environment: fake.environment)
        let next = try XCTUnwrap(openControllers.first { $0.window?.isVisible == true })
        next.manager.isTrusted = { _ in true }
        XCTAssertFalse(next === controller)
        XCTAssertNil(next.selection.name)
        next.close()
    }
}
