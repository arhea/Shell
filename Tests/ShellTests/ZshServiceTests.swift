import SwiftUI
import XCTest
@testable import Shell

/// A fake home with an Oh My Zsh install, a fake `zsh` and a recorder for
/// commands that would open a terminal tab.
@MainActor
private final class ZshFixture {
    let home: URL
    let omz: URL
    var commands: [(command: String, title: String)] = []
    var reported: String?

    init(home: URL, withOhMyZsh: Bool = true) throws {
        self.home = home
        omz = home.appendingPathComponent(".oh-my-zsh")
        let fm = FileManager.default
        let zsh = home.appendingPathComponent("bin/zsh")
        try writeExecutable("#!/bin/sh\necho 'zsh 5.9 (arm64-apple-darwin25.0)'\n", to: zsh)
        guard withOhMyZsh else { return }
        for dir in ["plugins/git", "plugins/docker", "plugins/zsh-autosuggestions", "plugins/.hidden", "plugins/rare-plugin",
                    "custom/plugins/example", "custom/plugins/zsh-syntax-highlighting", "themes", "custom/themes/powerlevel10k",
                    "custom/themes/not-a-theme"] {
            try fm.createDirectory(at: omz.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for file in ["oh-my-zsh.sh", "themes/robbyrussell.zsh-theme", "themes/agnoster.zsh-theme", "themes/example.zsh-theme",
                     "themes/README.md", "custom/themes/mine.zsh-theme", "custom/themes/powerlevel10k/powerlevel10k.zsh-theme"] {
            fm.createFile(atPath: omz.appendingPathComponent(file).path, contents: Data())
        }
    }

    var zshrc: URL { home.appendingPathComponent(".zshrc") }

    func writeRC(_ text: String) throws { try text.write(to: zshrc, atomically: true, encoding: .utf8) }
    func readRC() throws -> String { try String(contentsOf: zshrc, encoding: .utf8) }

    func service(zdotdir: String? = nil) -> ZshService {
        ZshService(home: home, zdotdir: zdotdir, zsh: home.appendingPathComponent("bin/zsh").path,
                   reportedOhMyZsh: { [weak self] in self?.reported },
                   terminal: { [weak self] in self?.commands.append(($0, $1)) })
    }
}

private let sampleRC = """
# Path to your oh-my-zsh installation.
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
# plugins=(commented out)
plugins=(
  git   # version control
  docker
  zsh-syntax-highlighting
)
source $ZSH/oh-my-zsh.sh
"""

// MARK: - Parsing

@MainActor
final class ZshParsingTests: XCTestCase {
    func testParsesThemeAndPlugins() {
        XCTAssertEqual(ZshService.parseTheme(sampleRC), "robbyrussell")
        XCTAssertEqual(ZshService.parseTheme("  ZSH_THEME='agnoster' "), "agnoster")
        XCTAssertNil(ZshService.parseTheme("export ZSH=~/.oh-my-zsh"))
        XCTAssertEqual(ZshService.parsePlugins(sampleRC), ["git", "docker", "zsh-syntax-highlighting"])
        XCTAssertEqual(ZshService.parsePlugins("plugins=(git z)"), ["git", "z"])
        XCTAssertEqual(ZshService.parsePlugins("plugins=()"), [])
        XCTAssertNil(ZshService.parsePlugins("# plugins=(git)"), "commented out")
        XCTAssertNil(ZshService.parsePlugins("myplugins=(git)"), "not the plugins array")
        XCTAssertNil(ZshService.parsePlugins("plugins=(git"), "unterminated")
        XCTAssertNil(ZshService.parsePlugins(""))
    }

    func testPluginsRangeSkipsCommentedBlocks() throws {
        let range = try XCTUnwrap(ZshService.pluginsRange(sampleRC))
        XCTAssertTrue(sampleRC[range].hasPrefix("plugins=(\n  git"))
        XCTAssertTrue(sampleRC[range].hasSuffix(")"))
    }

    func testExternalPluginCatalog() {
        XCTAssertEqual(ZshService.externalPlugins.map(\.id).first, "zsh-autosuggestions")
        XCTAssertTrue(ZshService.externalPlugins.allSatisfy { $0.repo.hasPrefix("https://github.com/") })
        XCTAssertTrue(ZshSettingsPane.recommended.contains("git"))
    }
}

// MARK: - Service

@MainActor
final class ZshServiceTests: XCTestCase {
    private var fixture: ZshFixture!

    override func setUp() async throws {
        fixture = try ZshFixture(home: try makeTemporaryDirectory())
    }

    func testRefreshReadsVersionOhMyZshAndTheRC() async throws {
        try fixture.writeRC(sampleRC)
        let zsh = fixture.service()
        XCTAssertEqual(zsh.zshrcURL, fixture.zshrc)
        await zsh.refresh()
        XCTAssertEqual(zsh.zshVersion, "zsh 5.9 (arm64-apple-darwin25.0)")
        XCTAssertFalse(zsh.loginShell.isEmpty)
        XCTAssertEqual(zsh.isZshDefault, (zsh.loginShell as NSString).lastPathComponent == "zsh")
        XCTAssertEqual(zsh.omzPath, fixture.omz.path)
        XCTAssertTrue(zsh.isOhMyZshInstalled)
        XCTAssertEqual(zsh.customPath, fixture.omz.path + "/custom")
        XCTAssertEqual(zsh.theme, "robbyrussell")
        XCTAssertEqual(zsh.enabledPlugins, ["git", "docker", "zsh-syntax-highlighting"])
        XCTAssertEqual(zsh.availablePlugins, ["docker", "git", "rare-plugin", "zsh-autosuggestions", "zsh-syntax-highlighting"])
        XCTAssertEqual(zsh.availableThemes, ["agnoster", "mine", "powerlevel10k/powerlevel10k", "robbyrussell"])
        XCTAssertTrue(zsh.isPluginInstalled("git"))
        XCTAssertTrue(zsh.isPluginInstalled("zsh-syntax-highlighting"))
        XCTAssertFalse(zsh.isPluginInstalled("fzf-tab"))
        XCTAssertNil(zsh.lastError)
    }

    func testPrefersTheOhMyZshPathReportedByTheShell() async throws {
        let elsewhere = try makeTemporaryDirectory()
        FileManager.default.createFile(atPath: elsewhere.appendingPathComponent("oh-my-zsh.sh").path, contents: Data())
        fixture.reported = elsewhere.path
        let zsh = fixture.service()
        await zsh.refresh()
        XCTAssertEqual(zsh.omzPath, elsewhere.path)
        XCTAssertTrue(zsh.availablePlugins.isEmpty)
    }

    func testWithoutOhMyZshOrRC() async throws {
        let bare = try ZshFixture(home: try makeTemporaryDirectory(), withOhMyZsh: false)
        let zsh = bare.service()
        await zsh.refresh()
        XCTAssertNil(zsh.omzPath)
        XCTAssertNil(zsh.customPath)
        XCTAssertNil(zsh.theme)
        XCTAssertEqual(zsh.enabledPlugins, [])
        XCTAssertFalse(zsh.isPluginInstalled("git"))
        zsh.installExternal(ZshService.externalPlugins[0])
        zsh.installPowerlevel10k()
        XCTAssertTrue(bare.commands.isEmpty, "nowhere to install into")
    }

    func testZDOTDIRMovesTheRC() throws {
        let dotdir = try makeTemporaryDirectory()
        XCTAssertEqual(fixture.service(zdotdir: dotdir.path).zshrcURL, dotdir.appendingPathComponent(".zshrc"))
    }

    func testSetThemeReplacesTheLineAndKeepsABackup() async throws {
        try fixture.writeRC(sampleRC)
        let zsh = fixture.service()
        await zsh.refresh()
        zsh.setTheme("agnoster")
        XCTAssertEqual(zsh.theme, "agnoster")
        XCTAssertTrue(try fixture.readRC().contains("ZSH_THEME=\"agnoster\"\n"))
        XCTAssertFalse(try fixture.readRC().contains("robbyrussell"))
        let backup = try String(contentsOf: fixture.home.appendingPathComponent(".zshrc.shell-backup"), encoding: .utf8)
        XCTAssertEqual(backup, sampleRC)
        zsh.setTheme("agnoster") // no change: nothing rewritten
        XCTAssertEqual(try String(contentsOf: fixture.home.appendingPathComponent(".zshrc.shell-backup"), encoding: .utf8), sampleRC)
    }

    func testSetThemeInsertsBeforeOhMyZshOrAtTheTop() throws {
        try fixture.writeRC("export ZSH=x\nsource $ZSH/oh-my-zsh.sh\n")
        let zsh = fixture.service()
        zsh.setTheme("mine")
        XCTAssertEqual(try fixture.readRC(), "export ZSH=x\nZSH_THEME=\"mine\"\nsource $ZSH/oh-my-zsh.sh\n")

        try fixture.writeRC("alias ll='ls -l'")
        zsh.setTheme("agnoster")
        XCTAssertEqual(try fixture.readRC(), "ZSH_THEME=\"agnoster\"\nalias ll='ls -l'")
    }

    func testEnablingAndDisablingPlugins() async throws {
        try fixture.writeRC(sampleRC)
        let zsh = fixture.service()
        await zsh.refresh()
        zsh.setPlugin("z", enabled: true)
        XCTAssertEqual(zsh.enabledPlugins, ["git", "docker", "z", "zsh-syntax-highlighting"], "highlighting stays last")
        XCTAssertTrue(try fixture.readRC().contains("plugins=(git docker z zsh-syntax-highlighting)\nsource"))
        zsh.setPlugin("z", enabled: true) // already on
        zsh.setPlugin("docker", enabled: false)
        XCTAssertEqual(zsh.enabledPlugins, ["git", "z", "zsh-syntax-highlighting"])
        XCTAssertTrue(try fixture.readRC().contains("# plugins=(commented out)"), "comments survive")
    }

    func testEnablingAPluginWithoutAPluginsLine() throws {
        try fixture.writeRC("export ZSH=x\nsource $ZSH/oh-my-zsh.sh")
        let zsh = fixture.service()
        zsh.setPlugin("git", enabled: true)
        XCTAssertEqual(try fixture.readRC(), "export ZSH=x\nplugins=(git)\nsource $ZSH/oh-my-zsh.sh")

        try fixture.writeRC("alias x=y")
        let fresh = fixture.service()
        fresh.setPlugin("git", enabled: true)
        XCTAssertEqual(try fixture.readRC(), "alias x=y\nplugins=(git)")
    }

    func testCreatesTheRCWhenMissingAndReportsWriteFailures() throws {
        let zsh = fixture.service()
        zsh.setTheme("agnoster")
        XCTAssertEqual(try fixture.readRC(), "ZSH_THEME=\"agnoster\"\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".zshrc.shell-backup").path),
                       "nothing to back up")

        let readOnly = try makeTemporaryDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path) }
        let blocked = fixture.service(zdotdir: readOnly.path)
        blocked.setTheme("x")
        XCTAssertTrue(blocked.lastError?.hasPrefix("Couldn't write") ?? false, blocked.lastError ?? "nil")
        XCTAssertEqual(blocked.theme, "x", "the in-memory state follows the requested change")
    }

