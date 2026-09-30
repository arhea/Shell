import XCTest
@testable import Shell

@MainActor
final class AutomationTests: XCTestCase {
    func testWaiterResumesOnMatchingEventOnly() async throws {
        let waiters = SessionWaiters()
        let id = UUID()
        let task = Task { @MainActor in
            try await waiters.wait(on: id, timeout: 5) { event -> String? in
                guard case .agent(_, let name, let message) = event, name == "needs-input" else { return nil }
                return message
            }
        }
        await Task.yield()
        waiters.notify(id, .agent(.claude, event: "working", message: nil))
        waiters.notify(UUID(), .agent(.claude, event: "needs-input", message: "other session"))
        XCTAssertEqual(waiters.pendingCount, 1)
        waiters.notify(id, .agent(.claude, event: "needs-input", message: "Approve edit?"))
        let message = try await task.value
        XCTAssertEqual(message, "Approve edit?")
        XCTAssertEqual(waiters.pendingCount, 0)
    }

    func testWaiterTimesOut() async {
        let waiters = SessionWaiters()
        do {
            _ = try await waiters.wait(on: UUID(), timeout: 0) { _ in true }
            XCTFail("expected a timeout")
        } catch AutomationError.timedOut {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(waiters.pendingCount, 0)
    }

    func testWaiterFailsWhenSessionCloses() async {
        let waiters = SessionWaiters()
        let id = UUID()
        let task = Task { @MainActor in try await waiters.wait(on: id, timeout: 5) { _ in true } }
        await Task.yield()
        waiters.notify(id, .closed)
        do {
            _ = try await task.value
            XCTFail("expected sessionClosed")
        } catch AutomationError.sessionClosed {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testRegisterRunsAfterInstallAndCanFail() async {
        let waiters = SessionWaiters()
        let id = UUID()
        // An event fired from `register` must not be missed.
        let value = try? await waiters.wait(on: id, timeout: 5, register: {
            waiters.notify(id, .commandFinished)
        }, match: { event -> Int? in
            if case .commandFinished = event { return 1 }
            return nil
        })
        XCTAssertEqual(value, 1)

        do {
            _ = try await waiters.wait(on: id, timeout: 5, register: { throw AutomationError.busy }) { _ in true }
            XCTFail("expected busy")
        } catch AutomationError.busy {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(waiters.pendingCount, 0)
    }

    func testAgentWaitConditions() {
        XCTAssertTrue(AgentWaitCondition.needsInput.matches("needs-input"))
        XCTAssertFalse(AgentWaitCondition.needsInput.matches("finished"))
        XCTAssertTrue(AgentWaitCondition.finished.matches("ended"))
        XCTAssertTrue(AgentWaitCondition.needsInputOrFinished.matches("needs-input"))
        XCTAssertTrue(AgentWaitCondition.needsInputOrFinished.matches("finished"))
        XCTAssertFalse(AgentWaitCondition.needsInputOrFinished.matches("working"))
    }

    func testAgentStatusEnumMapping() {
        XCTAssertEqual(AgentStatusAppEnum(nil), .none)
        XCTAssertEqual(AgentStatusAppEnum(.working(.codex)), .working)
        XCTAssertEqual(AgentStatusAppEnum(.needsInput(.claude, "?")), .needsInput)
        XCTAssertEqual(AgentStatusAppEnum(.finished(.claude, "done")), .finished)
    }

    func testShellActionsMapToShortcutActions() {
        for action in ShellActionAppEnum.allCases {
            XCTAssertNotNil(action.action, "\(action.rawValue) has no ShortcutAction")
        }
    }

    /// Snapshots written before session IDs were saved still decode.
    func testPaneSnapshotDecodesWithoutSessionID() throws {
        let old = #"{"leafDirectory":"/tmp"}"#.data(using: .utf8)!
        let snap = try JSONDecoder().decode(PaneTreeSnapshot.self, from: old)
        XCTAssertEqual(snap.leafDirectory, "/tmp")
        XCTAssertNil(snap.leafSessionID)

        let id = UUID()
        let roundTrip = try JSONDecoder().decode(
            PaneTreeSnapshot.self, from: JSONEncoder().encode(PaneTreeSnapshot(leafDirectory: "/tmp", leafSessionID: id)))
        XCTAssertEqual(roundTrip.leafSessionID, id)
    }
}
