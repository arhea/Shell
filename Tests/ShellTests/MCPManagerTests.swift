import XCTest
@testable import Shell

/// Parsing of Claude Code's `mcp_status` entries.
final class MCPServerEntryTests: XCTestCase {
    private func entry(_ s: [String: Any]) -> MCPServerEntry { MCPServerEntry.parse(s) }

    func testParsesAFullEntry() {
        let e = entry(MCPFixtures.all[0])
        XCTAssertEqual(e.name, "repo-db")
        XCTAssertEqual(e.id, "repo-db")
        XCTAssertEqual(e.status, .connected)
        XCTAssertEqual(e.group, .project)
        XCTAssertEqual(e.transport, "stdio", "a command without a type is stdio")
        XCTAssertEqual(e.command, "/usr/bin/true")
        XCTAssertEqual(e.args, ["--db"])
        XCTAssertEqual(e.envKeys, ["TOKEN"])
        XCTAssertEqual(e.endpoint, "/usr/bin/true --db")
        XCTAssertEqual(e.serverTitle, "Repo DB")
        XCTAssertEqual(e.serverVersion, "1.2")
        XCTAssertEqual(e.serverDescription, "Database access")
        XCTAssertEqual(e.websiteURL?.host(), "db.example.com")
        XCTAssertEqual(e.iconURL?.scheme, "data")
        XCTAssertEqual(e.tools, [.init(name: "query", readOnly: true, destructive: false), .init(name: "drop", readOnly: false, destructive: true)])
        XCTAssertEqual(e.config["command"] as? String, "/usr/bin/true")
        XCTAssertTrue(e.isEditable)
        XCTAssertFalse(e.canSignIn)
    }

    func testDefaultsForAnEmptyEntry() {
        let e = entry([:])
        XCTAssertEqual(e.name, "")
        XCTAssertEqual(e.status, .pending, "unknown status reads as pending")
        XCTAssertEqual(e.transport, "http", "no command and no type is http")
        XCTAssertEqual(e.group, .other)
        XCTAssertEqual(e.endpoint, "http")
        XCTAssertTrue(e.tools.isEmpty)
        XCTAssertNil(e.serverTitle)
        XCTAssertFalse(e.isEditable)
        XCTAssertTrue(e.config.isEmpty)
    }

    func testServerTitleFallsBackToNameAndToolHintsToShortKeys() {
        let e = entry(["name": "x", "serverInfo": ["name": "srv"],
                       "tools": [["name": "t", "annotations": ["readOnly": true, "destructive": true]]]])
        XCTAssertEqual(e.serverTitle, "srv")
        XCTAssertEqual(e.tools.first, .init(name: "t", readOnly: true, destructive: true))
    }

    func testGroupsByScopeAndSource() {
        func group(_ scope: String, _ source: String) -> MCPServerEntry.Group { entry(["scope": scope, "source": source]).group }
        XCTAssertEqual(group("project", "plugin"), .project)
        XCTAssertEqual(group("local", ""), .local)
        XCTAssertEqual(group("user", ""), .user)
        XCTAssertEqual(group("dynamic", "plugin"), .plugin)
        XCTAssertEqual(group("dynamic", "claudeai"), .claudeai)
        XCTAssertEqual(group("claudeai", ""), .claudeai)
        XCTAssertEqual(group("dynamic", "sdk"), .other)
        XCTAssertEqual(MCPServerEntry.Group.allCases.sorted(), MCPServerEntry.Group.allCases)
        XCTAssertLessThan(MCPServerEntry.Group.project, .other)
    }

    func testGroupTitlesAndScopes() {
        XCTAssertEqual(MCPServerEntry.Group.allCases.map(\.title),
                       ["Project · .mcp.json", "Project · only you", "Global · all projects", "Plugins", "claude.ai connectors", "Other"])
        XCTAssertEqual(MCPServerEntry.Group.allCases.map(\.cliScope), ["project", "local", "user", nil, nil, nil])
    }

