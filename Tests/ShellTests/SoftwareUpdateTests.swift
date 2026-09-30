import XCTest
@testable import Shell

final class SoftwareUpdateTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(AppVersion.isNewer("0.2.0", than: "0.1.0"))
        XCTAssertTrue(AppVersion.isNewer("v0.10.0", than: "0.9.9"))
        XCTAssertTrue(AppVersion.isNewer("1.0", than: "0.99.99"))
        XCTAssertTrue(AppVersion.isNewer("0.1.1", than: "0.1"))
        XCTAssertFalse(AppVersion.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(AppVersion.isNewer("0.1", than: "0.1.0"))
        XCTAssertFalse(AppVersion.isNewer("0.1.0", than: "0.2.0"))
        XCTAssertFalse(AppVersion.isNewer("0.2.0-beta.1", than: "0.2.0"))
        XCTAssertFalse(AppVersion.isNewer("nightly", than: "0.1.0"))
        XCTAssertFalse(AppVersion.isNewer("0.2.0", than: "garbage"))
        XCTAssertEqual(AppVersion.components("v1.2.3+45"), [1, 2, 3])
        XCTAssertEqual(AppVersion.components("1..2"), [])
    }

    func testChecksumParsing() {
        let hex = String(repeating: "aB", count: 32)
        XCTAssertEqual(UpdateChecksum.parse("\(hex)  Shell-0.2.0-2.dmg\n"), hex.lowercased())
        XCTAssertEqual(UpdateChecksum.parse(hex), hex.lowercased())
        XCTAssertNil(UpdateChecksum.parse(""))
        XCTAssertNil(UpdateChecksum.parse("abc123  Shell.dmg"))
        XCTAssertNil(UpdateChecksum.parse(String(repeating: "z", count: 64)))
    }

    private func releaseJSON(tag: String = "v0.2.0", draft: Bool = false, prerelease: Bool = false, assets: [String]) -> Data {
        let list = assets.map {
            #"{"name": "\#($0)", "browser_download_url": "https://github.com/arhea/Shell/releases/download/\#(tag)/\#($0)", "size": 1234}"#
        }.joined(separator: ",")
        return Data("""
        {"tag_name": "\(tag)", "name": "Shell 0.2.0", "html_url": "https://github.com/arhea/Shell/releases/tag/\(tag)",
         "draft": \(draft), "prerelease": \(prerelease), "assets": [\(list)], "body": "notes"}
        """.utf8)
    }

    func testParsesReleaseWithDMGAndChecksum() throws {
        let data = releaseJSON(assets: ["Shell-0.2.0-2.zip", "Shell-0.2.0-2.dmg", "Shell-0.2.0-2.dmg.sha256"])
        let release = try XCTUnwrap(UpdateRelease.parse(data))
        XCTAssertEqual(release.version, "0.2.0")
        XCTAssertEqual(release.dmgName, "Shell-0.2.0-2.dmg")
        XCTAssertEqual(release.dmgSize, 1234)
        XCTAssertEqual(release.dmgURL.lastPathComponent, "Shell-0.2.0-2.dmg")
        XCTAssertEqual(release.checksumURL.lastPathComponent, "Shell-0.2.0-2.dmg.sha256")
        XCTAssertEqual(release.notesURL.absoluteString, "https://github.com/arhea/Shell/releases/tag/v0.2.0")
    }

    func testIgnoresIncompleteOrUnstableReleases() throws {
        XCTAssertNil(try UpdateRelease.parse(releaseJSON(assets: ["Shell-0.2.0-2.dmg"])), "no checksum yet")
        XCTAssertNil(try UpdateRelease.parse(releaseJSON(assets: ["Shell-0.2.0-2.zip", "Shell-0.2.0-2.zip.sha256"])), "no DMG")
        let both = ["Shell-0.2.0-2.dmg", "Shell-0.2.0-2.dmg.sha256"]
        XCTAssertNil(try UpdateRelease.parse(releaseJSON(draft: true, assets: both)))
        XCTAssertNil(try UpdateRelease.parse(releaseJSON(prerelease: true, assets: both)))
        XCTAssertNil(try UpdateRelease.parse(releaseJSON(tag: "latest", assets: both)))
    }

    @MainActor func testDefaultsAndSync() {
        let s = AppSettings()
        XCTAssertTrue(s.checkForUpdates)
        XCTAssertTrue(s.installUpdatesAutomatically)
        XCTAssertTrue(SettingsSync.portableKeys.contains("checkForUpdates"))
        var changed = s
        changed.installUpdatesAutomatically = false
        XCTAssertTrue(changed.differsOnlyInNonVisualState(from: s))
    }
}
