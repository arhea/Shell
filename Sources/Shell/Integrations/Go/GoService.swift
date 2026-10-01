import AppKit
import Observation

/// Go's caches, measured and cleared with Go's own commands where it has them.
@MainActor
@Observable
final class GoService {
    static let shared = GoService()

    struct Cache: Identifiable {
        enum ID: String { case build, modules, fuzz, gopls, golangci, goimports }
        var id: ID
        var title: String
        var detail: String
        var path: String
        var bytes: Int64?
        /// Shown before clearing (e.g. "modules are downloaded again").
        var caution: String?
    }

    private(set) var goPath: String?
    private(set) var version: String?
    private(set) var env: [String: String] = [:]
    private(set) var caches: [Cache] = []
    private(set) var isMeasuring = false
    private(set) var lastMeasured: Date?
    private(set) var busy: Set<Cache.ID> = []
    var message: String?

    @ObservationIgnored private var monitor: Timer?
    // Injectable for unit tests; the defaults are the user's real toolchain.
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private let home: String
    @ObservationIgnored private let findExecutable: (_ name: String, _ environment: [String: String]) -> String?
    @ObservationIgnored private let size: @Sendable (_ path: String) async -> Int64?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let notify: @MainActor (_ title: String, _ body: String) -> Void

    init(environment: [String: String] = MCPManager.defaultEnvironment(),
         home: String = NSHomeDirectory(),
         findExecutable: @escaping (_ name: String, _ environment: [String: String]) -> String? = GitRepository.findExecutable,
         size: @escaping @Sendable (_ path: String) async -> Int64? = { await WorktreeService.size(of: $0) },
         // Unit tests share the app's bundle ID; keep their writes out of the real preferences.
         defaults: UserDefaults = AppEnvironment.isRunningTests
             ? UserDefaults(suiteName: "app.bethesdalabs.Shell.tests") ?? .standard : .standard,
         notify: @escaping @MainActor (_ title: String, _ body: String) -> Void = {
             NotificationManager.shared.postAppNotification(title: $0, body: $1, pane: .go)
         }) {
        self.environment = environment
        self.home = home
        self.findExecutable = findExecutable
        self.size = size
        self.defaults = defaults
        self.notify = notify
    }

    var isInstalled: Bool { goPath != nil }
    /// All Go caches (the fuzz corpus lives inside the build cache, so it isn't added twice).
    var total: Int64 { caches.filter { $0.id != .fuzz }.compactMap(\.bytes).reduce(0, +) }
    var limitBytes: Int64 { Int64(max(1, SettingsStore.shared.settings.goCacheWarningGB)) * 1_000_000_000 }
    var isOverLimit: Bool { lastMeasured != nil && total > limitBytes }
    var buildCacheBytes: Int64 { caches.first { $0.id == .build }?.bytes ?? 0 }
    /// The build cache on its own is over the same limit.
    var isBuildCacheOverLimit: Bool { lastMeasured != nil && buildCacheBytes > limitBytes }

    // MARK: Discovery

