import SwiftUI
import XCTest
@testable import Shell

/// Sizes reported for cache folders; paths without an override are measured with du.
/// Lock-protected: read from the measuring task group, written by the test.
private final class Sizes: @unchecked Sendable {
    private let lock = NSLock()
    private var overrides: [String: Int64] = [:]
    subscript(path: String) -> Int64? {
        get { lock.withLock { overrides[path] } }
        set { lock.withLock { overrides[path] = newValue } }
    }
    func size(_ path: String) async -> Int64? {
        if let o = self[path] { return o }
        return await WorktreeService.size(of: path)
    }
}

/// A fake Go toolchain in a temp home: `go env -json` points GOCACHE and
/// GOMODCACHE into the home, `go clean -cache|-modcache|-fuzzcache` empties
/// the matching folder, and `clean.fail` makes `go clean` fail.
@MainActor
private final class GoFixture {
    let home: URL
    let bin: URL
    let sizes = Sizes()
    var notifications: [(title: String, body: String)] = []
    let defaults: UserDefaults
    private let suite = "ShellTestFixture.go.\(UUID().uuidString)"

    var gocache: URL { home.appendingPathComponent("gocache") }
    var modcache: URL { home.appendingPathComponent("go/pkg/mod") }
    var caches: URL { home.appendingPathComponent("Library/Caches") }