    func testStatusTitles() {
        let all: [MCPServerEntry.Status] = [.connected, .needsAuth, .failed, .pending, .disabled, .untrusted]
        XCTAssertEqual(all.map(\.title), ["Connected", "Needs sign-in", "Failed", "Connecting…", "Disabled", "Folder not trusted"])
        XCTAssertEqual(MCPServerEntry.Status(rawValue: "needs-auth"), .needsAuth)
    }

    func testDisplayNamesForPluginsAndConnectors() {
        let plugin = entry(MCPFixtures.all[4])
        XCTAssertEqual(plugin.group, .plugin)
        XCTAssertEqual(plugin.displayName, "github")
        XCTAssertEqual(plugin.pluginName, "takt-engineering")
        XCTAssertTrue(plugin.hasOAuth)

        let connector = entry(MCPFixtures.all[5])
        XCTAssertEqual(connector.displayName, "Notion")
        XCTAssertNil(connector.pluginName)
        XCTAssertTrue(connector.canSignIn)

        let oddPlugin = entry(["name": "plugin:solo", "scope": "dynamic", "source": "plugin"])
        XCTAssertEqual(oddPlugin.displayName, "plugin:solo")
        XCTAssertEqual(oddPlugin.pluginName, "solo")
        XCTAssertNil(entry(["name": "plain", "source": "plugin"]).pluginName)
        XCTAssertEqual(entry(["name": "claude.ai X", "scope": "user"]).displayName, "claude.ai X", "only connectors drop the prefix")
    }

    func testEndpointPrefersURLAndHeadersAreListed() {
        let e = entry(MCPFixtures.all[2])
        XCTAssertEqual(e.endpoint, "https://mcp.linear.app/mcp")
        XCTAssertEqual(e.headerKeys, ["X-Key"])
        XCTAssertTrue(e.canSignIn)
        XCTAssertEqual(entry(["config": ["type": "http", "url": ""]]).endpoint, "http")
        XCTAssertTrue(entry(["config": ["type": "sse"]]).canSignIn)
    }
}

/// `MCPManager` driving a fake `claude` (control requests and `claude mcp …`).
@MainActor
final class MCPManagerTests: XCTestCase {
    private var dir: URL!
    private var fake: FakeMCPClaude!

    override func setUp() async throws {
        dir = try makeTemporaryDirectory()
        fake = try FakeMCPClaude(in: dir)
    }

    private func loaded(_ servers: [[String: Any]] = MCPFixtures.all, trusted: Bool = true) async throws -> MCPManager {
        try fake.setStatus(servers)
        let manager = makeMCPManager(fake, directory: dir, trusted: trusted)
        await manager.load()
        return manager
    }

    private func observe(_ name: Notification.Name) -> () -> [String] {
        var names: [String] = []
        let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { note in
            if let n = note.userInfo?["name"] as? String { MainActor.assumeIsolated { names.append(n) } }
        }
        addTeardownBlock { NotificationCenter.default.removeObserver(token) }
        return { names }
    }

    func testDefaultEnvironmentHasAPath() {
        let env = MCPManager.defaultEnvironment()
        XCTAssertFalse((env["PATH"] ?? "").isEmpty)
    }

    func testInitFindsClaudeOnThePathOrFallsBack() {
        let found = MCPManager(directory: dir.path, environment: ["PATH": fake.dir.path])
        XCTAssertEqual(found.directory, dir.path)
        let fallback = MCPManager(directory: dir.path, environment: ["PATH": dir.appendingPathComponent("empty").path])
        XCTAssertNil(fallback.lastError)
        found.stop(); fallback.stop()
    }

    func testLoadListsServersGroupedAndSorted() async throws {
        let manager = try await loaded()
        XCTAssertNil(manager.lastError)
        XCTAssertFalse(manager.isLoading)
        XCTAssertNotNil(manager.lastUpdated)
        XCTAssertTrue(manager.trusted)
        XCTAssertNil(manager.repository, "a plain temp folder isn't a repository")
        XCTAssertEqual(manager.servers.count, MCPFixtures.all.count)
        XCTAssertEqual(manager.grouped.map(\.0), [.project, .local, .user, .plugin, .claudeai, .other])
        XCTAssertEqual(manager.grouped.first { $0.0 == .user }?.1.map(\.name), ["linear", "notes"])
        XCTAssertEqual(manager.needsAuthCount, 1)
        XCTAssertEqual(manager.server("linear")?.status, .needsAuth)
        XCTAssertNil(manager.server("missing"))
        XCTAssertEqual(fake.requests("initialize").count, 1)
        XCTAssertEqual(fake.requests("mcp_status").count, 1, "no pending server: no polling")
    }

