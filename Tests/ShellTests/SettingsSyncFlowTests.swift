import XCTest
@testable import Shell

/// SettingsSync push, pull and enable flows. Under tests the "iCloud Drive"
/// folder is inside the temporary support directory and the sync stamps live
/// in a test-only defaults suite, so nothing touches the real iCloud Drive.
@MainActor
final class SettingsSyncFlowTests: XCTestCase {
    private let fm = FileManager.default

    /// `start()` registers a settings observer for the app's lifetime; do it once.
    private static var started = false
    private static func startSyncOnce() {
        guard !started else { return }
        started = true
        SettingsSync.shared.start()
    }

    override func setUp() async throws {
        try await super.setUp()
        XCTAssertTrue(SettingsSync.cloudDocuments.path.hasPrefix(SettingsStore.supportDirectory.path), "tests must never use the real iCloud Drive")
        XCTAssertFalse(SettingsSync.defaults === UserDefaults.standard)
        resetCloud()
    }

    override func tearDown() async throws {
        resetCloud()
        try await super.tearDown()
    }

    private func resetCloud() {
        try? fm.removeItem(at: SettingsSync.cloudDocuments)
        SettingsSync.defaults.removeObject(forKey: SettingsSync.lastSyncedKey)
        SettingsSync.defaults.removeObject(forKey: SettingsSync.lastSeenKey)
    }

    private func makeCloudAvailable() throws {
        try fm.createDirectory(at: SettingsSync.cloudDocuments, withIntermediateDirectories: true)
    }

    private static let stampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Writes a remote settings file as another Mac would.
    private func writeRemote(_ change: (inout AppSettings) -> Void, modified: Date = Date(), device: String = "Other Mac") throws {
        var s = AppSettings()
        change(&s)
        try fm.createDirectory(at: SettingsSync.folder, withIntermediateDirectories: true)
        let file: [String: Any] = ["format": 1, "modified": Self.stampFormatter.string(from: modified), "device": device,
                                   "settings": try XCTUnwrap(SettingsSync.portable(s))]
        try JSONSerialization.data(withJSONObject: file).write(to: SettingsSync.fileURL)
    }

    private func readRemote() throws -> SettingsSync.RemoteFile {
        try XCTUnwrap(SettingsSync.parse(Data(contentsOf: SettingsSync.fileURL)))
    }

    // MARK: Availability and remote state

    func testAvailabilityFollowsTheCloudFolder() throws {
        XCTAssertFalse(SettingsSync.isAvailable)
        try makeCloudAvailable()
        XCTAssertTrue(SettingsSync.isAvailable)
        XCTAssertEqual(SettingsSync.folder.deletingLastPathComponent(), SettingsSync.cloudDocuments)
        XCTAssertEqual(SettingsSync.fileURL.lastPathComponent, "settings.json")
    }

    func testRemoteStateIsNoneWithoutAFile() throws {
        try makeCloudAvailable()
        guard case .none = SettingsSync.shared.remoteState() else { return XCTFail("expected no remote") }
    }

    func testRemoteStateIgnoresANotYetDownloadedPlaceholder() throws {
        try makeCloudAvailable()
        try fm.createDirectory(at: SettingsSync.folder, withIntermediateDirectories: true)
        try Data().write(to: SettingsSync.folder.appendingPathComponent(".settings.json.icloud"))
        guard case .none = SettingsSync.shared.remoteState() else { return XCTFail("a placeholder isn't settings yet") }
    }

    func testRemoteStateReportsDeviceAndDate() throws {
        try makeCloudAvailable()
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        try writeRemote({ $0.fontSize = 15 }, modified: when, device: "Studio")
        guard case .exists(let device, let modified) = SettingsSync.shared.remoteState() else { return XCTFail("expected a remote") }
        XCTAssertEqual(device, "Studio")
        XCTAssertEqual(try XCTUnwrap(modified).timeIntervalSince1970, when.timeIntervalSince1970, accuracy: 0.01)
    }

