import AppKit
import XCTest
@testable import Shell

/// Regression tests for leaks and crashes found in the #51 review.
@MainActor
final class LeakAndCrashRegressionTests: XCTestCase {
    func testMainMenuCanBeInstalledAgain() {
        // Changing a shortcut rebuilds the menu bar; the shared update item
        // must move to the new Help menu instead of raising.
        MainMenu.install()
        MainMenu.install()
        XCTAssertTrue(NSApp.helpMenu?.items.contains(UpdateMenuItem.shared) == true)
    }

    func testBranchChecksModelFollowsANewRepositoryInstance() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("checks-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = ProcessInfo.processInfo.environment
        _ = await GitRepository.run(GitRepository.findGit(environment: env), ["init", "-q"], in: dir.path)

        let first_ = await GitRepository.discover(from: dir.path, environment: env)
        let first = try XCTUnwrap(first_)
        let a = BranchChecksModel.shared(for: first)
        XCTAssertTrue(BranchChecksModel.shared(for: first) === a)
        first.stop()

        // Leaving and coming back yields a fresh repository; the model must
        // not keep polling through the stopped one.
        let second_ = await GitRepository.discover(from: dir.path, environment: env)
        let second = try XCTUnwrap(second_)
        defer { second.stop() }
        XCTAssertFalse(first === second)
        let b = BranchChecksModel.shared(for: second)
        XCTAssertTrue(a === b, "the model is rebound, keeping its observers")
        XCTAssertTrue(b.repository === second)
    }

    func testStaleScratchFilesAreRemoved() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ShellSnippets", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("snippet-test-old-\(UUID().uuidString).sh")
        let fresh = dir.appendingPathComponent("snippet-test-new-\(UUID().uuidString).sh")
        try Data("echo old\n".utf8).write(to: old)
        try Data("echo new\n".utf8).write(to: fresh)
        defer { try? fm.removeItem(at: fresh) }
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86400)], ofItemAtPath: old.path)

        AppDelegate.removeStaleScratchFiles()

        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertTrue(fm.fileExists(atPath: fresh.path))
    }
}