    func refresh() async {
        goPath = findExecutable("go", environment)
        guard let go = goPath else {
            caches = []
            return
        }
        if let out = await GitRepository.run(go, ["env", "-json", "GOCACHE", "GOMODCACHE", "GOPATH", "GOROOT", "GOVERSION"], in: home, environment: environment),
           let data = out.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            env = obj
            version = obj["GOVERSION"]
        }
        let cacheDir = home + "/Library/Caches"
        let gocache = env["GOCACHE"] ?? cacheDir + "/go-build"
        caches = [
            Cache(id: .build, title: "Build & test cache", detail: "GOCACHE — compiled packages and cached test results. Go trims entries unused for 5 days, but active projects keep it large.",
                  path: gocache, caution: "The next builds and test runs recompile from scratch."),
            Cache(id: .modules, title: "Module cache", detail: "GOMODCACHE — downloaded module sources for every project.",
                  path: env["GOMODCACHE"] ?? (env["GOPATH"] ?? home + "/go") + "/pkg/mod",
                  caution: "Modules are downloaded again on the next build; offline builds fail until then."),
            Cache(id: .fuzz, title: "Fuzz corpus", detail: "Generated fuzzing inputs (go test -fuzz).",
                  path: gocache + "/fuzz", caution: "Fuzzing starts over from its seed corpus."),
            Cache(id: .gopls, title: "gopls", detail: "The Go language server's index for your editors.",
                  path: cacheDir + "/gopls", caution: "Restart your editor's Go language server afterwards."),
            Cache(id: .golangci, title: "golangci-lint", detail: "Lint results cache.", path: cacheDir + "/golangci-lint"),
            Cache(id: .goimports, title: "goimports", detail: "goimports' package index.", path: cacheDir + "/goimports"),
        ].filter { $0.id == .build || $0.id == .modules || FileManager.default.fileExists(atPath: $0.path) }
        await measure()
    }

    func measure() async {
        guard !isMeasuring else { return }
        isMeasuring = true
        defer { isMeasuring = false }
        let size = size
        await withTaskGroup(of: (Int, Int64?).self) { group in
            for (i, c) in caches.enumerated() {
                let path = c.path
                group.addTask { (i, FileManager.default.fileExists(atPath: path) ? await size(path) : 0) }
            }
            for await (i, bytes) in group where caches.indices.contains(i) { caches[i].bytes = bytes }
        }
        lastMeasured = Date()
    }

    // MARK: Clearing

    /// Clears a cache with `go clean` (build, modules, fuzz), the tool's own
    /// command (golangci-lint) or by removing the folder.
    func clear(_ id: Cache.ID) async {
        guard let cache = caches.first(where: { $0.id == id }) else { return }
        busy.insert(id)
        defer { busy.remove(id) }
        let before = cache.bytes ?? 0
        var err: String?
        switch id {
        case .build, .modules, .fuzz:
            guard let go = goPath else { return }
            let flag = id == .build ? "-cache" : id == .modules ? "-modcache" : "-fuzzcache"
            err = await WorktreeService.runReportingError(go, ["clean", flag], in: home, environment: environment)
        case .golangci:
            if let lint = findExecutable("golangci-lint", environment) {
                err = await WorktreeService.runReportingError(lint, ["cache", "clean"], in: home, environment: environment)
            } else {
                err = removeContents(cache.path)
            }
        case .gopls, .goimports:
            err = removeContents(cache.path)
        }
        await measure()
        let after = caches.first { $0.id == id }?.bytes ?? 0
        message = err.map { "\(cache.title): \($0)" } ?? "\(cache.title): freed \(WorktreeService.formatBytes(max(0, before - after)))"
    }

    /// Only clears the cached test results (`go clean -testcache`).
    func clearTestResults() async {
        guard let go = goPath else { return }
        busy.insert(.build)
        defer { busy.remove(.build) }
        let err = await WorktreeService.runReportingError(go, ["clean", "-testcache"], in: home, environment: environment)
        message = err ?? "Cached test results cleared — the next go test runs every test."
        await measure()
    }

    private func removeContents(_ path: String) -> String? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: path) else { return nil }
        var failed = 0
        for item in items {
            if (try? fm.removeItem(atPath: path + "/" + item)) == nil { failed += 1 }
        }
        return failed == 0 ? nil : "\(failed) item\(failed == 1 ? "" : "s") couldn't be removed"
    }

    // MARK: Size monitor

    /// Checks sizes after launch and every 6 hours; warns (at most daily) when
    /// Go's caches pass the limit, optionally clearing the build cache.
    func startMonitoring() {
        monitor?.invalidate()
        monitor = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            _ = MainActor.assumeIsolated { Task { await self?.check() } }
        }
        monitor?.tolerance = 600
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            _ = MainActor.assumeIsolated { Task { await self?.check() } }
        }
    }

    func check() async {
        let s = SettingsStore.shared.settings
        guard s.goCacheWarning, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        await refresh()
        guard isInstalled, isOverLimit || isBuildCacheOverLimit else { return }
        // The build cache gets its own, more specific warning.
        let buildOver = isBuildCacheOverLimit
        let size = WorktreeService.formatBytes(buildOver ? buildCacheBytes : total)
        let subject = buildOver ? "Go's build cache" : "Go's caches"
        if s.goAutoCleanBuildCache && buildCacheBytes > 0 {
            await clear(.build)
            notify("\(subject) passed \(s.goCacheWarningGB) GB",
                   "It was \(size); Shell cleared the build cache. " + (message ?? ""))
            return
        }
        let key = buildOver ? "GoBuildCacheWarningLastShown" : "GoCacheWarningLastShown"
        if let last = defaults.object(forKey: key) as? Date, Date().timeIntervalSince(last) < 86400 { return }
        defaults.set(Date(), forKey: key)
        notify("\(subject) \(buildOver ? "is" : "are") \(size)",
               buildOver
                   ? "That's over your \(s.goCacheWarningGB) GB limit. Open Settings › Go to clear it (go clean -cache)."
                   : "That's over your \(s.goCacheWarningGB) GB limit. Open Settings › Go to clear the build or module cache.")
    }
}
