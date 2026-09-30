import XCTest
@testable import Shell

final class ProcessRunnerTests: XCTestCase {
    /// Reading stdout to EOF before stderr used to hang once stderr passed the ~64 KB pipe buffer.
    func testLargeOutputOnBothStreamsDoesNotDeadlock() async {
        let script = "head -c 300000 /dev/zero | tr '\\\\0' e >&2; head -c 300000 /dev/zero | tr '\\\\0' o"
        let r = await ProcessRunner.run("/bin/sh", ["-c", script], timeout: 20)
        XCTAssertTrue(r.succeeded)
        XCTAssertEqual(r.stdout.count, 300_000)
        XCTAssertEqual(r.stderr.count, 300_000)
    }

    func testTimeoutKillsTheProcess() async {
        let start = Date()
        let r = await ProcessRunner.run("/bin/sleep", ["30"], timeout: 0.5)
        XCTAssertTrue(r.timedOut)
        XCTAssertFalse(r.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testMissingExecutable() async {
        let r = await ProcessRunner.run("/nonexistent/tool", [])
        XCTAssertEqual(r.status, -1)
        XCTAssertFalse(r.succeeded)
    }

    /// A background job that inherits stdout (like one started from .zshrc)
    /// used to keep the pipe open, so the run never finished.
    func testInheritedPipeDoesNotHangAfterExit() async {
        let start = Date()
        let r = await ProcessRunner.run("/bin/sh", ["-c", "echo hi; (sleep 30 &)"], timeout: 20)
        XCTAssertTrue(r.succeeded)
        XCTAssertEqual(String(decoding: r.stdout, as: UTF8.self), "hi\n")
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testTimeoutKillsAProcessIgnoringSIGTERM() async {
        let start = Date()
        let r = await ProcessRunner.run("/bin/sh", ["-c", "trap '' TERM; sleep 30"], timeout: 0.5)
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 15)
    }
}
