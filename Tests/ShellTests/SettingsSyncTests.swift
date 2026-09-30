import XCTest
@testable import Shell

@MainActor
final class SettingsSyncTests: XCTestCase {
    func testPortableExcludesMachineSpecificSettings() throws {
        var s = AppSettings()
        s.darkTheme = "Dracula"
        s.environment = ["API_TOKEN": "secret"]
        s.shellPath = "/opt/homebrew/bin/zsh"
        s.iCloudSync = true
        let portable = try XCTUnwrap(SettingsSync.portable(s))
        XCTAssertEqual(portable["darkTheme"] as? String, "Dracula")
        XCTAssertNil(portable["environment"])
        XCTAssertNil(portable["shellPath"])
        XCTAssertNil(portable["iCloudSync"])
        XCTAssertNil(portable["worktreeRoot"])
    }

    func testEveryPortableKeyExists() throws {
        // Catches typos and renamed settings in the allowlist.
        let data = try JSONEncoder().encode(AppSettings())
        let keys = Set(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys)
        let missing = SettingsSync.portableKeys.subtracting(keys).subtracting(["hotkey"]) // nil-able keys may be omitted
        XCTAssertEqual(missing, [])
    }

    func testMergeAppliesOnlyPortableKeys() throws {
        var local = AppSettings()
        local.shellPath = "/bin/zsh"
        local.fontSize = 13
        let remote: [String: Any] = ["fontSize": 16.0, "shellPath": "/bin/bash", "notARealKey": 1]
        let merged = try XCTUnwrap(SettingsSync.merge(remote: remote, into: local))
        XCTAssertEqual(merged.fontSize, 16)
        XCTAssertEqual(merged.shellPath, "/bin/zsh")
    }

    func testMergeRejectsInvalidValues() {
        XCTAssertNil(SettingsSync.merge(remote: ["fontSize": "huge"], into: AppSettings()))
    }

    func testRoundTripThroughFile() throws {
        var s = AppSettings()
        s.lightTheme = "Solarized Light"
        s.shortcuts = ["newTab": KeyShortcut(key: "t", modifiers: [.command, .shift])]
        let file: [String: Any] = ["format": 1, "modified": "2026-09-27T12:00:00.000Z", "device": "Mac",
                                   "settings": try XCTUnwrap(SettingsSync.portable(s))]
        let parsed = try XCTUnwrap(SettingsSync.parse(JSONSerialization.data(withJSONObject: file)))
        XCTAssertEqual(parsed.device, "Mac")
        XCTAssertNotNil(parsed.modified)
        let merged = try XCTUnwrap(SettingsSync.merge(remote: parsed.settings, into: AppSettings()))
        XCTAssertEqual(merged.lightTheme, "Solarized Light")
        XCTAssertEqual(merged.shortcuts, s.shortcuts)
        XCTAssertTrue(SettingsSync.samePortable(merged, s))
    }
}
