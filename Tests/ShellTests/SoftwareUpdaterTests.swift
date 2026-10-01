import AppKit
import CryptoKit
import XCTest
@testable import Shell

// MARK: - Fixtures

private func sampleRelease(_ version: String = "9.9.9") -> UpdateRelease {
    UpdateRelease(version: version, notesURL: URL(string: "https://github.com/arhea/Shell/releases/tag/v\(version)")!,
                  dmgName: "Shell-\(version).dmg", dmgURL: URL(string: "https://updates.test/Shell-\(version).dmg")!,
                  dmgSize: 4096, checksumURL: URL(string: "https://updates.test/Shell-\(version).dmg.sha256")!)
}

private struct Boom: LocalizedError { var errorDescription: String? { "offline" } }

/// Records everything the updater asks of the system and answers alerts from a script.
@MainActor
private final class UpdaterHarness {
    let dir: URL
    var system = SoftwareUpdater.System()
    var notifications: [(title: String, body: String, category: String?)] = []
    var alerts: [(message: String, info: String, buttons: [String])] = []
    var alertAnswers: [NSApplication.ModalResponse] = []
    var opened: [URL] = []
    var settingsShown = 0
    var terminated = 0
    var spawned: [(staged: URL, target: URL, relaunch: Bool)] = []
    var onTerminate: (@MainActor () -> Void)?

    /// Results for each fetch, in order (the last repeats); `etags` records what was sent.
    nonisolated(unsafe) var fetchResults: [Result<UpdateInstaller.LatestResult, Error>] = []
    nonisolated(unsafe) var etags: [String?] = []
    nonisolated(unsafe) var stageResult: Result<URL, Error> = .failure(Boom())
    nonisolated(unsafe) var stageDelay: Duration = .zero
    nonisolated(unsafe) var staged: [String] = []

    init(dir: URL, teamID: String? = "T9PCKZ42NK") throws {
        self.dir = dir
        let app = dir.appendingPathComponent("Applications/Shell.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        system.currentVersion = "1.0.0"
        system.teamID = teamID
        system.bundleURL = app
        system.bundleID = "app.bethesdalabs.Shell"
        system.stagingRoot = dir.appendingPathComponent("staging")
        system.stateURL = dir.appendingPathComponent("updates.json")
        // The closures below run off the main actor; the harness outlives each test's updater.
        let box = UnsafeBox(self)
        system.fetchLatest = { etag in
            let h = box.value
            h.etags.append(etag)
            let next = h.fetchResults.count > 1 ? h.fetchResults.removeFirst() : (h.fetchResults.first ?? .success(.release(nil, etag: nil)))
            return try next.get()
        }
        system.stage = { release, team, bundle, monitor in
            let h = box.value
            h.staged.append("\(release.version) \(team) \(bundle)")
            _ = monitor.bytesReceived
            if h.stageDelay > .zero { try? await Task.sleep(for: h.stageDelay) }
            return try h.stageResult.get()
        }
        system.spawnInstaller = { [weak self] staged, target, relaunch, _ in self?.spawned.append((staged, target, relaunch)) }
        system.notify = { [weak self] in self?.notifications.append(($0, $1, $2)) }
        system.runAlert = { [weak self] alert in
            guard let self else { return .abort }
            alerts.append((alert.messageText, alert.informativeText, alert.buttons.map(\.title)))
            return alertAnswers.isEmpty ? .alertThirdButtonReturn : alertAnswers.removeFirst()
        }
        system.open = { [weak self] in self?.opened.append($0) }
        system.showSettings = { [weak self] in self?.settingsShown += 1 }
        system.terminate = { [weak self] in
            self?.terminated += 1
            self?.onTerminate?()
        }
    }

    func updater() -> SoftwareUpdater { SoftwareUpdater(system: system) }
}

/// Hands a main-actor object to the updater's @Sendable hooks. Tests touch it
/// only while awaiting those hooks, so access never overlaps.
private final class UnsafeBox<T: AnyObject>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - Updater

@MainActor
final class SoftwareUpdaterTests: XCTestCase {
    private var h: UpdaterHarness!
    private var original: AppSettings!