    func testParseRejectsFilesWithoutSettings() {
        XCTAssertNil(SettingsSync.parse(Data("[]".utf8)))
        XCTAssertNil(SettingsSync.parse(Data(#"{"format": 1}"#.utf8)))
        let parsed = SettingsSync.parse(Data(#"{"settings": {}, "modified": "yesterday"}"#.utf8))
        XCTAssertNotNil(parsed)
        XCTAssertNil(parsed?.modified, "an unreadable date is dropped, not fatal")
        XCTAssertNil(parsed?.device)
    }

    // MARK: Push

    func testPushDoesNothingWhileSyncIsOff() throws {
        try makeCloudAvailable()
        withSettings({ $0.iCloudSync = false }) { SettingsSync.shared.pushNow() }
        XCTAssertFalse(fm.fileExists(atPath: SettingsSync.fileURL.path))
    }

    func testPushDoesNothingWithoutICloudDrive() {
        withSettings({ $0.iCloudSync = true }) { SettingsSync.shared.pushNow() }
        XCTAssertFalse(fm.fileExists(atPath: SettingsSync.fileURL.path))
    }

    func testPushWritesOnlyPortableSettings() throws {
        try makeCloudAvailable()
        try withSettings({ $0.iCloudSync = true; $0.darkTheme = "Pushed"; $0.shellPath = "/bin/secret-zsh" }) {
            SettingsSync.shared.pushNow()
            let remote = try readRemote()
            XCTAssertEqual(remote.settings["darkTheme"] as? String, "Pushed")
            XCTAssertNil(remote.settings["shellPath"], "machine-specific settings stay on this Mac")
            XCTAssertNil(remote.settings["iCloudSync"])
            XCTAssertNotNil(remote.modified)
            XCTAssertNotNil(remote.device)
            XCTAssertNotNil(SettingsSync.shared.lastSynced)
        }
    }

    func testPushSkipsWritingWhenICloudAlreadyMatches() throws {
        try makeCloudAvailable()
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try writeRemote({ $0.darkTheme = "Same" }, modified: old)
        try withSettings({ $0.iCloudSync = true; $0.darkTheme = "Same" }) {
            SettingsSync.shared.pushNow()
            let modified = try XCTUnwrap(readRemote().modified)
            XCTAssertEqual(modified.timeIntervalSince1970, old.timeIntervalSince1970, accuracy: 0.01, "the file wasn't rewritten")
            XCTAssertNotNil(SettingsSync.shared.lastSynced)
        }
    }

    // MARK: Pull

    func testPullAppliesANewerRemoteCopy() throws {
        try makeCloudAvailable()
        try writeRemote({ $0.darkTheme = "From Other Mac"; $0.fontSize = 18 })
        withSettings({ $0.iCloudSync = true; $0.shellPath = "/bin/local" }) {
            XCTAssertTrue(SettingsSync.shared.pullIfNewer())
            XCTAssertEqual(SettingsStore.shared.settings.darkTheme, "From Other Mac")
            XCTAssertEqual(SettingsStore.shared.settings.fontSize, 18)
            XCTAssertEqual(SettingsStore.shared.settings.shellPath, "/bin/local", "local-only settings are kept")
            XCTAssertTrue(SettingsStore.shared.settings.iCloudSync)
            // The same copy isn't applied twice.
            XCTAssertFalse(SettingsSync.shared.pullIfNewer())
        }
    }

    func testPullIgnoresOlderCopies() throws {
        try makeCloudAvailable()
        SettingsSync.defaults.set(Date(), forKey: SettingsSync.lastSeenKey)
        try writeRemote({ $0.darkTheme = "Stale" }, modified: Date().addingTimeInterval(-3600))
        withSettings({ $0.iCloudSync = true }) {
            XCTAssertFalse(SettingsSync.shared.pullIfNewer())
            XCTAssertNotEqual(SettingsStore.shared.settings.darkTheme, "Stale")
        }
    }

    func testPullDoesNothingWhileSyncIsOffOrWithoutAFile() throws {
        try makeCloudAvailable()
        withSettings({ $0.iCloudSync = true }) { XCTAssertFalse(SettingsSync.shared.pullIfNewer()) }
        try writeRemote({ $0.darkTheme = "Ignored" })
        withSettings({ $0.iCloudSync = false }) {
            XCTAssertFalse(SettingsSync.shared.pullIfNewer())
            XCTAssertNotEqual(SettingsStore.shared.settings.darkTheme, "Ignored")
        }
    }

    func testPullOfIdenticalSettingsStillRecordsTheSync() throws {
        try makeCloudAvailable()
        try writeRemote({ _ in })
        withSettings({ $0 = AppSettings(); $0.iCloudSync = true }) {
            let before = SettingsStore.shared.settings
            XCTAssertTrue(SettingsSync.shared.pullIfNewer())
            XCTAssertEqual(SettingsStore.shared.settings, before)
            XCTAssertNotNil(SettingsSync.shared.lastSynced)
        }
    }

    // MARK: Enable

    func testEnableWithRemoteAppliesTheICloudCopy() throws {
        try makeCloudAvailable()
        try writeRemote({ $0.lightTheme = "Remote Light" })
        withSettings({ $0.iCloudSync = false }) {
            SettingsSync.shared.enable(useRemote: true)
            XCTAssertTrue(SettingsStore.shared.settings.iCloudSync)
            XCTAssertEqual(SettingsStore.shared.settings.lightTheme, "Remote Light")
        }
    }

    func testEnableWithLocalKeepsThisMacsSettings() throws {
        try makeCloudAvailable()
        try writeRemote({ $0.lightTheme = "Remote Light" }, modified: Date().addingTimeInterval(-60))
        withSettings({ $0.iCloudSync = false; $0.lightTheme = "Local Light" }) {
            SettingsSync.shared.enable(useRemote: false)
            XCTAssertTrue(SettingsStore.shared.settings.iCloudSync)
            XCTAssertEqual(SettingsStore.shared.settings.lightTheme, "Local Light")
            // The iCloud copy is now considered stale, so it isn't pulled.
            XCTAssertFalse(SettingsSync.shared.pullIfNewer())
        }
    }

    // MARK: Lifecycle

    func testTurningSyncOnPublishesAndChangesArePushed() throws {
        try makeCloudAvailable()
        Self.startSyncOnce()
        try withSettings({ $0.darkTheme = "Before Sync" }) {
            SettingsStore.shared.settings.iCloudSync = true // activates: nothing remote, so it publishes
            XCTAssertEqual(try readRemote().settings["darkTheme"] as? String, "Before Sync")
            // Let the folder watcher see that write first: it can re-apply this Mac's own
            // file (its `modified` stamp is rounded to milliseconds), which would race a
            // change made within the watcher's one-second latency.
            RunLoop.main.run(until: Date().addingTimeInterval(1.6))

            SettingsStore.shared.settings.darkTheme = "After Sync" // scheduled push, about a second later
            XCTAssertTrue(waitUntil(timeout: 5) {
                (try? self.readRemote().settings["darkTheme"] as? String) == "After Sync"
            })

            SettingsStore.shared.settings.shellPath = "/bin/not-portable" // not portable: no push
            SettingsStore.shared.settings.iCloudSync = false // deactivates
            SettingsStore.shared.settings.darkTheme = "While Off"
            RunLoop.main.run(until: Date().addingTimeInterval(1.3))
            XCTAssertEqual(try readRemote().settings["darkTheme"] as? String, "After Sync", "nothing is pushed while sync is off")
        }
    }

    func testTurningSyncOnPullsANewerRemoteCopy() throws {
        try makeCloudAvailable()
        try writeRemote({ $0.darkTheme = "Remote Wins" })
        Self.startSyncOnce()
        withSettings({ $0.darkTheme = "Local" }) {
            SettingsStore.shared.settings.iCloudSync = true
            XCTAssertEqual(SettingsStore.shared.settings.darkTheme, "Remote Wins")
            SettingsStore.shared.settings.iCloudSync = false
        }
    }
}