    init(home: URL) throws {
        self.home = home
        bin = home.appendingPathComponent("bin")
        defaults = UserDefaults(suiteName: suite)!
        let fm = FileManager.default
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createDirectory(at: gocache.appendingPathComponent("fuzz"), withIntermediateDirectories: true)
        try fm.createDirectory(at: modcache, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64 * 1024).write(to: gocache.appendingPathComponent("a.bin"))
        try Data(repeating: 1, count: 32 * 1024).write(to: modcache.appendingPathComponent("m.zip"))
        try script("go", #"""
        dir=$(dirname "$0")
        echo "$*" >> "$dir/go.log"
        case "$1" in
          env) printf '{"GOCACHE": "\#(gocache.path)", "GOPATH": "\#(home.path)/go", "GOROOT": "/usr/local/go", "GOVERSION": "go1.25.1"}\n' ;;
          clean)
            if [ -f "$dir/clean.fail" ]; then echo "go: permission denied" >&2; exit 1; fi
            case "$2" in
              -cache) rm -rf "\#(gocache.path)"/* ;;
              -modcache) rm -rf "\#(modcache.path)"/* ;;
              -fuzzcache) rm -rf "\#(gocache.path)/fuzz"/* ;;
            esac ;;
        esac
        """#)
    }

    func removeDefaults() { UserDefaults.standard.removePersistentDomain(forName: suite) }

    @discardableResult
    func script(_ name: String, _ body: String) throws -> String {
        try writeExecutable("#!/bin/sh\n" + body + "\n", to: bin.appendingPathComponent(name))
    }

    var goLog: [String] {
        ((try? String(contentsOf: bin.appendingPathComponent("go.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func service(installed: Bool = true) -> GoService {
        let bin = bin.path
        let sizes = sizes
        return GoService(environment: ["PATH": "\(bin):/usr/bin:/bin"], home: home.path,
                         findExecutable: { name, _ in
                             guard installed else { return nil }
                             let p = "\(bin)/\(name)"
                             return FileManager.default.isExecutableFile(atPath: p) ? p : nil
                         },
                         size: { await sizes.size($0) },
                         defaults: defaults,
                         notify: { [weak self] in self?.notifications.append(($0, $1)) })
    }
}

@MainActor
final class GoServiceTests: XCTestCase {
    private var fx: GoFixture!
    private var original: AppSettings!

    override func setUp() async throws {
        fx = try GoFixture(home: try makeTemporaryDirectory())
        original = SettingsStore.shared.settings
        SettingsStore.shared.settings.goCacheWarning = true
        SettingsStore.shared.settings.goCacheWarningGB = 5
        SettingsStore.shared.settings.goAutoCleanBuildCache = false
    }

    override func tearDown() async throws {
        SettingsStore.shared.settings = original
        fx.removeDefaults()
    }

    func testNotInstalled() async {
        let go = fx.service(installed: false)
        await go.refresh()
        XCTAssertFalse(go.isInstalled)
        XCTAssertTrue(go.caches.isEmpty)
        await go.clearTestResults()
        await go.clear(.build)
        XCTAssertNil(go.message)
    }

    func testRefreshReadsGoEnvAndMeasuresTheCachesThatExist() async throws {
        let gopls = fx.caches.appendingPathComponent("gopls")
        try FileManager.default.createDirectory(at: gopls, withIntermediateDirectories: true)
        let go = fx.service()
        await go.refresh()
        XCTAssertTrue(go.isInstalled)
        XCTAssertEqual(go.version, "go1.25.1")
        XCTAssertEqual(go.env["GOROOT"], "/usr/local/go")
        XCTAssertEqual(go.caches.map(\.id), [.build, .modules, .fuzz, .gopls])
        XCTAssertEqual(go.caches.first { $0.id == .modules }?.path, fx.modcache.path, "derived from GOPATH")
        XCTAssertEqual(go.caches.first { $0.id == .fuzz }?.path, fx.gocache.path + "/fuzz")
        XCTAssertNotNil(go.lastMeasured)
        XCTAssertFalse(go.isMeasuring)
        let build = try XCTUnwrap(go.caches.first { $0.id == .build }?.bytes)
        XCTAssertGreaterThanOrEqual(build, 64 * 1024)
        XCTAssertEqual(go.buildCacheBytes, build)
        let all = go.caches.filter { $0.id != .fuzz }.compactMap(\.bytes).reduce(0, +)
        XCTAssertEqual(go.total, all, "the fuzz corpus lives inside the build cache")
        XCTAssertEqual(go.limitBytes, 5_000_000_000)
        XCTAssertFalse(go.isOverLimit)
        XCTAssertFalse(go.isBuildCacheOverLimit)
        XCTAssertEqual(fx.goLog.first, "env -json GOCACHE GOMODCACHE GOPATH GOROOT GOVERSION")
    }

    func testClearingWithGoClean() async throws {
        let go = fx.service()
        await go.refresh()
        await go.clear(.build)
        XCTAssertTrue(go.message?.hasPrefix("Build & test cache: freed ") ?? false, go.message ?? "nil")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.gocache.appendingPathComponent("a.bin").path))
        await go.clear(.modules)
        XCTAssertTrue(go.message?.hasPrefix("Module cache: freed ") ?? false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.modcache.appendingPathComponent("m.zip").path))
        XCTAssertTrue(go.busy.isEmpty)
        XCTAssertTrue(fx.goLog.contains("clean -cache"))
        XCTAssertTrue(fx.goLog.contains("clean -modcache"))
    }

    func testFuzzAndTestCacheAndFailures() async throws {
        try FileManager.default.createDirectory(at: fx.gocache.appendingPathComponent("fuzz/corpus"), withIntermediateDirectories: true)
        let go = fx.service()
        await go.refresh()
        await go.clear(.fuzz)
        XCTAssertTrue(fx.goLog.contains("clean -fuzzcache"))
        await go.clearTestResults()
        XCTAssertEqual(go.message, "Cached test results cleared — the next go test runs every test.")
        XCTAssertTrue(fx.goLog.contains("clean -testcache"))

        FileManager.default.createFile(atPath: fx.bin.appendingPathComponent("clean.fail").path, contents: Data())
        await go.clear(.build)
        XCTAssertEqual(go.message, "Build & test cache: go: permission denied")
        await go.clearTestResults()
        XCTAssertEqual(go.message, "go: permission denied")
    }

    func testClearingToolCachesByRemovingTheirContents() async throws {
        let fm = FileManager.default
        for name in ["gopls", "goimports", "golangci-lint"] {
            let dir = fx.caches.appendingPathComponent(name)
            try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try Data(repeating: 2, count: 4096).write(to: dir.appendingPathComponent("sub/index"))
        }
        let go = fx.service()
        await go.refresh()
        XCTAssertEqual(go.caches.map(\.id), [.build, .modules, .fuzz, .gopls, .golangci, .goimports])
        await go.clear(.gopls)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: fx.caches.appendingPathComponent("gopls").path), [])
        XCTAssertTrue(go.message?.hasPrefix("gopls: freed") ?? false)
        await go.clear(.golangci) // no golangci-lint binary: remove the folder's contents
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: fx.caches.appendingPathComponent("golangci-lint").path), [])

        // An item that can't be deleted is reported.
        let locked = fx.caches.appendingPathComponent("goimports/sub")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        addTeardownBlock { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        await go.clear(.goimports)
        XCTAssertEqual(go.message, "goimports: 1 item couldn't be removed")

        // A folder that vanished is fine.
        try fm.removeItem(at: fx.caches.appendingPathComponent("gopls"))
        await go.clear(.gopls)
        XCTAssertTrue(go.message?.hasPrefix("gopls: freed") ?? false)
    }

    func testGolangciLintCleansItsOwnCache() async throws {
        try FileManager.default.createDirectory(at: fx.caches.appendingPathComponent("golangci-lint"), withIntermediateDirectories: true)
        let log = fx.bin.appendingPathComponent("lint.log").path
        try fx.script("golangci-lint", "echo \"$*\" >> \"\(log)\"")
        let go = fx.service()
        await go.refresh()
        await go.clear(.golangci)
        XCTAssertEqual(try String(contentsOfFile: log, encoding: .utf8), "cache clean\n")
        XCTAssertTrue(go.message?.hasPrefix("golangci-lint: freed") ?? false)
        await go.clear(.goimports) // not present: nothing happens
    }

    func testWarnsOnceADayWhenTheBuildCacheIsOverTheLimit() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.isLowPowerModeEnabled, "Low Power Mode skips the check")
        fx.sizes[fx.gocache.path] = 6_000_000_000
        let go = fx.service()
        await go.check()
        XCTAssertTrue(go.isBuildCacheOverLimit)
        XCTAssertTrue(go.isOverLimit)
        XCTAssertEqual(fx.notifications.count, 1)
        XCTAssertTrue(fx.notifications.first?.title.hasPrefix("Go's build cache is ") ?? false, fx.notifications.first?.title ?? "")
        XCTAssertTrue(fx.notifications.first?.body.contains("go clean -cache") ?? false)
        XCTAssertNotNil(fx.defaults.object(forKey: "GoBuildCacheWarningLastShown"))
        await go.check()
        XCTAssertEqual(fx.notifications.count, 1, "at most once a day")
    }

    func testWarnsWhenAllCachesTogetherAreOverTheLimit() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.isLowPowerModeEnabled, "Low Power Mode skips the check")
        fx.sizes[fx.gocache.path] = 3_000_000_000
        fx.sizes[fx.modcache.path] = 3_000_000_000
        let go = fx.service()
        await go.check()
        XCTAssertFalse(go.isBuildCacheOverLimit)
        XCTAssertTrue(go.isOverLimit)
        XCTAssertEqual(fx.notifications.map(\.title).first?.hasPrefix("Go's caches are "), true)
        XCTAssertNotNil(fx.defaults.object(forKey: "GoCacheWarningLastShown"))
    }

    func testAutoCleanClearsTheBuildCacheInsteadOfWarning() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.isLowPowerModeEnabled, "Low Power Mode skips the check")
        SettingsStore.shared.settings.goAutoCleanBuildCache = true
        fx.sizes[fx.gocache.path] = 6_000_000_000
        let go = fx.service()
        await go.check()
        XCTAssertTrue(fx.goLog.contains("clean -cache"))
        XCTAssertEqual(fx.notifications.first?.title, "Go's build cache passed 5 GB")
        XCTAssertTrue(fx.notifications.first?.body.hasPrefix("It was ") ?? false)
    }

    func testNoWarningWhenUnderTheLimitOrDisabled() async {
        let go = fx.service()
        await go.check()
        XCTAssertTrue(fx.notifications.isEmpty)
        SettingsStore.shared.settings.goCacheWarning = false
        fx.sizes[fx.gocache.path] = 60_000_000_000
        let other = fx.service()
        await other.check()
        XCTAssertNil(other.lastMeasured, "disabled: doesn't even measure")
        XCTAssertTrue(fx.notifications.isEmpty)
        other.startMonitoring()
        other.startMonitoring() // restarting replaces the timer
    }
}

// MARK: - Pane

@MainActor
final class GoSettingsPaneTests: XCTestCase {
    private var fx: GoFixture!
    private var original: AppSettings!

    override func setUp() async throws {
        fx = try GoFixture(home: try makeTemporaryDirectory())
        original = SettingsStore.shared.settings
        SettingsStore.shared.settings.goCacheWarningGB = 5
    }

    override func tearDown() async throws {
        SettingsStore.shared.settings = original
        fx.removeDefaults()
    }

    func testNotInstalledAndMeasuring() {
        render(GoSettingsPane(go: fx.service(installed: false)))
        render(GoSettingsPane(go: fx.service())) // not measured yet
    }

    func testUnderTheLimitWithAMessage() async throws {
        try FileManager.default.createDirectory(at: fx.caches.appendingPathComponent("golangci-lint"), withIntermediateDirectories: true)
        let go = fx.service()
        await go.refresh()
        go.message = "gopls: freed 12 MB"
        render(GoSettingsPane(go: go))
        SettingsStore.shared.settings.goCacheWarning = false
        render(GoSettingsPane(go: go))
    }

    func testBuildCacheOverTheLimit() async {
        fx.sizes[fx.gocache.path] = 6_000_000_000
        let go = fx.service()
        await go.refresh()
        XCTAssertTrue(go.isBuildCacheOverLimit)
        render(GoSettingsPane(go: go))
    }

    func testAllCachesOverTheLimit() async {
        fx.sizes[fx.gocache.path] = 3_000_000_000
        fx.sizes[fx.modcache.path] = 3_000_000_000
        let go = fx.service()
        await go.refresh()
        XCTAssertTrue(go.isOverLimit)
        XCTAssertFalse(go.isBuildCacheOverLimit)
        render(GoSettingsPane(go: go))
    }

    func testConfirmationTextNamesTheCommand() {
        func cache(_ id: GoService.Cache.ID) -> GoService.Cache {
            GoService.Cache(id: id, title: "t", detail: "d", path: NSHomeDirectory() + "/Library/Caches/x")
        }
        XCTAssertEqual(GoSettingsPane.command(for: cache(.build)), "Runs `go clean -cache`.")
        XCTAssertEqual(GoSettingsPane.command(for: cache(.modules)), "Runs `go clean -modcache`.")
        XCTAssertEqual(GoSettingsPane.command(for: cache(.fuzz)), "Runs `go clean -fuzzcache`.")
        XCTAssertEqual(GoSettingsPane.command(for: cache(.golangci)), "Runs `golangci-lint cache clean`.")
        XCTAssertEqual(GoSettingsPane.command(for: cache(.gopls)), "Removes the contents of ~/Library/Caches/x.")
        XCTAssertEqual(GoSettingsPane.command(for: cache(.goimports)), "Removes the contents of ~/Library/Caches/x.")
    }
}
