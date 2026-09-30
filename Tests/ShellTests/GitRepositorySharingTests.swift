import XCTest
@testable import Shell

@MainActor
final class GitRepositorySharingTests: XCTestCase {
    func testOneInstancePerCheckoutReleasedByLastHolder() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitshare-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let git = GitRepository.findGit(environment: ProcessInfo.processInfo.environment)
        _ = await GitRepository.run(git, ["init", "-q"], in: dir.path)

        let env = ProcessInfo.processInfo.environment
        let a_ = await GitRepository.discover(from: dir.path, environment: env)
        let a = try XCTUnwrap(a_)
        let b_ = await GitRepository.discover(from: dir.appendingPathComponent("sub").path, environment: env)
        let b = try XCTUnwrap(b_)
        XCTAssertTrue(a === b, "the same checkout should share one watcher")

        a.stop()   // one holder left
        let c_ = await GitRepository.discover(from: dir.path, environment: env)
        let c = try XCTUnwrap(c_)
        XCTAssertTrue(c === b)
        b.stop()
        c.stop()   // last holder: released
        let d_ = await GitRepository.discover(from: dir.path, environment: env)
        let d = try XCTUnwrap(d_)
        XCTAssertFalse(d === a, "a released checkout gets a fresh instance")
        d.stop()
    }
}
