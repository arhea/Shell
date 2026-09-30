import XCTest
@testable import Shell

final class ClaudeTrustWriteTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("trust-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testTrustKeepsTheRestOfTheConfig() throws {
        let config = dir.appendingPathComponent(".claude.json")
        let original: [String: Any] = [
            "numStartups": 42,
            "projects": ["/other": ["hasTrustDialogAccepted": true, "allowedTools": ["Bash"]],
                         "/repo": ["lastCost": 1.5]],
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: config)
        XCTAssertFalse(ClaudeTrust.isTrusted("/repo/src", configURL: config))

        try ClaudeTrust.trust("/repo", configURL: config)

        XCTAssertTrue(ClaudeTrust.isTrusted("/repo/src", configURL: config))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        XCTAssertEqual(saved["numStartups"] as? Int, 42)
        let projects = try XCTUnwrap(saved["projects"] as? [String: Any])
        XCTAssertEqual((projects["/repo"] as? [String: Any])?["lastCost"] as? Double, 1.5)
        XCTAssertEqual((projects["/other"] as? [String: Any])?["allowedTools"] as? [String], ["Bash"])
    }

    func testRefusesToOverwriteAnUnreadableConfig() throws {
        let config = dir.appendingPathComponent(".claude.json")
        try Data("{ not json".utf8).write(to: config)
        XCTAssertThrowsError(try ClaudeTrust.trust("/repo", configURL: config))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "{ not json")
    }

    func testFindsTheMainCheckoutOfAWorktree() throws {
        let main = dir.appendingPathComponent("repo")
        let wt = dir.appendingPathComponent("worktrees/repo/bug-1")
        try FileManager.default.createDirectory(at: main.appendingPathComponent(".git/worktrees/bug-1"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wt.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "gitdir: \(main.path)/.git/worktrees/bug-1\n".write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        XCTAssertEqual(ClaudeTrust.worktreeRoot(containing: wt.appendingPathComponent("src").path), wt.path)
        XCTAssertEqual(ClaudeTrust.mainCheckout(ofWorktree: wt.path), main.path)
        XCTAssertNil(ClaudeTrust.worktreeRoot(containing: main.path)) // the main checkout isn't a linked worktree
    }
}
