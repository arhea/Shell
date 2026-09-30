import XCTest
@testable import Shell

/// Tests run inside Shell (TEST_HOST); they must never touch the user's real files.
final class TestIsolationTests: XCTestCase {
    func testDetectsTheTestHost() {
        XCTAssertTrue(AppEnvironment.isRunningTests)
    }

    @MainActor
    func testFilesLiveInATemporaryFolder() {
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shell").standardizedFileURL.path
        for url in [SettingsStore.supportDirectory, SettingsStore.fileURL, ConfigController.configURL, SessionRestore.fileURL] {
            XCTAssertFalse(url.standardizedFileURL.path.hasPrefix(real), "\(url.path) is in the real support folder")
            XCTAssertTrue(url.standardizedFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path))
        }
    }

    @MainActor
    func testNoWindowsOrSocketAtLaunch() {
        XCTAssertTrue(AppDelegate.shared.controllers.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ShellIntegration.socketPath))
    }
}

final class LenientSettingsTests: XCTestCase {
    /// Retired or unknown values must not make the whole settings file fall back to defaults.
    func testUnknownEnumValuesFallBack() throws {
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any])
        dict["sidebarTab"] = "prs"
        dict["githubSection"] = "something-new"
        dict["fontSize"] = 17
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: dict))
        XCTAssertEqual(decoded.sidebarTab, .github)
        XCTAssertEqual(decoded.githubSection, .prs)
        XCTAssertEqual(decoded.fontSize, 17)
    }
}