    func testLoadPollsWhileServersAreConnecting() async throws {
        try fake.setStatus([MCPFixtures.server("slow", status: "pending")], request: 1)
        try fake.setStatus([MCPFixtures.server("slow", status: "connected")])
        let manager = makeMCPManager(fake, directory: dir)
        await manager.load()
        XCTAssertEqual(manager.server("slow")?.status, .connected)
        XCTAssertEqual(fake.requests("mcp_status").count, 2)
    }

    func testLoadReusesTheRunningClient() async throws {
        let manager = try await loaded()
        try await manager.refreshStatus()
        XCTAssertEqual(fake.requests("initialize").count, 1)
        XCTAssertEqual(fake.requests("mcp_status").count, 2)
    }

    func testUntrustedFolderListsProjectServersWithoutStartingThem() async throws {
        let mcp: [String: Any] = ["mcpServers": ["repo-tool": ["command": "npx", "args": ["-y", "tool"]], "bad": "not a dict"]]
        try JSONSerialization.data(withJSONObject: mcp).write(to: dir.appendingPathComponent(".mcp.json"))
        let manager = try await loaded([MCPFixtures.server("global")], trusted: false)
        XCTAssertFalse(manager.trusted)
        XCTAssertEqual(manager.servers.map(\.name).sorted(), ["global", "repo-tool"])
        let repo = try XCTUnwrap(manager.server("repo-tool"))
        XCTAssertEqual(repo.status, .untrusted)
        XCTAssertEqual(repo.group, .project)
        XCTAssertTrue(repo.error?.contains("trusted") == true)
        XCTAssertFalse(manager.canInspect(repo))
        // Asked from home, so the repository's .mcp.json never starts.
        XCTAssertTrue(fake.log("launch.log").contains("pwd: \(NSHomeDirectory())"))
    }

    func testUntrustedFolderWithoutMCPJSONAddsNothing() async throws {
        let manager = try await loaded([MCPFixtures.server("global")], trusted: false)
        XCTAssertEqual(manager.servers.map(\.name), ["global"])
    }

    func testLoadFindsTheRepositoryRoot() async throws {
        let git = await ProcessRunner.run("/usr/bin/git", ["init", "-q", dir.path], environment: ["PATH": "/usr/bin:/bin"], directory: dir.path, timeout: 30)
        try XCTSkipUnless(git.succeeded, "git unavailable")
        let manager = try await loaded([MCPFixtures.server("x")])
        XCTAssertEqual(manager.repository?.root.resolvingSymlinksInPath().path, dir.resolvingSymlinksInPath().path)
        manager.stop()
        XCTAssertNil(manager.repository)
    }

    func testInitializeErrorIsReported() async throws {
        try fake.set("initialize.error", "not logged in")
        let manager = makeMCPManager(fake, directory: dir)
        await manager.load()
        XCTAssertEqual(manager.lastError, "not logged in")
        XCTAssertTrue(manager.servers.isEmpty)
    }

    func testMissingBinaryIsReported() async throws {
        let manager = MCPManager(directory: dir.path, binary: dir.appendingPathComponent("missing").path, environment: [:])
        manager.isTrusted = { _ in true }
        defer { manager.stop() }
        await manager.load()
        XCTAssertNotNil(manager.lastError)
    }

    func testExitIncludesTheLastStderrLine() async throws {
        try fake.set("stderr.txt", "Error: something broke")
        try fake.set("initialize.exit", "")
        let manager = makeMCPManager(fake, directory: dir)
        await manager.load()
        let error = try XCTUnwrap(manager.lastError)
        XCTAssertTrue(error.hasPrefix("Claude Code isn't running"), error)
    }

