import XCTest
@testable import Shell

/// The model itself isn't available in CI; these cover what surrounds it:
/// when Shell asks, what it sends, and which answers it accepts.
final class IntelligenceTests: XCTestCase {
    // MARK: Branch names

    func testBranchNamesAreValidatedDedupedAndCapped() {
        let names = IntelligencePrompts.validBranchNames(
            ["fix/login-redirect", "Fix/Login-Redirect", "`chore/deps`", "bad name..", "feat/x", "feat/y", "feat/z"],
            existing: ["feat/x"])
        XCTAssertEqual(names, ["fix/login-redirect", "chore/deps", "feat/y"])
    }

    func testBranchNamesRejectInvalidRefs() {
        XCTAssertEqual(IntelligencePrompts.validBranchNames(["-oops", "a..b", "x/.hidden", "ok-name"], existing: []), ["ok-name"])
    }

    func testBranchPromptIncludesRecentBranchesForStyle() {
        let prompt = IntelligencePrompts.branchNames(description: "  fix the login redirect ", recentBranches: ["feat/pla-1", "bug/pla-2"])
        XCTAssertTrue(prompt.contains("Work: fix the login redirect\n"))
        XCTAssertTrue(prompt.contains("- feat/pla-1"))
    }

    func testLooksLikeRequest() {
        XCTAssertFalse(IntelligencePrompts.looksLikeRequest("split"))
        XCTAssertFalse(IntelligencePrompts.looksLikeRequest("split right"))
        XCTAssertTrue(IntelligencePrompts.looksLikeRequest("make the text bigger"))
    }

    // MARK: Command fixes

    func testFixesSkipSignalsAndSilentFailures() {
        XCTAssertFalse(IntelligencePrompts.shouldSuggestFix(exitCode: 0, output: "error"))
        XCTAssertFalse(IntelligencePrompts.shouldSuggestFix(exitCode: 130, output: "^C"))
        XCTAssertFalse(IntelligencePrompts.shouldSuggestFix(exitCode: 1, output: "  \n"))
        XCTAssertTrue(IntelligencePrompts.shouldSuggestFix(exitCode: 127, output: ""))
        XCTAssertTrue(IntelligencePrompts.shouldSuggestFix(exitCode: 1, output: "git: 'psuh' is not a git command"))
    }

    func testValidatedFixCleansAndAccepts() {
        XCTAssertEqual(IntelligencePrompts.validatedFix("$ `git push`", original: "git psuh", output: ""), "git push")
    }

    func testValidatedFixRejectsUnchangedEmptyOrMalformed() {
        XCTAssertNil(IntelligencePrompts.validatedFix("git psuh", original: "git psuh ", output: ""))
        XCTAssertNil(IntelligencePrompts.validatedFix("  ", original: "ls", output: ""))
        XCTAssertNil(IntelligencePrompts.validatedFix("echo \"hi", original: "ech hi", output: ""))
        XCTAssertNil(IntelligencePrompts.validatedFix("ls\nrm x", original: "lss", output: ""))
    }

    func testValidatedFixNeverAddsRiskyWords() {
        XCTAssertNil(IntelligencePrompts.validatedFix("rm -rf build && make", original: "make", output: "error"))
        XCTAssertNil(IntelligencePrompts.validatedFix("git push --force", original: "git push", output: "rejected"))
        // Already in the original: allowed.
        XCTAssertEqual(IntelligencePrompts.validatedFix("rm -r build", original: "rm build", output: "is a directory"), "rm -r build")
    }

    func testSudoOnlyForPermissionErrors() {
        XCTAssertNil(IntelligencePrompts.validatedFix("sudo make install", original: "make install", output: "No rule to make target"))
        XCTAssertEqual(IntelligencePrompts.validatedFix("sudo make install", original: "make install", output: "cp: Permission denied"),
                       "sudo make install")
    }

    func testTailKeepsTheEndAtALineBoundary() {
        let text = (1...2000).map { "line \($0)" }.joined(separator: "\n")
        let tail = IntelligencePrompts.tail(text, maxCharacters: 100)
        XCTAssertLessThanOrEqual(tail.count, 100)
        XCTAssertTrue(tail.hasSuffix("line 2000"))
        XCTAssertTrue(tail.hasPrefix("line "))
    }

    // MARK: Lines

    func testCleanLine() {
        XCTAssertEqual(IntelligencePrompts.cleanLine("\"Auth Refactor.\"\nextra", maxLength: 32), "Auth Refactor")
        XCTAssertNil(IntelligencePrompts.cleanLine("   ", maxLength: 32))
        XCTAssertNil(IntelligencePrompts.cleanLine(String(repeating: "a", count: 40), maxLength: 32))
    }

    // MARK: Gating

    @MainActor
    func testEveryFeatureIsOffByDefault() {
        let defaults = AppSettings()
        for feature in IntelligenceFeature.allCases {
            XCTAssertFalse(defaults[keyPath: feature.keyPath], feature.rawValue)
        }
        XCTAssertFalse(defaults.intelligenceAnnouncementShown)
    }

    @MainActor
    func testIntelligenceSettingsDontSync() {
        for key in ["intelligenceBranchNames", "intelligencePaletteIntents", "intelligenceCommandFixes",
                    "intelligenceSessionSummaries", "intelligenceTabNames", "intelligenceCommitMessages",
                    "intelligenceAnnouncementShown"] {
            XCTAssertFalse(SettingsSync.portableKeys.contains(key), key)
        }
    }

    @MainActor
    func testDisabledFeaturesNeverAsk() async {
        let saved = SettingsStore.shared.settings
        defer { SettingsStore.shared.settings = saved }
        SettingsStore.shared.settings = AppSettings()
        let names = await Intelligence.branchNames(for: "fix the login redirect", recentBranches: [], existing: [])
        XCTAssertEqual(names, [])
        let fix = await Intelligence.commandFix(command: "git psuh", exitCode: 1, output: "not a git command", directory: "~", branch: nil)
        XCTAssertNil(fix)
    }
}