    func testCommandsRunInATerminalTab() async throws {
        try fixture.writeRC(sampleRC)
        let zsh = fixture.service()
        await zsh.refresh()
        zsh.installOhMyZsh()
        zsh.updateOhMyZsh()
        zsh.makeZshDefault()
        zsh.installExternal(ZshService.externalPlugins[1])
        zsh.installPowerlevel10k()
        zsh.reloadOpenShells()
        XCTAssertEqual(fixture.commands.map(\.title), ["Install Oh My Zsh", "Update Oh My Zsh", "Default shell", "zsh-syntax-highlighting", "powerlevel10k"])
        XCTAssertEqual(fixture.commands[0].command, ZshService.ohMyZshInstall)
        XCTAssertEqual(fixture.commands[2].command, "chsh -s /bin/zsh")
        XCTAssertTrue(fixture.commands[3].command.hasPrefix("git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting "))
        XCTAssertTrue(fixture.commands[3].command.contains("custom/plugins/zsh-syntax-highlighting"))
        XCTAssertTrue(fixture.commands[4].command.contains("romkatv/powerlevel10k.git"))
        XCTAssertEqual(zsh.theme, "powerlevel10k/powerlevel10k")
    }
}

// MARK: - Pane

@MainActor
final class ZshSettingsPaneTests: XCTestCase {
    func testRendersWithOhMyZshInEveryFilterState() async throws {
        let fixture = try ZshFixture(home: try makeTemporaryDirectory())
        try fixture.writeRC(sampleRC.replacingOccurrences(of: "robbyrussell", with: "custom-missing"))
        let zsh = fixture.service()
        await zsh.refresh()
        render(ZshSettingsPane(zsh: zsh))
        render(ZshSettingsPane(zsh: zsh, pluginFilter: "rare", changed: true))
        XCTAssertTrue(fixture.commands.isEmpty)
    }

    func testRendersWithPowerlevel10kInstalledAndNoTheme() async throws {
        let fixture = try ZshFixture(home: try makeTemporaryDirectory())
        let zsh = fixture.service()
        await zsh.refresh()
        XCTAssertNil(zsh.theme)
        render(ZshSettingsPane(zsh: zsh))
    }

    func testRendersWithoutOhMyZshAndWithAnError() async throws {
        let fixture = try ZshFixture(home: try makeTemporaryDirectory(), withOhMyZsh: false)
        let readOnly = try makeTemporaryDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path) }
        let zsh = fixture.service(zdotdir: readOnly.path)
        await zsh.refresh()
        zsh.setTheme("x")
        XCTAssertNotNil(zsh.lastError)
        render(ZshSettingsPane(zsh: zsh))
    }
}
