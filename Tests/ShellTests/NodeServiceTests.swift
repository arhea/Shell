import SwiftUI
import XCTest
@testable import Shell

// MARK: - Fixtures

/// Canned responses for nodejs.org, the npm registry and GitHub.
/// Lock-protected: read from NodeService's fetch tasks, written by the test.
private final class Web: @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [String: Data] = [:]
    private var log: [String] = []

    subscript(url: String) -> Data? {
        get { lock.withLock { pages[url] } }
        set { lock.withLock { pages[url] = newValue } }
    }

    var requests: [String] { lock.withLock { log } }

    func fetch(_ url: String) -> Data? {
        lock.withLock {
            log.append(url)
            return pages[url]
        }
    }
}

private let indexURL = "https://nodejs.org/dist/index.json"
private let scheduleURL = "https://raw.githubusercontent.com/nodejs/Release/main/schedule.json"
private let nvmReleaseURL = "https://api.github.com/repos/nvm-sh/nvm/releases/latest"
private func registry(_ name: String) -> String { "https://registry.npmjs.org/\(name)/latest" }

private func json(_ obj: Any) -> Data { (try? JSONSerialization.data(withJSONObject: obj)) ?? Data() }

/// A fake Node toolchain in a temp folder: a stand-in `zsh` that reports the
/// login environment from `env.txt` and answers nvm's commands, plus helpers
/// that lay out n- or nvm-managed installs with fake node, npm, pnpm, yarn and bun.
/// Every fake logs its arguments to `<name>.log` in `root` and exits with the
/// status in `<name>.status` (default 0).
@MainActor
private final class NodeFixture {
    let root: URL
    let web = Web()
    var commands: [(command: String, title: String)] = []
    var brewInstalled = true

    var home: URL { root.appendingPathComponent("home") }
    var path: URL { root.appendingPathComponent("path") }
    var nPrefix: URL { root.appendingPathComponent("nprefix") }
    var nvmDir: URL { root.appendingPathComponent("nvm") }
    var zshrc: URL { home.appendingPathComponent(".zshrc") }

