import XCTest
@testable import Shell

final class ClaudeRunningSessionsTests: XCTestCase {
    func testParsesInteractiveAndBackgroundSessions() {
        let json = """
        [
          {"pid": 4434, "cwd": "/Users/me/code/shell", "kind": "interactive", "startedAt": 1790712112855,
           "sessionId": "c66f4b93-372b-4cd8-a58f-f4c1a69c3ba8", "name": "Dashboard", "status": "waiting",
           "waitingFor": "permission prompt"},
          {"pid": 501, "id": "brisk-wren", "cwd": "/Users/me/code/api", "kind": "background", "startedAt": 1790712000000,
           "sessionId": "dd038909-f9ec-4ab9-b15c-4fd1fcc7743f", "status": "busy", "state": "working"},
          {"id": "", "cwd": "/Users/me", "kind": "background", "startedAt": 1},
          {"pid": 9, "cwd": "/Users/me", "kind": "something-new", "startedAt": 1}
        ]
        """
        let sessions = ClaudeRunningSession.parse(Data(json.utf8))
        XCTAssertEqual(sessions.count, 2)

        let interactive = sessions[0]
        XCTAssertEqual(interactive.kind, .interactive)
        XCTAssertFalse(interactive.canAttach)
        XCTAssertNil(interactive.attachCommand)
        XCTAssertEqual(interactive.pid, 4434)
        XCTAssertEqual(interactive.name, "Dashboard")
        XCTAssertEqual(interactive.waitingFor, "permission prompt")
        XCTAssertEqual(interactive.startedAt, Date(timeIntervalSince1970: 1790712112.855))
        XCTAssertEqual(interactive.id, "c66f4b93-372b-4cd8-a58f-f4c1a69c3ba8")

        let background = sessions[1]
        XCTAssertEqual(background.kind, .background(jobID: "brisk-wren"))
        XCTAssertTrue(background.canAttach)
        XCTAssertEqual(background.attachCommand, "claude attach brisk-wren")
        XCTAssertEqual(background.state, "working")
        XCTAssertEqual(background.id, "job:brisk-wren")
    }

    func testRejectsMalformedOutput() {
        XCTAssertEqual(ClaudeRunningSession.parse(Data("error: unknown command".utf8)), [])
        XCTAssertEqual(ClaudeRunningSession.parse(Data("{}".utf8)), [])
    }

    func testRefusesUnsafeJobIDs() {
        let session = ClaudeRunningSession(kind: .background(jobID: "x; rm -rf ~"), directory: "/", startedAt: .now)
        XCTAssertNil(session.attachCommand)
    }

    func testFindsAttachedJobInCommandLine() {
        XCTAssertEqual(ClaudeRunningSession.attachedJob(in: "claude attach brisk-wren"), "brisk-wren")
        XCTAssertEqual(ClaudeRunningSession.attachedJob(in: "/opt/homebrew/bin/claude attach 'brisk-wren'"), "brisk-wren")
        XCTAssertNil(ClaudeRunningSession.attachedJob(in: "claude --resume abc"))
        XCTAssertNil(ClaudeRunningSession.attachedJob(in: "git attach foo"))
        XCTAssertNil(ClaudeRunningSession.attachedJob(in: "claude attach"))
    }

    func testProcessTree() {
        let me = getpid()
        XCTAssertTrue(ProcessTree.isDescendant(me, of: me))
        XCTAssertTrue(ProcessTree.isDescendant(me, of: getppid()))
        XCTAssertFalse(ProcessTree.isDescendant(getppid(), of: me))
        XCTAssertFalse(ProcessTree.isDescendant(1, of: me))
    }
}