    func testStoppedManagerDoesNotStartClaude() async throws {
        let manager = makeMCPManager(fake, directory: dir)
        manager.stop()
        await manager.load()
        XCTAssertNil(manager.lastError, "cancellation isn't an error")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fake.dir.appendingPathComponent("launch.log").path))
    }

    func testRefreshAndReloadRestartTheClient() async throws {
        let manager = try await loaded([MCPFixtures.server("a")])
        manager.reload()
        await assertEventually { self.fake.requests("initialize").count == 2 && !manager.isLoading }
        manager.refresh()
        await assertEventually { self.fake.requests("mcp_status").count >= 3 && !manager.isLoading }
        XCTAssertEqual(fake.requests("initialize").count, 2, "refresh keeps the client")
    }

    func testSwitchDirectoryResetsAndReloads() async throws {
        let manager = try await loaded([MCPFixtures.server("a")])
        manager.switchDirectory(dir.path) // same folder: no-op
        XCTAssertEqual(manager.servers.count, 1)
        let other = try makeTemporaryDirectory()
        manager.switchDirectory(other.path)
        XCTAssertEqual(manager.directory, other.path)
        XCTAssertTrue(manager.servers.isEmpty)
        await assertEventually { manager.servers.count == 1 && !manager.isLoading }
        XCTAssertEqual(fake.requests("initialize").count, 2)
    }

    func testReconnectSignOutAndToggleSendControlRequestsAndAnnounce() async throws {
        let manager = try await loaded()
        let announced = observe(.mcpServerDidChange)
        manager.reconnect("linear")
        XCTAssertTrue(manager.busy.contains("linear"))
        await assertEventually { manager.busy.isEmpty }
        manager.signOut("linear")
        await assertEventually { manager.busy.isEmpty }
        manager.setEnabled("notes", true)
        await assertEventually { manager.busy.isEmpty }
        XCTAssertNil(manager.lastError)
        XCTAssertEqual(fake.requests("mcp_reconnect").first?["serverName"] as? String, "linear")
        XCTAssertEqual(fake.requests("mcp_clear_auth").first?["serverName"] as? String, "linear")
        XCTAssertEqual(fake.requests("mcp_toggle").first?["enabled"] as? Bool, true)
        XCTAssertEqual(announced(), ["linear", "linear", "notes"])
    }

    func testFailedActionReportsTheServer() async throws {
        let manager = try await loaded()
        try fake.set("mcp_toggle.error", "toggle failed")
        manager.setEnabled("notes", false)
        await assertEventually { manager.busy.isEmpty }
        XCTAssertEqual(manager.lastError, "notes: toggle failed")
    }

    func testSignInWaitsForTheServerToConnect() async throws {
        let manager = try await loaded([MCPFixtures.server("linear", status: "needs-auth")])
        try fake.setStatus([MCPFixtures.server("linear", status: "connected")])
        let announced = observe(.mcpServerDidChange)
        manager.signIn("linear")
        manager.signIn("linear") // already busy: ignored
        await assertEventually(timeout: 6) { manager.busy.isEmpty }
        XCTAssertEqual(fake.requests("mcp_authenticate").count, 1)
        XCTAssertEqual(manager.server("linear")?.status, .connected)
        XCTAssertNil(manager.signingIn["linear"])
        XCTAssertEqual(announced(), ["linear"])
        manager.cancelSignIn("linear")
        XCTAssertTrue(manager.signingIn.isEmpty)
    }

    func testSignInFailureIsReported() async throws {
        let manager = try await loaded([MCPFixtures.server("linear", status: "needs-auth")])
        try fake.set("mcp_authenticate.error", "no oauth")
        manager.signIn("linear")
        await assertEventually { manager.busy.isEmpty }
        XCTAssertEqual(manager.lastError, "Sign-in for linear failed: no oauth")
    }

    func testAddRunsAddJSONAndReloads() async throws {
        let manager = try await loaded([MCPFixtures.server("a")])
        let error = await manager.add(name: "new", scope: "user", config: ["type": "http", "url": "https://x.example.com"])
        XCTAssertNil(error)
        let line = fake.log("cli.log")
        XCTAssertTrue(line.hasPrefix("mcp add-json --scope user new {"), line)
        XCTAssertTrue(line.contains("\"url\""))
        await assertEventually { self.fake.requests("initialize").count == 2 && !manager.isLoading }
    }

    func testAddReportsCLIOutputOrExitStatus() async throws {
        let manager = makeMCPManager(fake, directory: dir)
        try fake.set("cli.status", "1")
        try fake.set("cli.stderr", "Server already exists")
        let withText = await manager.add(name: "dup", scope: "local", config: [:])
        XCTAssertEqual(withText, "Server already exists")
        try FileManager.default.removeItem(at: fake.dir.appendingPathComponent("cli.stderr"))
        try fake.set("cli.status", "2")
        let bare = await manager.add(name: "dup", scope: "local", config: [:])
        XCTAssertEqual(bare, "claude exited with 2")
    }

    func testRemoveRunsTheCLIForEditableScopesOnly() async throws {
        let manager = try await loaded()
        let plugin = try XCTUnwrap(manager.server("plugin:takt-engineering:github"))
        let refused = await manager.remove(plugin)
        XCTAssertEqual(refused, "plugin:takt-engineering:github is managed by Plugins and can't be removed here.")
        XCTAssertEqual(fake.log("cli.log"), "")

        let local = try XCTUnwrap(manager.server("local-files"))
        let removed = await manager.remove(local)
        XCTAssertNil(removed)
        XCTAssertEqual(fake.log("cli.log"), "mcp remove --scope local local-files\n")

        try fake.set("cli.status", "1")
        let failed = await manager.remove(local)
        XCTAssertEqual(failed, "claude exited with 1")
    }

    func testCanInspectOnlyStdioAndUnauthenticatedHTTP() async throws {
        let manager = try await loaded()
        func can(_ name: String) -> Bool { manager.canInspect(manager.server(name)!) }
        XCTAssertTrue(can("repo-db"), "stdio")
        XCTAssertTrue(can("local-files"), "stdio, even when failing")
        XCTAssertFalse(can("linear"), "needs auth")
        XCTAssertFalse(can("notes"), "sse")
        XCTAssertFalse(can("plugin:takt-engineering:github"), "oauth")
        XCTAssertFalse(can("claude.ai Notion"), "claude.ai proxy")
        let plain = MCPServerEntry.parse(MCPFixtures.server("plain"))
        XCTAssertTrue(manager.canInspect(plain))
        let connector = MCPServerEntry.parse(MCPFixtures.server("c", scope: "claudeai", config: ["type": "http", "url": "https://x"]))
        XCTAssertFalse(manager.canInspect(connector))
    }

    func testLoadToolDetailsAsksTheServer() async throws {
        let server = try FakeMCPServer.write(in: dir)
        var env = fake.environment
        env["GREETING"] = "world"
        let manager = MCPManager(directory: dir.path, binary: fake.binary, environment: env)
        defer { manager.stop() }
        let entry = MCPServerEntry.parse(MCPFixtures.server("fake", config: ["command": server, "args": ["ok", "two"]]))
        manager.loadToolDetails(entry)
        XCTAssertTrue(manager.loadingTools.contains("fake"))
        manager.loadToolDetails(entry) // already loading: ignored
        await assertEventually(timeout: 10) { manager.loadingTools.isEmpty }
        XCTAssertNil(manager.toolErrors["fake"])
        XCTAssertEqual(manager.toolDetails["fake"]?.map(\.name), ["first", "second"])
        XCTAssertEqual(manager.toolDetails["fake"]?.first?.description, "hello world")
    }

    func testLoadToolDetailsRecordsErrors() async throws {
        let manager = makeMCPManager(fake, directory: dir)
        let entry = MCPServerEntry.parse(MCPFixtures.server("ws", config: ["type": "ws"]))
        manager.loadToolDetails(entry)
        await assertEventually { manager.loadingTools.isEmpty }
        XCTAssertEqual(manager.toolErrors["ws"], "Tool descriptions aren't available for ws servers.")
        XCTAssertNil(manager.toolDetails["ws"])
    }
}