    init(root: URL) throws {
        self.root = root
        let fm = FileManager.default
        for dir in [home, path, root.appendingPathComponent("bin")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try exe(root.appendingPathComponent("bin/zsh"), #"""
        root="\#(root.path)"
        case "$1" in
          -lic) cat "$root/env.txt" ;;
          -c)
            case "$2" in
              *"nvm --version"*) cat "$root/nvm.version" 2>/dev/null ;;
              *"nvm version default"*) cat "$root/nvm.default" 2>/dev/null ;;
              *) echo "$2" >> "$root/nvm.log"; exit "$(cat "$root/nvm.status" 2>/dev/null || echo 0)" ;;
            esac ;;
        esac
        """#)
        try exe(root.appendingPathComponent("bin/brew"), #"""
        echo "$*" >> "\#(root.path)/brew.log"
        exit "$(cat "\#(root.path)/brew.status" 2>/dev/null || echo 0)"
        """#)
        setReleases()
        web[registry("npm")] = json(["version": "11.6.0"])
        web[registry("pnpm")] = json(["version": "10.0.0"])
        web[registry("@yarnpkg/cli-dist")] = json(["version": "4.1.0"])
        web[registry("yarn")] = json(["version": "1.22.22"])
        web[registry("bun")] = json(["version": "1.3.0"])
        web[nvmReleaseURL] = json(["tag_name": "v0.40.9"])
    }

    // MARK: Files

    @discardableResult
    func exe(_ url: URL, _ body: String) throws -> String {
        try writeExecutable("#!/bin/sh\n" + body + "\n", to: url)
    }

    func link(_ url: URL, to target: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    }

    func write(_ name: String, _ text: String) throws {
        try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func log(_ name: String) -> [String] {
        ((try? String(contentsOf: root.appendingPathComponent("\(name).log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    /// A fake tool that logs, honors `<name>.status`, and prints `version` for --version.
    private func tool(_ name: String, version: String, extra: String = "") -> String {
        #"""
        root="\#(root.path)"
        echo "$*" >> "$root/\#(name).log"
        case "$1" in
          --version) echo "\#(version)" ;;
          \#(extra)
          *) exit "$(cat "$root/\#(name).status" 2>/dev/null || echo 0)" ;;
        esac
        """#
    }

    /// The login environment the fake zsh reports.
    func setEnv(path: [String]? = nil, nPrefix: String = "", nvmDir: String = "", node: [String] = []) throws {
        let p = (path ?? [self.path.path]) + ["/usr/bin", "/bin"]
        try write("env.txt", """
        noise from .zshrc
        __SHELLAPP_BEGIN__
        PATH=\(p.joined(separator: ":"))
        N_PREFIX=\(nPrefix)
        NVM_DIR=\(nvmDir)
        NODE=\(node.joined(separator: ":"))
        ignored line without equals
        __SHELLAPP_END__
        """)
    }

    /// Package managers in `bin`: npm (bundled), pnpm via corepack, yarn from npm, bun from Homebrew.
    func installPackageManagers(in bin: URL, yarn: String = "4.1.0") throws {
        try exe(bin.appendingPathComponent("npm"), tool("npm", version: "10.9.0", extra: #"""
        doctor) printf 'Check  Value\nok  npm ping\nnot ok  registry: unreachable\n' ;;
        """#).replacingOccurrences(of: #"echo "10.9.0""#, with: #"echo "npm notice"; echo "10.9.0""#))
        try exe(bin.appendingPathComponent("corepack"), tool("corepack", version: "0.31.0"))
        let lib = bin.deletingLastPathComponent().appendingPathComponent("lib/node_modules")
        let pnpm = try exe(lib.appendingPathComponent("corepack/shims/pnpm"), tool("pnpm", version: "9.0.0"))
        try link(bin.appendingPathComponent("pnpm"), to: URL(fileURLWithPath: pnpm))
        let yarnPath = try exe(lib.appendingPathComponent("yarn/bin/yarn"), tool("yarn", version: yarn))
        try link(bin.appendingPathComponent("yarn"), to: URL(fileURLWithPath: yarnPath))
        let bun = try exe(root.appendingPathComponent("Cellar/bun/1.2.0/bin/bun"), tool("bun", version: "1.2.0"))
        try? FileManager.default.removeItem(at: path.appendingPathComponent("bun"))
        try link(path.appendingPathComponent("bun"), to: URL(fileURLWithPath: bun))
    }

    /// n in PATH managing `nPrefix`, with `versions` cached and `active` in use.
    func makeN(active: String = "22.11.0", versions: [String] = ["22.11.0", "20.18.0"], fromHomebrew: Bool = false) throws {
        let n = tool("n", version: "10.1.0", extra: #"""
        prune|rm) [ -f "$root/n.sleep" ] && sleep 1; exit "$(cat "$root/n.status" 2>/dev/null || echo 0)" ;;
        [0-9]*) [ -f "$root/n.status" ] && exit "$(cat "$root/n.status")"; echo "v$1" > "$root/active" ;;
        """#)
        if fromHomebrew {
            let cellar = try exe(root.appendingPathComponent("Cellar/n/10.1.0/bin/n"), n)
            try link(path.appendingPathComponent("n"), to: URL(fileURLWithPath: cellar))
        } else {
            try exe(path.appendingPathComponent("n"), n)
        }
        try exe(nPrefix.appendingPathComponent("bin/node"), #"cat "\#(root.path)/active""#)
        try write("active", "v\(active)\n")
        for v in versions {
            try FileManager.default.createDirectory(at: nPrefix.appendingPathComponent("n/versions/node/\(v)"), withIntermediateDirectories: true)
            try Data(repeating: 0, count: 4096).write(to: nPrefix.appendingPathComponent("n/versions/node/\(v)/node"))
        }
        try installPackageManagers(in: nPrefix.appendingPathComponent("bin"))
    }

    /// nvm in `nvmDir` with `versions` installed and `active` as the default.
    func makeNvm(active: String = "24.10.0", versions: [String] = ["24.10.0", "22.11.0"]) throws {
        try FileManager.default.createDirectory(at: nvmDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: nvmDir.appendingPathComponent("nvm.sh").path, contents: Data())
        try write("nvm.version", "0.40.3\n")
        try write("nvm.default", "v\(active)\n")
        for v in versions {
            try FileManager.default.createDirectory(at: nvmDir.appendingPathComponent("versions/node/v\(v)/bin"), withIntermediateDirectories: true)
        }
        try installPackageManagers(in: nvmDir.appendingPathComponent("versions/node/v\(active)/bin"))
    }

    // MARK: Releases

    private static func day(_ offset: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date().addingTimeInterval(Double(offset) * 86400))
    }

    /// Node 18 and 20 are end-of-life, 22 in maintenance, 24 active LTS,
    /// 25 a Current line that ends within 90 days. 22.12.0 is a security release.
    func setReleases() {
        web[indexURL] = json([
            ["version": "v25.2.0", "lts": false, "security": false, "date": "2026-09-01", "npm": "11.6.0"],
            ["version": "v24.11.0", "lts": "Krypton", "security": false, "date": "2026-08-20", "npm": "11.6.0"],
            ["version": "v24.10.0", "lts": "Krypton", "security": false, "date": "2026-07-01"],
            ["version": "v22.12.0", "lts": "Jod", "security": true, "date": "2026-06-01"],
            ["version": "v22.11.0", "lts": "Jod", "security": false, "date": "2026-05-01"],
            ["version": "v20.19.0", "lts": "Iron", "security": false, "date": "2026-01-01"],
            ["version": "v18.20.0", "lts": "Hydrogen"],
            ["version": "nightly"],
        ])
        let d = Self.day
        web[scheduleURL] = json([
            "v18": ["start": d(-1500), "lts": d(-1300), "maintenance": d(-900), "end": d(-400), "codename": "Hydrogen"],
            "v20": ["start": d(-900), "lts": d(-700), "maintenance": d(-300), "end": d(-10), "codename": "Iron"],
            "v22": ["start": d(-600), "lts": d(-400), "maintenance": d(-30), "end": d(300), "codename": "Jod"],
            "v24": ["start": d(-200), "lts": d(-30), "maintenance": d(300), "end": d(700), "codename": "Krypton"],
            "v25": ["start": d(-120), "end": d(30)],
            "vNext": ["start": d(10)],
        ])
    }

    func brewService() -> BrewService {
        BrewService(candidates: brewInstalled ? [root.appendingPathComponent("bin/brew").path] : [], terminal: { _, _ in })
    }

    func service() -> NodeService {
        var system = NodeService.System()
        system.zsh = root.appendingPathComponent("bin/zsh").path
        system.home = home.path
        system.nLocations = []
        system.defaultNPrefix = root.appendingPathComponent("usrlocal").path
        let web = web
        system.fetch = { web.fetch($0) }
        let zshrc = zshrc
        system.zshrcURL = { zshrc }
        system.terminal = { [weak self] in self?.commands.append(($0, $1)) }
        let brew = brewService()
        system.brew = { brew }
        return NodeService(system: system)
    }
}

// MARK: - Value types

final class NodeValueTypeTests: XCTestCase {
    func testSemVerParsingAndOrdering() {
        XCTAssertEqual(SemVer("v22.11.0"), SemVer(major: 22, minor: 11, patch: 0))
        XCTAssertEqual(SemVer(" 1.2 \n"), SemVer(major: 1, minor: 2))
        XCTAssertEqual(SemVer("10"), SemVer(major: 10))
        XCTAssertEqual(SemVer("4.0.0-rc.1+build"), SemVer(major: 4))
        XCTAssertEqual(SemVer("1.x.3"), SemVer(major: 1, minor: 0, patch: 3))
        XCTAssertNil(SemVer("nightly"))
        XCTAssertNil(SemVer(""))
        XCTAssertLessThan(SemVer("1.9.9")!, SemVer("1.10.0")!)
        XCTAssertEqual(SemVer(major: 1, minor: 2, patch: 3).description, "1.2.3")
        XCTAssertEqual(SemVer(major: 1, minor: 2, patch: 3).tag, "v1.2.3")
    }

    func testTracksRoundTrip() {
        XCTAssertEqual(NodeTrack("lts"), .lts)
        XCTAssertEqual(NodeTrack("current"), .current)
        XCTAssertEqual(NodeTrack("pinned"), .pinned)
        XCTAssertEqual(NodeTrack("22"), .major(22))
        XCTAssertEqual(NodeTrack("garbage"), .lts)
        for t in [NodeTrack.lts, .current, .pinned, .major(20)] { XCTAssertEqual(NodeTrack(t.raw), t) }
        XCTAssertEqual(NodeManagerKind.allCases.map(\.title), ["n", "nvm"])
        XCTAssertEqual(NodeManagerKind.nvm.id, "nvm")
    }

    func testLineStatusOverTime() {
        let now = Date()
        func at(_ days: Double) -> Date { now.addingTimeInterval(days * 86400) }
        let line = NodeLine(major: 22, codename: "Jod", start: at(-10), ltsStart: at(10), maintenanceStart: at(20), end: at(30))
        XCTAssertEqual(line.status(on: now), "Current")
        XCTAssertEqual(line.status(on: at(15)), "Active LTS")
        XCTAssertEqual(line.status(on: at(25)), "Maintenance LTS")
        XCTAssertEqual(line.status(on: at(31)), "End of life")
        XCTAssertTrue(line.isSupported(on: now))
        XCTAssertFalse(line.isSupported(on: at(31)))
        XCTAssertTrue(NodeLine(major: 30).isSupported())
    }

    func testPackageManagerStatus() {
        var pm = PackageManagerStatus(name: "pnpm")
        XCTAssertEqual(pm.id, "pnpm")
        XCTAssertFalse(pm.isInstalled)
        XCTAssertFalse(pm.isOutdated)
        pm.path = "/x/pnpm"
        pm.version = SemVer("9.0.0")
        XCTAssertFalse(pm.isOutdated, "latest unknown")
        pm.latest = SemVer("10.0.0")
        XCTAssertTrue(pm.isInstalled)
        XCTAssertTrue(pm.isOutdated)
        XCTAssertLessThan(NodeIssue.Severity.info, .error)
        XCTAssertEqual(NodeIssue(severity: .info, title: "t", detail: "").id, "t")
    }

    func testAsyncMap() async {
        let some: Int? = 2
        let none: Int? = nil
        let doubled = await some.asyncMap { $0 * 2 }
        let missing = await none.asyncMap { $0 * 2 }
        XCTAssertEqual(doubled, 4)
        XCTAssertNil(missing)
    }
}

// MARK: - Service

@MainActor
final class NodeServiceTests: XCTestCase {
    private var fx: NodeFixture!
    private var original: AppSettings!

    override func setUp() async throws {
        fx = try NodeFixture(root: try makeTemporaryDirectory())
        original = SettingsStore.shared.settings
        SettingsStore.shared.settings.nodeTrack = "lts"
        SettingsStore.shared.settings.nodeManager = .n
        SettingsStore.shared.settings.nodePackageManagers = ["npm", "pnpm", "yarn", "bun"]
        SettingsStore.shared.settings.nodePruneOldVersions = false
    }

    override func tearDown() async throws {
        SettingsStore.shared.settings = original
    }

    private func titles(_ node: NodeService) -> [String] { node.issues.map(\.title) }

    func testNManagedToolchain() async throws {
        try fx.makeN(versions: ["22.11.0", "20.18.0", "18.0.0", "16.0.0", "14.0.0", "12.0.0", "not-a-version"])
        try fx.exe(fx.path.appendingPathComponent("volta"), "exit 0")
        let other = fx.root.appendingPathComponent("other/node")
        try fx.setEnv(nPrefix: fx.nPrefix.path, node: [fx.nPrefix.path + "/bin/node", other.path])
        let node = fx.service()
        await node.refresh()

        XCTAssertFalse(node.isLoading)
        XCTAssertEqual(node.manager, .n)
        XCTAssertEqual(node.nBinary, fx.path.appendingPathComponent("n").path)
        XCTAssertEqual(node.nVersion, "10.1.0")
        XCTAssertFalse(node.nFromHomebrew)
        XCTAssertNil(node.nvmVersion)
        XCTAssertEqual(node.nPrefix, fx.nPrefix.path)
        XCTAssertNil(node.nvmDir)
        XCTAssertEqual(node.nodeOnPath.count, 2)
        XCTAssertTrue(node.otherManagers.contains("volta"))
        XCTAssertEqual(node.activeVersion, SemVer("22.11.0"))
        XCTAssertEqual(node.installed.map(\.description), ["22.11.0", "20.18.0", "18.0.0", "16.0.0", "14.0.0", "12.0.0"])
        XCTAssertEqual(node.nodeBinDirectory, fx.nPrefix.path + "/bin")
        XCTAssertTrue(node.toolPath.hasPrefix(fx.nPrefix.path + "/bin:" + fx.path.path))
        XCTAssertEqual(node.toolEnvironment["N_PREFIX"], fx.nPrefix.path)
        XCTAssertNil(node.toolEnvironment["NVM_DIR"])
        XCTAssertEqual(node.toolEnvironment["COREPACK_ENABLE_DOWNLOAD_PROMPT"], "0")

        // Releases and lines
        XCTAssertEqual(node.releases.count, 7, "unparseable versions are skipped")
        XCTAssertEqual(node.latestLTS?.version, SemVer("24.11.0"))
        XCTAssertEqual(node.latestCurrent?.version, SemVer("25.2.0"))
        XCTAssertEqual(node.line(for: SemVer("22.0.0")!)?.codename, "Jod")
        XCTAssertEqual(node.line(for: SemVer("22.0.0")!)?.status(), "Maintenance LTS")
        XCTAssertEqual(node.supportedLines.map(\.line.major), [25, 24, 22], "18 and 20 are end-of-life")
        XCTAssertEqual(node.supportedLines.first?.latest.version, SemVer("25.2.0"))
        XCTAssertEqual(node.updateAvailable?.version, SemVer("24.11.0"))

        // Package managers
        let pms = Dictionary(uniqueKeysWithValues: node.packageManagers.map { ($0.name, $0) })
        XCTAssertEqual(node.packageManagers.map(\.name), ["npm", "pnpm", "yarn", "bun"])
        XCTAssertEqual(pms["npm"]?.source, .bundled)
        XCTAssertEqual(pms["npm"]?.version, SemVer("10.9.0"), "the last line of --version")
        XCTAssertEqual(pms["npm"]?.latest, SemVer("11.6.0"))
        XCTAssertEqual(pms["pnpm"]?.source, .corepack)
        XCTAssertEqual(pms["yarn"]?.source, .npm)
        XCTAssertEqual(pms["yarn"]?.latest, SemVer("4.1.0"), "yarn 2+ is checked against @yarnpkg/cli-dist")
        XCTAssertEqual(pms["bun"]?.source, .homebrew)
        XCTAssertTrue(fx.web.requests.contains(registry("@yarnpkg/cli-dist")))

        // Health
        XCTAssertEqual(titles(node), [
            "Security update available: Node v22.12.0",
            "Other Node managers found: volta",
            "Other node binaries on PATH",
            "6 cached Node versions",
            "Package manager updates: npm 11.6.0, pnpm 10.0.0, bun 1.3.0",
        ])
        XCTAssertEqual(node.issues.first?.fix, .update)
        XCTAssertEqual(node.issues.first { $0.title.hasSuffix("cached Node versions") }?.fix, .prune)
        XCTAssertTrue(node.issues.first { $0.title == "Other node binaries on PATH" }?.detail.contains(" is shadowed by ") ?? false)
        XCTAssertTrue(node.debugSummary.contains("manager=n n=10.1.0"), node.debugSummary)
        XCTAssertNil(node.lastError)
    }

    func testReleasesAreFetchedAtMostHourly() async throws {
        try fx.makeN()
        try fx.setEnv(nPrefix: fx.nPrefix.path)
        let node = fx.service()
        await node.refresh()
        await node.refresh()
        await node.refresh(fetchReleases: false)
        XCTAssertEqual(fx.web.requests.filter { $0 == indexURL }.count, 1)
    }

    func testUnreachableReleaseServerIsReported() async throws {
        try fx.makeN()
        try fx.setEnv(nPrefix: fx.nPrefix.path)
        fx.web[indexURL] = nil
        fx.web[scheduleURL] = nil
        let node = fx.service()
        await node.refresh()
        XCTAssertEqual(node.lastError, "Couldn't reach nodejs.org to check for releases.")
        XCTAssertTrue(node.releases.isEmpty)
        XCTAssertNil(node.updateAvailable)
    }

    func testUpdatingSwitchingAndPruningWithN() async throws {
        try fx.makeN(versions: ["22.11.0", "20.18.0"])
        try fx.setEnv(nPrefix: fx.nPrefix.path)
        let node = fx.service()
        await node.refresh()
        let n = try XCTUnwrap(node.nBinary)

        let steps = node.switchCommand(to: SemVer("24.11.0")!, from: node.activeVersion)
        XCTAssertEqual(steps.map(\.title), ["n 24.11.0"])
        XCTAssertEqual(steps.first?.exe, n)
        XCTAssertEqual(node.uninstallCommand(SemVer("20.18.0")!)?.args, ["rm", "20.18.0"])

        await node.updateNode()
        XCTAssertEqual(node.activeVersion, SemVer("24.11.0"))
        XCTAssertNil(node.busy)
        XCTAssertNil(node.lastError)
        let logPath = try XCTUnwrap(node.lastActionLog)
        XCTAssertTrue(logPath.hasPrefix(SettingsStore.supportDirectory.path))
        XCTAssertTrue(try String(contentsOfFile: logPath, encoding: .utf8).contains("$ n 24.11.0"))

        await node.uninstall(SemVer("20.18.0")!)
        await node.prune()
        XCTAssertEqual(fx.log("n").filter { $0 != "--version" }, ["24.11.0", "rm 20.18.0", "prune"])
    }

    func testFailedActionsAreReportedWithTheirLog() async throws {
        try fx.makeN()
        try fx.setEnv(nPrefix: fx.nPrefix.path)
        try fx.write("n.status", "1")
        let node = fx.service()
        await node.refresh()
        await node.prune()
        XCTAssertEqual(node.lastError, "n prune failed — see the log.")
        XCTAssertNotNil(node.lastActionLog)
    }

    func testPackageManagerUpdateCommands() async throws {
        try fx.makeN()
        try fx.setEnv(nPrefix: fx.nPrefix.path)
        let node = fx.service()
        await node.refresh()
        let bin = fx.nPrefix.path + "/bin"
        let pms = Dictionary(uniqueKeysWithValues: node.packageManagers.map { ($0.name, $0) })

        XCTAssertEqual(node.updateCommand(for: pms["npm"]!)?.title, "npm install -g npm@latest")
        XCTAssertEqual(node.updateCommand(for: pms["pnpm"]!)?.exe, bin + "/corepack")
        XCTAssertEqual(node.updateCommand(for: pms["pnpm"]!)?.title, "corepack install -g pnpm@latest")
        XCTAssertEqual(node.updateCommand(for: pms["yarn"]!)?.title, "npm install -g @yarnpkg/cli-dist@latest")
        XCTAssertEqual(node.updateCommand(for: pms["bun"]!)?.title, "brew upgrade bun")
        var yarnCorepack = pms["yarn"]!
        yarnCorepack.source = .corepack
        XCTAssertEqual(node.updateCommand(for: yarnCorepack)?.title, "corepack install -g yarn@stable")
        var standaloneBun = pms["bun"]!
        standaloneBun.source = .standalone
        XCTAssertEqual(node.updateCommand(for: standaloneBun)?.title, "bun upgrade")
        let classicYarn = PackageManagerStatus(name: "yarn", path: "/x", version: SemVer("1.22.0"), source: .npm)
        XCTAssertEqual(node.updateCommand(for: classicYarn)?.title, "npm install -g yarn@latest")

        await node.updatePackageManager(pms["pnpm"]!)
        XCTAssertEqual(fx.log("corepack"), ["install -g pnpm@latest"])
        await node.updateAllPackageManagers()
        XCTAssertTrue(fx.log("npm").contains("install -g npm@latest"))
        XCTAssertEqual(fx.log("brew"), ["upgrade oven-sh/bun/bun"])
    }

    func testInstallingPackageManagers() async throws {
        try fx.makeN()
        try fx.setEnv(nPrefix: fx.nPrefix.path)
        SettingsStore.shared.settings.nodePackageManagers = ["npm"]
        let node = fx.service()
        await node.refresh()
        node.installPackageManager("yarn")
        XCTAssertEqual(SettingsStore.shared.settings.nodePackageManagers, ["npm", "yarn"])
        await assertEventually { self.fx.log("npm").contains("install -g yarn@latest") && node.busy == nil }
        node.installPackageManager("pnpm")
        await assertEventually { self.fx.log("npm").contains("install -g pnpm@latest") && node.busy == nil }

        node.installPackageManager("bun")
        XCTAssertEqual(fx.commands.last?.command, "brew install oven-sh/bun/bun")
        fx.brewInstalled = false
        let noBrew = fx.service()
        noBrew.installPackageManager("bun")
        XCTAssertEqual(fx.commands.last?.command, "curl -fsSL https://bun.sh/install | bash")
        XCTAssertEqual(fx.commands.last?.title, "Install bun")
        noBrew.installPackageManager("pnpm") // no Node yet: nothing to install with
    }

    func testNvmManagedToolchain() async throws {
        try fx.makeNvm()
        let shadow = fx.root.appendingPathComponent("elsewhere/node")
        try fx.setEnv(nvmDir: fx.nvmDir.path, node: [shadow.path])
        SettingsStore.shared.settings.nodeTrack = "current"
        let node = fx.service()
        await node.refresh()

        XCTAssertEqual(node.manager, .nvm)
        XCTAssertEqual(node.nvmVersion, "0.40.3")
        XCTAssertNil(node.nBinary)
        XCTAssertEqual(node.activeVersion, SemVer("24.10.0"))
        XCTAssertEqual(node.installed, [SemVer("24.10.0")!, SemVer("22.11.0")!])
        XCTAssertEqual(node.nodeBinDirectory, fx.nvmDir.path + "/versions/node/v24.10.0/bin")
        XCTAssertEqual(node.toolEnvironment["NVM_DIR"], fx.nvmDir.path)
        XCTAssertEqual(node.updateAvailable?.version, SemVer("25.2.0"))
        XCTAssertEqual(titles(node).first, "Another node comes first on PATH")
        XCTAssertTrue(titles(node).contains("Node v25.2.0 is available"))

        let steps = node.switchCommand(to: SemVer("25.2.0")!, from: SemVer("24.10.0"))
        XCTAssertEqual(steps.first?.title, "nvm install 25.2.0 --reinstall-packages-from=24.10.0 && nvm alias default 25.2.0")
        XCTAssertEqual(node.switchCommand(to: SemVer("24.10.0")!, from: SemVer("24.10.0")).first?.title,
                       "nvm install 24.10.0 && nvm alias default 24.10.0")
        XCTAssertEqual(node.uninstallCommand(SemVer("22.11.0")!)?.title, "nvm uninstall 22.11.0")

        try fx.write("nvm.default", "v25.2.0\n")
        await node.use(SemVer("25.2.0")!)
        XCTAssertEqual(node.activeVersion, SemVer("25.2.0"))
        XCTAssertTrue(fx.log("nvm").first?.contains("nvm install 25.2.0 --reinstall-packages-from=24.10.0") ?? false)
        await node.uninstall(SemVer("22.11.0")!)
        XCTAssertTrue(fx.log("nvm").last?.contains("nvm uninstall 22.11.0") ?? false)
        await node.prune() // n only
        XCTAssertEqual(fx.log("nvm").count, 2)

        await node.updateManager()
        XCTAssertEqual(fx.commands.last?.title, "Update nvm")
        XCTAssertTrue(fx.commands.last?.command.contains("/v0.40.9/install.sh") ?? false)
    }

    func testMajorTrackSwitchesAcrossMajorsAndPinnedNeverUpdates() async throws {
        try fx.makeNvm()
        try fx.setEnv(nvmDir: fx.nvmDir.path)
        SettingsStore.shared.settings.nodeTrack = "22"
        let node = fx.service()
        await node.refresh()
        XCTAssertEqual(node.updateAvailable?.version, SemVer("22.12.0"), "a major pin moves back to that line")
        SettingsStore.shared.settings.nodeTrack = "24"
        XCTAssertEqual(node.updateAvailable?.version, SemVer("24.11.0"))
        SettingsStore.shared.settings.nodeTrack = "pinned"
        XCTAssertNil(node.updateAvailable)
        XCTAssertNil(node.target(for: .pinned))
        await node.updateNode()
        XCTAssertTrue(fx.log("nvm").isEmpty)
    }

    func testNode25WithCorepackAndAShortLivedLine() async throws {
        try fx.makeNvm(active: "25.2.0", versions: ["25.2.0"])
        try fx.setEnv(nvmDir: fx.nvmDir.path)
        let node = fx.service()
        await node.refresh()
        XCTAssertTrue(titles(node).contains("Corepack isn't bundled with Node 25"), titles(node).joined(separator: "\n"))
        XCTAssertEqual(node.issues.first { $0.title.hasPrefix("Corepack") }?.fix, .installPackageManager("pnpm"))
        XCTAssertTrue(titles(node).contains("Node 25 support ends soon"))
        let pnpm = try XCTUnwrap(node.packageManagers.first { $0.name == "pnpm" })
        XCTAssertEqual(node.updateCommand(for: pnpm)?.title, "npm install -g pnpm@latest", "no corepack on Node 25")
    }

    func testBothManagersInstalled() async throws {
        try fx.makeN()
        try fx.makeNvm()
        try fx.setEnv(nPrefix: fx.nPrefix.path, nvmDir: fx.nvmDir.path)
        SettingsStore.shared.settings.nodeManager = .nvm
        let node = fx.service()
        await node.refresh()
        XCTAssertEqual(node.manager, .nvm, "the user's choice")
        XCTAssertTrue(titles(node).contains("Both n and nvm are installed"))
        SettingsStore.shared.settings.nodeManager = .n
        XCTAssertEqual(node.manager, .n)
    }

    func testNotInstalled() async throws {
        try fx.setEnv()
        let node = fx.service()
        await node.refresh()
        XCTAssertNil(node.manager)
        XCTAssertNil(node.activeVersion)
        XCTAssertNil(node.nodeBinDirectory)
        XCTAssertEqual(titles(node), ["Node.js isn't installed"])
        XCTAssertTrue(node.switchCommand(to: SemVer("24.0.0")!, from: nil).isEmpty)
        XCTAssertNil(node.uninstallCommand(SemVer("24.0.0")!))
        XCTAssertNil(node.updateCommand(for: PackageManagerStatus(name: "npm")))
        await node.updateManager()
        XCTAssertTrue(fx.commands.isEmpty)
        _ = NodeService.managerLikelyInstalled
    }

    func testUnmanagedEndOfLifeNode() async throws {
        let bin = fx.root.appendingPathComponent("system/bin")
        try fx.exe(bin.appendingPathComponent("node"), "echo v20.19.0")
        try fx.setEnv(node: [bin.appendingPathComponent("node").path])
        let node = fx.service()
        await node.refresh()
        XCTAssertNil(node.manager)
        XCTAssertEqual(node.activeVersion, SemVer("20.19.0"))
        XCTAssertEqual(node.nodeBinDirectory, bin.path)
        XCTAssertEqual(titles(node).first, "Node 20 is end-of-life")
        XCTAssertTrue(titles(node).contains("Node isn't managed by a version manager"))
    }

    func testNWithoutPrefixAndUnwritableGlobals() async throws {
        let usrlocal = fx.root.appendingPathComponent("usrlocal")
        try fx.exe(fx.path.appendingPathComponent("n"), "echo 10.0.0")
        try fx.exe(usrlocal.appendingPathComponent("bin/node"), "echo v24.11.0")
        let globals = usrlocal.appendingPathComponent("lib/node_modules")
        try FileManager.default.createDirectory(at: globals, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: globals.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: globals.path) }
        try fx.setEnv()
        let node = fx.service()
        await node.refresh()
        XCTAssertEqual(node.manager, .n)
        XCTAssertNil(node.nPrefix)
        XCTAssertEqual(node.activeVersion, SemVer("24.11.0"))
        XCTAssertTrue(titles(node).contains("Global npm packages need sudo"))
        XCTAssertEqual(titles(node).contains("n needs sudo without N_PREFIX"),
                       !FileManager.default.isWritableFile(atPath: "/usr/local/bin"))
    }

    func testInstallingAndUpdatingTheManager() async throws {
        let node = fx.service()
        node.installN()
        XCTAssertEqual(fx.commands.last?.title, "Install n")
        XCTAssertTrue(fx.commands.last?.command.hasPrefix("brew install n") ?? false)
        XCTAssertTrue(try String(contentsOf: fx.zshrc, encoding: .utf8).contains(#"export N_PREFIX="$HOME/.n""#))
        XCTAssertEqual(node.nPrefix, fx.home.path + "/.n")

        fx.brewInstalled = false
        fx.service().installN()
        XCTAssertTrue(fx.commands.last?.command.hasPrefix("curl -fsSL https://raw.githubusercontent.com/tj/n/") ?? false)

        await node.installNvm()
        XCTAssertEqual(fx.commands.last?.title, "Install nvm")
        XCTAssertTrue(fx.commands.last?.command.contains("/v0.40.9/install.sh") ?? false)
        fx.web[nvmReleaseURL] = nil
        await node.installNvm()
        XCTAssertTrue(fx.commands.last?.command.contains("/v0.40.3/install.sh") ?? false, "falls back to a known release")
    }

    func testUpdatingN() async throws {
        try fx.makeN(fromHomebrew: true)
        try fx.setEnv(nPrefix: fx.nPrefix.path)
        let brewN = fx.service()
        await brewN.refresh()
        XCTAssertTrue(brewN.nFromHomebrew)
        await brewN.updateManager()
        XCTAssertEqual(fx.commands.last?.command, "brew upgrade n")

        try FileManager.default.removeItem(at: fx.path.appendingPathComponent("n"))
        try fx.exe(fx.path.appendingPathComponent("n"), "echo 10.1.0")
        let npmN = fx.service()
        await npmN.refresh()
        XCTAssertFalse(npmN.nFromHomebrew)
        await npmN.updateManager()
        XCTAssertTrue(fx.log("npm").contains("install -g n@latest"))
    }

    func testNPrefixIsAddedToTheZshrcOnceWithABackup() throws {
        let node = fx.service()
        try "export PATH=/usr/bin".write(to: fx.zshrc, atomically: true, encoding: .utf8)
        node.ensureNPrefixInZshrc()
        let rc = try String(contentsOf: fx.zshrc, encoding: .utf8)
        XCTAssertEqual(rc, "export PATH=/usr/bin\n\n" + NodeService.nPrefixSnippet + "\n")
        XCTAssertEqual(try String(contentsOf: fx.home.appendingPathComponent(".zshrc.shell-backup"), encoding: .utf8), "export PATH=/usr/bin")
        node.ensureNPrefixInZshrc()
        XCTAssertEqual(try String(contentsOf: fx.zshrc, encoding: .utf8), rc, "already there")
        XCTAssertEqual(NodeService.nInstallViaBrew, "brew install n")
    }
}

// MARK: - Background job

@MainActor
final class NodeMaintenanceJobTests: XCTestCase {
    private var fx: NodeFixture!
    private var original: AppSettings!

    override func setUp() async throws {
        fx = try NodeFixture(root: try makeTemporaryDirectory())
        original = SettingsStore.shared.settings
        SettingsStore.shared.settings.nodeTrack = "lts"
        SettingsStore.shared.settings.nodeManager = .n
        SettingsStore.shared.settings.nodePackageManagers = ["npm", "pnpm", "yarn", "bun"]
        SettingsStore.shared.settings.nodePruneOldVersions = true
    }

    override func tearDown() async throws {
        SettingsStore.shared.settings = original
    }

    private func perform(_ job: NodeMaintenanceJob) async -> (MaintenanceOutcome, String) {
        let run = MaintenanceRun(jobID: "node-test")
        let out = await job.perform(run)
        run.close()
        return (out, (try? String(contentsOf: run.logURL, encoding: .utf8)) ?? "")
    }

    func testUpdatesNodePackageManagersAndRunsDoctorWithN() async throws {
        try fx.makeN()
        try fx.setEnv(nPrefix: fx.nPrefix.path)
        try fx.write("brew.status", "1") // bun's brew upgrade fails: reported, not fatal
        let job = NodeMaintenanceJob(node: fx.service())
        XCTAssertEqual(job.id, "node")
        XCTAssertFalse(job.summary.isEmpty)
        let (out, log) = await perform(job)
        XCTAssertNil(out.failedStep)
        XCTAssertEqual(out.changes.first, "node v22.11.0 → v24.11.0")
        XCTAssertTrue(out.changes.contains("npm 10.9.0 → 11.6.0"))
        XCTAssertTrue(out.changes.contains("pnpm 9.0.0 → 10.0.0"))
        XCTAssertTrue(out.warnings.contains("Couldn't update bun (brew upgrade bun)"), out.warnings.joined(separator: "\n"))
        XCTAssertTrue(out.warnings.contains("npm doctor: registry: unreachable"))
        XCTAssertTrue(log.contains("manager: n · active: v22.11.0 · track: lts"), log)
        XCTAssertTrue(fx.log("n").contains("prune"))
        XCTAssertTrue(job.isAvailable)
        await job.didFinish()
    }

    func testNvmPrunesThePreviousVersionAndWarnsAboutOpenTabs() async throws {
        try fx.makeNvm()
        try fx.setEnv(nvmDir: fx.nvmDir.path)
        try fx.write("nvm.default", "v24.10.0\n")
        let job = NodeMaintenanceJob(node: fx.service())
        let (out, _) = await perform(job)
        XCTAssertNil(out.failedStep)
        XCTAssertEqual(out.changes.first, "node v24.10.0 → v24.11.0")
        XCTAssertTrue(out.warnings.contains("Open tabs keep the previous Node until restarted; new tabs use v24.11.0."))
        XCTAssertTrue(fx.log("nvm").contains { $0.contains("nvm uninstall 24.10.0") }, fx.log("nvm").joined(separator: "\n"))
    }

    func testFailures() async throws {
        try fx.setEnv()
        var (out, _) = await perform(NodeMaintenanceJob(node: fx.service()))
        XCTAssertEqual(out.failedStep, "find n or nvm")

        try fx.makeN()
        try fx.setEnv(nPrefix: fx.nPrefix.path)
        fx.web[indexURL] = nil
        var log: String
        (out, log) = await perform(NodeMaintenanceJob(node: fx.service()))
        XCTAssertEqual(out.failedStep, "fetch Node.js releases")
        XCTAssertTrue(log.contains("Couldn't reach nodejs.org"))

        fx.setReleases()
        try fx.write("n.status", "1")
        (out, _) = await perform(NodeMaintenanceJob(node: fx.service()))
        XCTAssertEqual(out.failedStep, "n 24.11.0")
    }

    func testPinnedTrackLeavesNodeAlone() async throws {
        try fx.makeN()
        try fx.setEnv(nPrefix: fx.nPrefix.path)
        SettingsStore.shared.settings.nodeTrack = "pinned"
        SettingsStore.shared.settings.nodePackageManagers = []
        let (out, _) = await perform(NodeMaintenanceJob(node: fx.service()))
        XCTAssertNil(out.failedStep)
        XCTAssertTrue(out.changes.isEmpty)
        XCTAssertEqual(fx.log("n").filter { $0 != "--version" }, [])
    }

    func testNotifications() {
        let job = NodeMaintenanceJob(node: fx.service())
        func record(_ outcome: MaintenanceRecord.Outcome, changes: [String] = [], warnings: [String] = [], failedStep: String? = nil) -> MaintenanceRecord {
            MaintenanceRecord(startedAt: Date(), finishedAt: Date(), outcome: outcome, failedStep: failedStep,
                              changes: changes, warnings: warnings, logPath: "")
        }
        XCTAssertEqual(job.notification(for: record(.success, changes: ["node a → b"]))?.body, "node a → b")
        XCTAssertEqual(job.notification(for: record(.success, changes: ["x", "y"], warnings: ["w"]))?.body, "x, y · 1 issue to review")
        XCTAssertEqual(job.notification(for: record(.success, changes: ["x"], warnings: ["w", "v"]))?.body, "x · 2 issues to review")
        XCTAssertEqual(job.notification(for: record(.success, changes: ["x"]))?.title, "Node.js toolchain updated")
        XCTAssertNil(job.notification(for: record(.success)))
        XCTAssertNil(job.notification(for: record(.cancelled)))
        XCTAssertEqual(job.notification(for: record(.failed, failedStep: "n 24"))?.title, "Node.js auto-update failed")
        XCTAssertTrue(job.notification(for: record(.failed))?.body.hasPrefix("update didn't finish") ?? false)
        withSettings({ $0.nodeAutoUpdate = .monthly }) { XCTAssertEqual(job.schedule, .monthly) }
    }
}

// MARK: - Pane

@MainActor
final class NodePaneTests: XCTestCase {
    private var fx: NodeFixture!
    private var original: AppSettings!

    override func setUp() async throws {
        fx = try NodeFixture(root: try makeTemporaryDirectory())
        original = SettingsStore.shared.settings
        SettingsStore.shared.settings.nodeTrack = "lts"
        SettingsStore.shared.settings.nodeManager = .n
        SettingsStore.shared.settings.nodePackageManagers = ["npm", "pnpm"]
    }

    override func tearDown() async throws {
        SettingsStore.shared.settings = original
    }

    func testNotInstalled() async throws {
        try fx.setEnv()
        let node = fx.service()
        await node.refresh()
        render(NodePane(node: node))
        XCTAssertTrue(fx.commands.isEmpty, "rendering never runs installers")
    }

    func testNWithUpdatesIssuesAndPackageManagers() async throws {
        try fx.makeN(versions: ["22.11.0", "20.18.0", "18.0.0", "16.0.0", "14.0.0", "12.0.0"])
        try fx.setEnv(nPrefix: fx.nPrefix.path, node: [fx.nPrefix.path + "/bin/node", "/somewhere/node"])
        let node = fx.service()
        await node.refresh()
        render(NodePane(node: node))
        render(NodePane(node: node, installMajor: 24))
    }

    func testBusyAndError() async throws {
        try fx.makeN()
        try fx.setEnv(nPrefix: fx.nPrefix.path)
        let node = fx.service()
        await node.refresh()
        try fx.write("n.sleep", "")
        let task = Task { await node.prune() }
        await assertEventually { node.busy != nil }
        render(NodePane(node: node))
        await task.value

        try fx.write("n.status", "2")
        try FileManager.default.removeItem(at: fx.root.appendingPathComponent("n.sleep"))
        await node.prune()
        XCTAssertNotNil(node.lastError)
        render(NodePane(node: node))
    }

    func testNvmAndBothManagers() async throws {
        try fx.makeNvm(active: "20.19.0", versions: ["20.19.0", "24.10.0"])
        try fx.setEnv(nvmDir: fx.nvmDir.path)
        let nvm = fx.service()
        await nvm.refresh()
        render(NodePane(node: nvm))

        try fx.makeN()
        try fx.setEnv(nPrefix: fx.nPrefix.path, nvmDir: fx.nvmDir.path)
        let both = fx.service()
        await both.refresh()
        render(NodePane(node: both))
    }

    func testPackageManagerRowsWithoutInstalls() async throws {
        let bin = fx.root.appendingPathComponent("system/bin")
        try fx.exe(bin.appendingPathComponent("node"), "echo v24.11.0")
        try fx.setEnv(node: [bin.appendingPathComponent("node").path])
        let node = fx.service()
        await node.refresh()
        XCTAssertTrue(node.packageManagers.allSatisfy { !$0.isInstalled })
        render(NodePane(node: node))
        render(Badge(text: "LTS", color: .green))
    }
}