    override func setUp() async throws {
        h = try UpdaterHarness(dir: try makeTemporaryDirectory())
        original = SettingsStore.shared.settings
        SettingsStore.shared.settings.checkForUpdates = true
        SettingsStore.shared.settings.installUpdatesAutomatically = true
    }

    override func tearDown() async throws {
        SettingsStore.shared.settings = original
    }

    func testInstallBlockers() throws {
        var system = h.system
        system.teamID = nil
        XCTAssertEqual(SoftwareUpdater(system: system).installBlocker, "This is a development build, so it doesn't update itself.")
        system.teamID = "TEAM"
        system.bundleURL = URL(fileURLWithPath: "/private/var/folders/xy/AppTranslocation/ABC/d/Shell.app")
        XCTAssertEqual(SoftwareUpdater(system: system).installBlocker, "Move Shell to your Applications folder to install updates.")
        let locked = h.dir.appendingPathComponent("Locked")
        try FileManager.default.createDirectory(at: locked.appendingPathComponent("Shell.app"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        system.bundleURL = locked.appendingPathComponent("Shell.app")
        XCTAssertTrue(SoftwareUpdater(system: system).installBlocker?.hasPrefix("Shell can't replace itself in") ?? false)
        XCTAssertNil(h.updater().installBlocker)
    }

    func testBasics() {
        let u = h.updater()
        XCTAssertEqual(u.currentVersion, "1.0.0")
        XCTAssertEqual(u.releasesURL.absoluteString, "https://github.com/\(UpdateInstaller.repository)/releases")
        XCTAssertEqual(u.phase, .idle)
        XCTAssertNil(u.lastCheck)
        XCTAssertEqual(SoftwareUpdater.checkInterval, 6 * 3600)
    }

    func testFailedCheck() async {
        h.fetchResults = [.failure(Boom())]
        let u = h.updater()
        await u.check(userInitiated: false)
        XCTAssertEqual(u.phase, .failed("offline"))
        XCTAssertNil(u.lastCheck)
    }

    func testNoReleaseOrNoNewerReleaseIsUpToDate() async {
        h.fetchResults = [.success(.release(nil, etag: nil)), .success(.release(sampleRelease("1.0.0"), etag: "\"e1\""))]
        let u = h.updater()
        await u.check(userInitiated: false)
        XCTAssertEqual(u.phase, .upToDate)
        let checked = u.lastCheck
        XCTAssertNotNil(checked)
        await u.check(userInitiated: false)
        XCTAssertEqual(u.phase, .upToDate)
        XCTAssertTrue(h.notifications.isEmpty)
        XCTAssertNotNil(h.updater().lastCheck, "the last check is saved")
    }

    func testUserInitiatedCheckOnlyAnnouncesInTheUI() async {
        h.fetchResults = [.success(.release(sampleRelease(), etag: "\"e1\""))]
        let u = h.updater()
        await u.check(userInitiated: true)
        XCTAssertEqual(u.phase, .available(sampleRelease()))
        XCTAssertTrue(h.notifications.isEmpty)
        XCTAssertTrue(h.staged.isEmpty)
    }

    func testAutomaticCheckWithoutAutoInstallNotifiesOncePerVersion() async {
        SettingsStore.shared.settings.installUpdatesAutomatically = false
        h.fetchResults = [.success(.release(sampleRelease(), etag: "\"e1\"")), .success(.notModified)]
        let u = h.updater()
        await u.check(userInitiated: false)
        XCTAssertEqual(u.phase, .available(sampleRelease()))
        XCTAssertEqual(h.notifications.count, 1)
        XCTAssertEqual(h.notifications.first?.title, "Shell 9.9.9 is available")
        XCTAssertEqual(h.notifications.first?.body, "You have 1.0.0. Choose Help › Install Shell 9.9.9 and Restart.")
        XCTAssertEqual(h.notifications.first?.category, NotificationManager.updateCategory)

        await u.check(userInitiated: false) // 304: the saved release is still the latest
        XCTAssertEqual(h.etags, [nil, "\"e1\""])
        XCTAssertEqual(u.phase, .available(sampleRelease()))
        XCTAssertEqual(h.notifications.count, 1, "announced once")

        // A new updater remembers the ETag, the release and the announcement.
        let reloaded = h.updater()
        await reloaded.check(userInitiated: false)
        XCTAssertEqual(h.etags.last, "\"e1\"")
        XCTAssertEqual(reloaded.phase, .available(sampleRelease()))
        XCTAssertEqual(h.notifications.count, 1)
    }

    func testBlockedCopiesAnnounceADownload() async {
        var system = h.system
        system.teamID = nil
        h.fetchResults = [.success(.release(sampleRelease(), etag: nil))]
        let u = SoftwareUpdater(system: system)
        await u.check(userInitiated: false)
        XCTAssertEqual(u.phase, .available(sampleRelease()))
        XCTAssertEqual(h.notifications.first?.body, "You have 1.0.0. Click to download it.")
        XCTAssertNil(h.notifications.first?.category)
        XCTAssertTrue(h.staged.isEmpty, "can't install, so nothing is downloaded")
    }

    func testAutomaticInstallDownloadsAndStages() async throws {
        let staged = h.dir.appendingPathComponent("staging/9.9.9/Shell.app")
        h.stageResult = .success(staged)
        h.stageDelay = .milliseconds(400) // long enough for a progress tick
        h.fetchResults = [.success(.release(sampleRelease(), etag: "\"e1\""))]
        let u = h.updater()
        let task = Task { await u.check(userInitiated: false) }
        await assertEventually { u.phase == .downloading(sampleRelease()) }
        XCTAssertNotNil(u.downloadFraction)
        await task.value
        XCTAssertEqual(u.phase, .ready(sampleRelease()))
        XCTAssertNil(u.downloadFraction)
        XCTAssertNil(u.downloadError)
        XCTAssertEqual(h.staged, ["9.9.9 T9PCKZ42NK app.bethesdalabs.Shell"])
        XCTAssertEqual(h.notifications.first?.body, "Restart Shell to install it, or it installs the next time you quit.")

        // A later check for the same version keeps the staged copy.
        await u.check(userInitiated: false)
        XCTAssertEqual(u.phase, .ready(sampleRelease()))
        XCTAssertEqual(h.staged.count, 1)

        // Quitting hands it to the installer (automatic installs are on).
        u.installOnQuit()
        XCTAssertEqual(h.spawned.count, 1)
        XCTAssertEqual(h.spawned.first?.staged, staged)
        XCTAssertEqual(h.spawned.first?.target, h.system.bundleURL)
        XCTAssertEqual(h.spawned.first?.relaunch, false)

        SettingsStore.shared.settings.installUpdatesAutomatically = false
        u.installOnQuit()
        XCTAssertEqual(h.spawned.count, 1, "off, and the user didn't ask to restart")
    }

    func testFailedDownloadStaysAvailableWithTheError() async {
        h.stageResult = .failure(UpdateInstaller.Failure("checksum mismatch"))
        h.fetchResults = [.success(.release(sampleRelease(), etag: nil))]
        let u = h.updater()
        await u.check(userInitiated: false)
        XCTAssertEqual(u.phase, .available(sampleRelease()))
        XCTAssertEqual(u.downloadError, "checksum mismatch")
        XCTAssertEqual(h.notifications.first?.body, "You have 1.0.0. Choose Help › Install Shell 9.9.9 and Restart.")
        u.installOnQuit()
        XCTAssertTrue(h.spawned.isEmpty, "nothing staged")
    }

    func testRestartToUpdateInstallsAndRelaunches() async {
        h.stageResult = .success(h.dir.appendingPathComponent("staging/9.9.9/Shell.app"))
        h.fetchResults = [.success(.release(sampleRelease(), etag: nil))]
        let u = h.updater()
        h.onTerminate = { u.installOnQuit() } // what quitting does
        await u.check(userInitiated: true)
        XCTAssertEqual(u.phase, .available(sampleRelease()))
        u.installAndRelaunch()
        await assertEventually { self.h.terminated == 1 }
        XCTAssertEqual(u.phase, .ready(sampleRelease()))
        XCTAssertEqual(h.spawned.first?.relaunch, true)

        u.installAndRelaunch() // already staged: straight to quitting
        await assertEventually { self.h.terminated == 2 }
    }

    func testRestartAfterAFailedDownloadOffersRetryAndTheDownloadPage() async {
        h.stageResult = .failure(UpdateInstaller.Failure("HTTP 500"))
        h.fetchResults = [.success(.release(sampleRelease(), etag: nil))]
        let u = h.updater()
        await u.check(userInitiated: true)
        h.alertAnswers = [.alertFirstButtonReturn, .alertSecondButtonReturn] // Try Again, then Open Download Page
        u.installAndRelaunch()
        await assertEventually { self.h.alerts.count == 2 && !self.h.opened.isEmpty }
        XCTAssertEqual(h.alerts.first?.message, "Couldn't download Shell 9.9.9")
        XCTAssertEqual(h.alerts.first?.info, "HTTP 500")
        XCTAssertEqual(h.alerts.first?.buttons, ["Try Again", "Open Download Page", "Cancel"])
        XCTAssertEqual(h.opened, [sampleRelease().notesURL])
        XCTAssertEqual(h.terminated, 0)

        h.alertAnswers = [.alertThirdButtonReturn]
        u.installAndRelaunch()
        await assertEventually { self.h.alerts.count == 3 }
        XCTAssertEqual(h.opened.count, 1, "Cancel does nothing")
    }

    func testRestartDoesNothingWhenBlockedOrWithoutAnUpdate() async throws {
        let u = h.updater()
        u.installAndRelaunch() // idle
        var system = h.system
        system.teamID = nil
        SoftwareUpdater(system: system).installAndRelaunch()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(h.terminated, 0)
        u.installOnQuit()
        XCTAssertTrue(h.spawned.isEmpty)
    }

    func testCheckForUpdatesResults() async {
        let u = h.updater()
        u.checkInteractively() // nothing published
        await assertEventually { self.h.alerts.count == 1 }
        XCTAssertEqual(h.alerts.last?.message, "You're up to date")
        XCTAssertEqual(h.alerts.last?.info, "Shell 1.0.0 is the latest version.")

        h.fetchResults = [.failure(Boom())]
        u.checkInteractively()
        await assertEventually { self.h.alerts.count == 2 }
        XCTAssertEqual(h.alerts.last?.message, "Couldn't check for updates")
        XCTAssertEqual(h.alerts.last?.info, "offline")

        h.fetchResults = [.success(.release(sampleRelease(), etag: nil))]
        h.alertAnswers = [.alertSecondButtonReturn] // Release Notes
        u.checkInteractively()
        await assertEventually { self.h.alerts.count == 3 }
        XCTAssertEqual(h.alerts.last?.message, "Shell 9.9.9 is available")
        XCTAssertEqual(h.alerts.last?.buttons, ["Install and Restart", "Release Notes", "Later"])
        XCTAssertEqual(h.opened, [sampleRelease().notesURL])
        XCTAssertTrue(h.notifications.isEmpty, "a check you asked for answers in the alert")
    }

    func testCheckForUpdatesInstallsFromTheAlert() async {
        h.stageResult = .success(h.dir.appendingPathComponent("staging/9.9.9/Shell.app"))
        h.fetchResults = [.success(.release(sampleRelease(), etag: nil))]
        h.alertAnswers = [.alertFirstButtonReturn] // Install and Restart
        let u = h.updater()
        u.checkInteractively()
        await assertEventually { self.h.terminated == 1 }
        XCTAssertEqual(h.settingsShown, 1, "shows download progress")

        // Now staged: the alert offers Restart Now.
        h.alertAnswers = [.alertFirstButtonReturn]
        u.checkInteractively()
        await assertEventually { self.h.terminated == 2 }
        XCTAssertEqual(h.alerts.last?.message, "Shell 9.9.9 is ready to install")
        XCTAssertEqual(h.alerts.last?.buttons.first, "Restart Now")
        XCTAssertEqual(h.settingsShown, 1)
    }

    func testCheckForUpdatesExplainsBlockersAndFailedDownloads() async {
        h.fetchResults = [.success(.release(sampleRelease(), etag: nil))]
        var system = h.system
        system.teamID = nil
        let blocked = SoftwareUpdater(system: system)
        h.alertAnswers = [.alertFirstButtonReturn] // Open Download Page
        blocked.checkInteractively()
        await assertEventually { self.h.alerts.count == 1 }
        XCTAssertEqual(h.alerts.last?.buttons, ["Open Download Page", "Later"])
        XCTAssertTrue(h.alerts.last?.info.contains("development build") ?? false)
        XCTAssertEqual(h.opened.count, 1)

        h.stageResult = .failure(UpdateInstaller.Failure("disk full"))
        let u = h.updater()
        await u.check(userInitiated: false) // automatic: tries the download and fails
        u.checkInteractively()
        await assertEventually { self.h.alerts.count == 2 }
        XCTAssertTrue(h.alerts.last?.info.hasSuffix("The last download failed: disk full") ?? false, h.alerts.last?.info ?? "")
    }

    func testCheckForUpdatesWhileDownloadingShowsProgress() async {
        h.stageResult = .success(h.dir.appendingPathComponent("staging/9.9.9/Shell.app"))
        h.stageDelay = .milliseconds(500)
        h.fetchResults = [.success(.release(sampleRelease(), etag: nil))]
        let u = h.updater()
        let auto = Task { await u.check(userInitiated: false) }
        await assertEventually { u.phase == .downloading(sampleRelease()) }
        u.checkInteractively() // busy: the check is skipped and the progress shown
        await assertEventually { self.h.settingsShown == 1 }
        await auto.value
        XCTAssertTrue(h.alerts.isEmpty)
    }

    func testStartClearsStagingAndConfiguresChecks() async throws {
        let staging = h.system.stagingRoot
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("0.1.0"), withIntermediateDirectories: true)
        let u = h.updater()
        u.start()
        await assertEventually { !FileManager.default.fileExists(atPath: staging.path) }
        u.configure() // reconfigure keeps a single wake observer
        SettingsStore.shared.settings.checkForUpdates = false
        u.configure()
        var system = h.system
        system.teamID = nil
        SoftwareUpdater(system: system).configure() // development builds never check automatically
        XCTAssertTrue(h.etags.isEmpty, "configuring doesn't check right away")
    }
}

// MARK: - Installer

/// Serves canned responses for `updates.test` and the GitHub API in a private URLSession.
private final class StubUpdateProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { var status = 200; var headers: [String: String] = [:]; var body = Data() }
    // Guarded by the lock; set by the test, read on URL loading threads.
    nonisolated(unsafe) static var replies: [String: Reply] = [:]
    nonisolated(unsafe) static var seen: [URLRequest] = []
    static let lock = NSLock()

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubUpdateProtocol.self]
        return URLSession(configuration: config)
    }()

    static func set(_ url: String, _ reply: Reply) { lock.withLock { replies[url] = reply } }
    static func reset() { lock.withLock { replies = [:]; seen = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = Self.lock.withLock { () -> Reply in
            Self.seen.append(request)
            return Self.replies[request.url?.absoluteString ?? ""] ?? Reply(status: 404)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class UpdateInstallerTests: XCTestCase {
    private let latestURL = "https://api.github.com/repos/\(UpdateInstaller.repository)/releases/latest"
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try makeTemporaryDirectory()
        StubUpdateProtocol.reset()
    }

    override func tearDown() {
        StubUpdateProtocol.reset()
        super.tearDown()
    }

    private func releaseJSON() -> Data {
        Data(#"""
        {"tag_name": "v9.9.9", "html_url": "https://github.com/arhea/Shell/releases/tag/v9.9.9", "draft": false, "prerelease": false,
         "assets": [{"name": "Shell-9.9.9.dmg", "browser_download_url": "https://updates.test/Shell-9.9.9.dmg", "size": 10},
                    {"name": "Shell-9.9.9.dmg.sha256", "browser_download_url": "https://updates.test/Shell-9.9.9.dmg.sha256", "size": 80}]}
        """#.utf8)
    }

    func testFetchLatestHandlesEachResponse() async throws {
        StubUpdateProtocol.set(latestURL, .init(status: 200, headers: ["ETag": "\"abc\""], body: releaseJSON()))
        guard case .release(let r?, let etag) = try await UpdateInstaller.fetchLatest(etag: nil, session: StubUpdateProtocol.session) else {
            return XCTFail("expected a release")
        }
        XCTAssertEqual(r.version, "9.9.9")
        XCTAssertEqual(etag, "\"abc\"")
        let first = try XCTUnwrap(StubUpdateProtocol.lock.withLock { StubUpdateProtocol.seen.first })
        XCTAssertEqual(first.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertNil(first.value(forHTTPHeaderField: "If-None-Match"))

        StubUpdateProtocol.set(latestURL, .init(status: 304))
        guard case .notModified = try await UpdateInstaller.fetchLatest(etag: "\"abc\"", session: StubUpdateProtocol.session) else {
            return XCTFail("expected not modified")
        }
        XCTAssertEqual(StubUpdateProtocol.lock.withLock { StubUpdateProtocol.seen.last?.value(forHTTPHeaderField: "If-None-Match") }, "\"abc\"")

        StubUpdateProtocol.set(latestURL, .init(status: 404))
        guard case .release(.none, .none) = try await UpdateInstaller.fetchLatest(etag: nil, session: StubUpdateProtocol.session) else {
            return XCTFail("expected no release")
        }

        for status in [403, 429] {
            StubUpdateProtocol.set(latestURL, .init(status: status))
            do {
                _ = try await UpdateInstaller.fetchLatest(etag: nil, session: StubUpdateProtocol.session)
                XCTFail("expected a rate-limit error")
            } catch {
                XCTAssertEqual(error.localizedDescription, "GitHub's rate limit was reached. Shell will try again later.")
            }
        }
        StubUpdateProtocol.set(latestURL, .init(status: 502))
        do {
            _ = try await UpdateInstaller.fetchLatest(etag: nil, session: StubUpdateProtocol.session)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "GitHub returned HTTP 502.")
        }
    }

    private func stage(_ release: UpdateRelease) async -> Error? {
        do {
            _ = try await UpdateInstaller.stage(release, teamID: "TEAM", bundleID: "app.bethesdalabs.Shell",
                                                monitor: UpdateInstaller.DownloadMonitor(), root: dir.appendingPathComponent("staging"),
                                                session: StubUpdateProtocol.session)
            return nil
        } catch {
            return error
        }
    }

    private func serve(dmg: Data, checksum: String? = nil, dmgStatus: Int = 200) {
        let r = UpdateRelease(version: "9.9.9", notesURL: URL(string: "https://x.test")!, dmgName: "Shell-9.9.9.dmg",
                                    dmgURL: URL(string: "https://updates.test/Shell-9.9.9.dmg")!, dmgSize: dmg.count,
                                    checksumURL: URL(string: "https://updates.test/Shell-9.9.9.dmg.sha256")!)
        let sum = checksum ?? SHA256Hex.of(dmg)
        StubUpdateProtocol.set(r.checksumURL.absoluteString, .init(body: Data("\(sum)  Shell-9.9.9.dmg\n".utf8)))
        StubUpdateProtocol.set(r.dmgURL.absoluteString, .init(status: dmgStatus, body: dmg))
    }

    private var testRelease: UpdateRelease {
        UpdateRelease(version: "9.9.9", notesURL: URL(string: "https://x.test")!, dmgName: "Shell-9.9.9.dmg",
                      dmgURL: URL(string: "https://updates.test/Shell-9.9.9.dmg")!, dmgSize: 10,
                      checksumURL: URL(string: "https://updates.test/Shell-9.9.9.dmg.sha256")!)
    }

    func testStageRejectsAMissingOrMalformedChecksum() async {
        var error = await stage(testRelease) // nothing served: 404
        XCTAssertEqual(error?.localizedDescription, "The release's checksum file is missing or malformed.")
        serve(dmg: Data("x".utf8), checksum: "not-a-digest")
        error = await stage(testRelease)
        XCTAssertEqual(error?.localizedDescription, "The release's checksum file is missing or malformed.")
    }

    func testStageRejectsAFailedDownloadOrAMismatchedDigest() async {
        serve(dmg: Data("x".utf8), dmgStatus: 500)
        var error = await stage(testRelease)
        XCTAssertEqual(error?.localizedDescription, "Downloading Shell-9.9.9.dmg failed (HTTP 500).")
        serve(dmg: Data("x".utf8), checksum: String(repeating: "0", count: 64))
        error = await stage(testRelease)
        XCTAssertEqual(error?.localizedDescription, "Shell-9.9.9.dmg doesn't match its published checksum.")
    }

    func testStageRejectsSomethingThatIsntADiskImage() async {
        serve(dmg: Data("definitely not a disk image".utf8))
        let error = await stage(testRelease)
        XCTAssertTrue(error?.localizedDescription.hasPrefix("Couldn't open Shell-9.9.9.dmg") ?? false, error?.localizedDescription ?? "nil")
    }

    /// Builds a small read-only disk image from `folder`, or nil if hdiutil isn't usable here.
    private func makeDMG(from folder: URL) throws -> Data? {
        let dmg = dir.appendingPathComponent("image-\(UUID().uuidString.prefix(6)).dmg")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["create", "-quiet", "-fs", "HFS+", "-format", "UDZO", "-volname", "ShellTest", "-srcfolder", folder.path, dmg.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return try Data(contentsOf: dmg)
    }

    func testStageCopiesTheAppOutOfTheImageAndVerifiesIt() async throws {
        let src = dir.appendingPathComponent("src")
        let app = src.appendingPathComponent("Shell.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist: NSDictionary = ["CFBundleIdentifier": "app.bethesdalabs.Shell", "CFBundleShortVersionString": "9.9.9"]
        plist.write(to: app.appendingPathComponent("Info.plist"), atomically: true)
        guard let dmg = try makeDMG(from: src) else { throw XCTSkip("hdiutil can't create disk images here") }
        serve(dmg: dmg)
        let error = await stage(testRelease)
        // The copy is unsigned, so the signature check is what rejects it.
        XCTAssertTrue(signatureRejected(error?.localizedDescription), error?.localizedDescription ?? "nil")
        let staged = dir.appendingPathComponent("staging/9.9.9")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.appendingPathComponent("Shell.app/Contents/Info.plist").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.appendingPathComponent("Shell-9.9.9.dmg").path), "the image is deleted")
    }

    func testStageNeedsAnAppInTheImage() async throws {
        let src = dir.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("readme".utf8).write(to: src.appendingPathComponent("README"))
        guard let dmg = try makeDMG(from: src) else { throw XCTSkip("hdiutil can't create disk images here") }
        serve(dmg: dmg)
        let error = await stage(testRelease)
        XCTAssertEqual(error?.localizedDescription, "Couldn't copy Shell from the disk image: no app in the disk image")
    }

    func testVerifyChecksIdentityVersionAndSignature() async throws {
        let app = dir.appendingPathComponent("Shell.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: NSDictionary = ["CFBundleIdentifier": "com.example.other", "CFBundleShortVersionString": "9.9.9"]
        plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)

        func verify(_ version: String, _ bundleID: String) async -> String? {
            do {
                try await UpdateInstaller.verify(app: app, version: version, teamID: "TEAM", bundleID: bundleID)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        var message = await verify("9.9.9", "app.bethesdalabs.Shell")
        XCTAssertEqual(message, "The downloaded app isn't Shell.")
        message = await verify("1.0.0", "com.example.other")
        XCTAssertEqual(message, "The downloaded app's version doesn't match release 1.0.0.")
        message = await verify("9.9.9", "com.example.other")
        XCTAssertTrue(signatureRejected(message), message ?? "nil")
        let missing = dir.appendingPathComponent("Missing.app")
        do {
            try await UpdateInstaller.verify(app: missing, version: "1", teamID: "T", bundleID: "x")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The downloaded app isn't Shell.")
        }
    }

    /// An unsigned copy fails either reading or checking its signature.
    private func signatureRejected(_ message: String?) -> Bool {
        guard let message else { return false }
        return message.hasPrefix("The downloaded app isn't signed by Shell's developer")
            || message == "Couldn't read the downloaded app's signature."
    }

    func testSHA256() throws {
        let small = dir.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: small)
        XCTAssertEqual(try UpdateInstaller.sha256(of: small), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let big = dir.appendingPathComponent("big")
        let data = Data(repeating: 0x61, count: (1 << 20) + 17)
        try data.write(to: big)
        XCTAssertEqual(try UpdateInstaller.sha256(of: big), SHA256Hex.of(data))
        XCTAssertThrowsError(try UpdateInstaller.sha256(of: dir.appendingPathComponent("nope")))
    }

    func testDownloadMonitorStartsAtZero() {
        XCTAssertEqual(UpdateInstaller.DownloadMonitor().bytesReceived, 0)
        XCTAssertTrue(UpdateInstaller.stagingRoot.path.hasSuffix("app.bethesdalabs.Shell/Updates"))
        XCTAssertFalse(UpdateInstaller.currentVersion.isEmpty)
    }

    /// The pid of a process that has already exited, so the helper doesn't wait.
    private func exitedPID() throws -> pid_t {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try p.run()
        p.waitUntilExit()
        return p.processIdentifier
    }

    private func waitForLog(_ log: URL, containing text: String, timeout: TimeInterval = 10) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var contents = ""
        while Date() < deadline {
            contents = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            if contents.contains(text) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return contents
    }

    func testInstallerHelperSwapsTheAppInATempFolder() throws {
        let fm = FileManager.default
        let staged = dir.appendingPathComponent("stage/9.9.9/Shell.app")
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: staged.appendingPathComponent("version"))
        let target = dir.appendingPathComponent("Applications/Shell.app")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("version"))
        let log = dir.appendingPathComponent("update.log")

        XCTAssertTrue(UpdateInstaller.spawnInstaller(staged: staged, target: target, relaunch: false, log: log, waitingFor: try exitedPID()))
        let output = waitForLog(log, containing: "updated")
        XCTAssertTrue(output.contains("updating \(target.path)"), output)
        XCTAssertTrue(output.contains("\nupdated"), output)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("version"), encoding: .utf8), "new")
        // "updated" is logged just before the staging folder is removed.
        let deadline = Date().addingTimeInterval(5)
        while fm.fileExists(atPath: staged.deletingLastPathComponent().path), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertFalse(fm.fileExists(atPath: staged.deletingLastPathComponent().path), "the staging folder is removed")
        let leftovers = try fm.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["Shell.app"], "no .Shell-update/.Shell-previous copies remain")
    }

    func testInstallerHelperKeepsTheCurrentAppWhenTheCopyFails() throws {
        let target = dir.appendingPathComponent("Applications/Shell.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("version"))
        let log = dir.appendingPathComponent("update.log")
        let missing = dir.appendingPathComponent("stage/none/Shell.app")
        XCTAssertTrue(UpdateInstaller.spawnInstaller(staged: missing, target: target, relaunch: false, log: log, waitingFor: try exitedPID()))
        let output = waitForLog(log, containing: "update failed")
        XCTAssertTrue(output.contains("update failed; kept the current version"), output)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("version"), encoding: .utf8), "old")
    }
}

/// Hex SHA-256 for fixtures, in one shot rather than UpdateInstaller's chunks.
private enum SHA256Hex {
    static func of(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
