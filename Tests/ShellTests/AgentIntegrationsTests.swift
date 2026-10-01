import XCTest
@testable import Shell

/// Installing and removing the agent status hooks, against a temporary home
/// folder (never the real ~/.claude or ~/.codex).
@MainActor
final class AgentIntegrationsTests: XCTestCase {
    private var home: URL!
    private var integrations: AgentIntegrations!

    override func setUp() async throws {
        home = try makeTemporaryDirectory()
        integrations = AgentIntegrations(home: home)
    }

    private var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }
    private var codexConfig: URL { home.appendingPathComponent(".codex/config.toml") }

    private func readSettings() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: claudeSettings)) as? [String: Any])
    }

    private func hookCommands(_ settings: [String: Any], _ event: String) -> [String] {
        let groups = (settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    func testPathsAndInitialStatusUseTheGivenHome() {
        XCTAssertEqual(integrations.claudeSettingsURL, claudeSettings)
        XCTAssertEqual(integrations.codexConfigURL, codexConfig)
        XCTAssertEqual(integrations.claude, .notInstalled)
        XCTAssertEqual(integrations.codex, .notInstalled)
        XCTAssertNil(integrations.lastError)
        XCTAssertEqual(AgentIntegrations.claudeCommand("Stop"),
                       #"[ -n "$SHELL_APP_CTL" ] && "$SHELL_APP_CTL" claude-hook Stop || true"#)
    }

    func testReportsOhMyZshFromTheShell() {
        integrations.shellReported(omz: "/Users/me/.oh-my-zsh", theme: "robbyrussell")
        XCTAssertEqual(integrations.ohMyZshPath, "/Users/me/.oh-my-zsh")
        XCTAssertEqual(integrations.ohMyZshTheme, "robbyrussell")
        integrations.shellReported(omz: "", theme: nil)
        XCTAssertNil(integrations.ohMyZshPath)
        XCTAssertNil(integrations.ohMyZshTheme)
    }

    // MARK: Claude Code

    func testInstallingClaudeHooksCreatesTheSettings() throws {
        integrations.installClaude()
        XCTAssertEqual(integrations.claude, .installed)
        XCTAssertNil(integrations.lastError)
        let settings = try readSettings()
        for event in AgentIntegrations.claudeEvents {
            XCTAssertEqual(hookCommands(settings, event), [AgentIntegrations.claudeCommand(event)], event)
        }
        let notification = ((settings["hooks"] as? [String: Any])?["Notification"] as? [[String: Any]])?.first
        XCTAssertEqual(notification?["matcher"] as? String, "", "Notification hooks match every notification")
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeSettings.path + ".shell-backup"), "nothing to back up yet")
    }

    func testInstallingClaudeHooksKeepsExistingSettingsAndIsIdempotent() throws {
        try FileManager.default.createDirectory(at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing: [String: Any] = ["model": "opus", "hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]]]
        try JSONSerialization.data(withJSONObject: existing).write(to: claudeSettings)

        integrations.installClaude()
        integrations.installClaude()
        let settings = try readSettings()
        XCTAssertEqual(settings["model"] as? String, "opus")
        XCTAssertEqual(hookCommands(settings, "Stop"), ["say done", AgentIntegrations.claudeCommand("Stop")], "installed once, after the user's hook")
        XCTAssertEqual(hookCommands(settings, "SessionEnd").count, 1)
        let backup = try Data(contentsOf: URL(fileURLWithPath: claudeSettings.path + ".shell-backup"))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: backup) as? [String: Any], "the previous file is backed up")

        integrations.uninstallClaude()
        XCTAssertEqual(integrations.claude, .notInstalled)
        let cleaned = try readSettings()
        XCTAssertEqual(hookCommands(cleaned, "Stop"), ["say done"], "the user's own hooks stay")
        XCTAssertNil((cleaned["hooks"] as? [String: Any])?["UserPromptSubmit"], "events left empty are removed")
        XCTAssertEqual(cleaned["model"] as? String, "opus")
    }

    func testUninstallingTheOnlyHooksRemovesTheHooksKey() throws {
        integrations.installClaude()
        var settings = try readSettings()
        var hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        hooks["Custom"] = "not a list"
        settings["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: settings).write(to: claudeSettings)
        integrations.uninstallClaude()
        XCTAssertEqual((try readSettings()["hooks"] as? [String: Any])?.keys.sorted(), ["Custom"])

        try Data(#"{"theme": "dark"}"#.utf8).write(to: claudeSettings)
        integrations.uninstallClaude() // no hooks: nothing to do
        XCTAssertEqual(try readSettings()["theme"] as? String, "dark")

        try JSONSerialization.data(withJSONObject: ["hooks": ["Stop": [["hooks": [["command": AgentIntegrations.claudeCommand("Stop")]]]]]])
            .write(to: claudeSettings)
        integrations.uninstallClaude()
        XCTAssertNil(try readSettings()["hooks"])
    }

    func testAnEmptySettingsFileIsTreatedAsEmpty() throws {
        try FileManager.default.createDirectory(at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: claudeSettings)
        integrations.installClaude()
        XCTAssertEqual(integrations.claude, .installed)
    }

    func testUnreadableClaudeSettingsAreLeftAlone() throws {
        try FileManager.default.createDirectory(at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[1, 2]".utf8).write(to: claudeSettings)
        integrations.installClaude()
        XCTAssertEqual(integrations.lastError?.hasPrefix("Couldn't update \(claudeSettings.path)"), true)
        XCTAssertEqual(try String(contentsOf: claudeSettings, encoding: .utf8), "[1, 2]")
        XCTAssertEqual(integrations.claude, .notInstalled)

        integrations.uninstallClaude()
        XCTAssertNotNil(integrations.lastError)
        XCTAssertEqual(try String(contentsOf: claudeSettings, encoding: .utf8), "[1, 2]")

        // Not UTF-8: can't be ours.
        try Data([0xFF, 0xFE, 0x00]).write(to: claudeSettings)
        integrations.refresh()
        XCTAssertEqual(integrations.claude, .notInstalled)
    }

    // MARK: Codex

    func testInstallingTheCodexNotifyHook() throws {
        integrations.installCodex(replace: false)
        XCTAssertEqual(integrations.codex, .installed)
        XCTAssertNil(integrations.lastError)
        let text = try String(contentsOf: codexConfig, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# Added by Shell.app: agent notifications in Shell tabs\n\(AgentIntegrations.codexNotifyLine)\n"))

        // Reinstalling our own hook replaces it in place.
        integrations.installCodex(replace: false)
        XCTAssertEqual(try String(contentsOf: codexConfig, encoding: .utf8).components(separatedBy: AgentIntegrations.codexNotifyLine).count, 2)

        integrations.uninstallCodex()
        XCTAssertEqual(integrations.codex, .notInstalled)
        XCTAssertFalse(try String(contentsOf: codexConfig, encoding: .utf8).contains("Shell.app"), "the comment goes with the hook")
    }

    func testAnotherNotifyHookIsAConflictUntilReplaced() throws {
        try FileManager.default.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "model = \"o3\"\n  notify = [\"terminal-notifier\"]\n\n[profiles.fast]\nmodel = \"mini\"\n"
        try original.write(to: codexConfig, atomically: true, encoding: .utf8)
        integrations.refresh()
        XCTAssertEqual(integrations.codex, .conflict(#"notify = ["terminal-notifier"]"#))

        integrations.installCodex(replace: false)
        XCTAssertEqual(integrations.codex, .conflict(#"  notify = ["terminal-notifier"]"#))
        XCTAssertEqual(try String(contentsOf: codexConfig, encoding: .utf8), original, "not replaced without asking")
        integrations.uninstallCodex() // not ours: nothing removed
        XCTAssertEqual(try String(contentsOf: codexConfig, encoding: .utf8), original)

        integrations.installCodex(replace: true)
        XCTAssertEqual(integrations.codex, .installed)
        let text = try String(contentsOf: codexConfig, encoding: .utf8)
        XCTAssertTrue(text.contains("model = \"o3\"\n\(AgentIntegrations.codexNotifyLine)\n"))
        XCTAssertTrue(text.contains("[profiles.fast]"))
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: codexConfig.path + ".shell-backup"), encoding: .utf8), original)

        integrations.uninstallCodex()
        XCTAssertEqual(try String(contentsOf: codexConfig, encoding: .utf8), "model = \"o3\"\n\n[profiles.fast]\nmodel = \"mini\"\n")
    }

    func testNotifyInsideATableIsntTopLevel() throws {
        try FileManager.default.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[tui]\nnotify = true\n".write(to: codexConfig, atomically: true, encoding: .utf8)
        integrations.refresh()
        XCTAssertEqual(integrations.codex, .notInstalled)
        integrations.installCodex(replace: false)
        XCTAssertEqual(integrations.codex, .installed)
        XCTAssertTrue(try String(contentsOf: codexConfig, encoding: .utf8).hasSuffix("\n[tui]\nnotify = true\n"))
        integrations.uninstallCodex()
        XCTAssertEqual(try String(contentsOf: codexConfig, encoding: .utf8), "\n[tui]\nnotify = true\n")
    }

    func testUnwritableCodexConfigReportsAnError() throws {
        try FileManager.default.createDirectory(at: codexConfig, withIntermediateDirectories: true) // a folder where the file goes
        integrations.installCodex(replace: false)
        XCTAssertEqual(integrations.lastError?.hasPrefix("Couldn't update \(codexConfig.path)"), true)
        XCTAssertEqual(integrations.codex, .notInstalled)
        integrations.uninstallCodex()
    }
}
