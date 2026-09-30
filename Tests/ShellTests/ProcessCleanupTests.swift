import XCTest
@testable import Shell

final class ProcessCleanupTests: XCTestCase {
    private func spawn(_ script: String) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try p.run()
        return p
    }

    func testFindsChildrenAndGrandchildren() throws {
        let p = try spawn("sleep 30 & wait")
        defer { kill(p.processIdentifier, SIGKILL) }
        // Give the shell a moment to fork `sleep`.
        var tree: [pid_t] = []
        for _ in 0..<50 where tree.count < 2 {
            usleep(20_000)
            tree = ProcessCleanup.descendants(of: p.processIdentifier)
        }
        XCTAssertEqual(tree.count, 1, "sleep is the shell's only child")
        XCTAssertTrue(ProcessCleanup.descendants(of: getpid()).contains(p.processIdentifier))
        XCTAssertTrue(ProcessCleanup.descendants(of: getpid()).contains(tree[0]))
        tree.forEach { kill($0, SIGKILL) }
    }

    func testTerminateStopsPoliteProcesses() throws {
        let p = try spawn("sleep 30")
        let start = Date()
        ProcessCleanup.terminate([p.processIdentifier], grace: 2)
        p.waitUntilExit()
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5, "SIGTERM is enough; no need to wait out the grace period")
        XCTAssertEqual(p.terminationReason, .uncaughtSignal)
        XCTAssertEqual(p.terminationStatus, SIGTERM)
    }

    func testTerminateKillsProcessesThatIgnoreSIGTERM() throws {
        let p = try spawn("trap '' TERM; while :; do sleep 0.05; done")
        usleep(100_000) // let the trap install
        ProcessCleanup.terminate([p.processIdentifier], grace: 0.3)
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, SIGKILL)
    }

    func testZombieIsNotAlive() throws {
        let p = try spawn("exit 0")
        p.waitUntilExit()
        XCTAssertFalse(ProcessCleanup.isAlive(p.processIdentifier))
    }
}
