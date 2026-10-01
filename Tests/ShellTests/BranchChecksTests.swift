import XCTest
@testable import Shell

final class BranchChecksTests: XCTestCase {
    private let prView = """
    {"number":39,"url":"https://github.com/arhea/Shell/pull/39","headRefOid":"74c838f0000",
     "statusCheckRollup":[
      {"__typename":"CheckRun","name":"lint","workflowName":"Lint","status":"COMPLETED","conclusion":"SUCCESS",
       "startedAt":"2026-10-01T15:00:00Z","completedAt":"2026-10-01T15:00:32Z",
       "detailsUrl":"https://github.com/arhea/Shell/actions/runs/100/job/201"},
      {"__typename":"CheckRun","name":"Build and test","workflowName":"Test","status":"COMPLETED","conclusion":"FAILURE",
       "startedAt":"2026-10-01T15:00:00Z","completedAt":"2026-10-01T15:04:02Z",
       "detailsUrl":"https://github.com/arhea/Shell/actions/runs/101/job/202"},
      {"__typename":"CheckRun","name":"CodeQL","workflowName":"CodeQL","status":"IN_PROGRESS","conclusion":"",
       "startedAt":"2026-10-01T15:00:00Z","detailsUrl":"https://github.com/arhea/Shell/actions/runs/102/job/203"},
      {"__typename":"CheckRun","name":"Notarize","workflowName":"Release","status":"COMPLETED","conclusion":"SKIPPED",
       "detailsUrl":"https://github.com/arhea/Shell/actions/runs/103/job/204"},
      {"__typename":"StatusContext","context":"danger","state":"SUCCESS","description":"PR checks passed",
       "targetUrl":"https://example.com/danger"}
     ]}
    """

    func testParsesAndSortsFailingFirst() throws {
        let snap = try XCTUnwrap(BranchChecksModel.parse(prView: prView, branch: "bug/38"))
        XCTAssertEqual(snap.prNumber, 39)
        XCTAssertEqual(snap.headSHA, "74c838f0000")
        XCTAssertEqual(snap.jobs.map(\.name), ["Build and test", "CodeQL", "danger", "lint", "Notarize"])
        XCTAssertEqual(snap.failing.count, 1)
        XCTAssertEqual(snap.running.count, 1)
        XCTAssertEqual(snap.passed.count, 2)
        XCTAssertEqual(snap.skipped.count, 1)
        XCTAssertEqual(snap.overall, .failed)
        XCTAssertEqual(snap.summary, "1 check failing")
    }

    func testCheckRunIDsAndDuration() throws {
        let snap = try XCTUnwrap(BranchChecksModel.parse(prView: prView, branch: "b"))
        let build = try XCTUnwrap(snap.jobs.first { $0.name == "Build and test" })
        XCTAssertEqual(build.runID, 101)
        XCTAssertEqual(build.jobID, 202)
        XCTAssertEqual(build.id, "202")
        XCTAssertEqual(build.workflow, "Test")
        XCTAssertEqual(try XCTUnwrap(build.duration), 242, accuracy: 0.5)
        let danger = try XCTUnwrap(snap.jobs.first { $0.name == "danger" })
        XCTAssertNil(danger.runID)
        XCTAssertEqual(danger.detail, "PR checks passed")
    }

    func testSummaryStates() {
        func snap(_ states: [CheckJob.State]) -> BranchChecksSnapshot {
            BranchChecksSnapshot(branch: "b", updatedAt: Date(), jobs: states.enumerated().map {
                CheckJob(id: "\($0.offset)", name: "j\($0.offset)", state: $0.element)
            })
        }
        XCTAssertEqual(snap([]).summary, "No checks")
        XCTAssertNil(snap([]).overall)
        XCTAssertEqual(snap([.failed, .failed]).summary, "2 checks failing")
        XCTAssertEqual(snap([.running, .passed]).summary, "1 running")
        XCTAssertEqual(snap([.running, .passed]).overall, .running)
        XCTAssertEqual(snap([.passed, .passed]).summary, "2 passed")
    }

    func testApplyStepsSetsFailingDetail() {
        var job = CheckJob(id: "202", name: "Build and test", state: .failed, jobID: 202)
        let json = """
        {"workflow_name":"Test","steps":[
          {"name":"Checkout, cache, build","status":"completed","conclusion":"success",
           "started_at":"2026-10-01T15:00:00Z","completed_at":"2026-10-01T15:03:14Z"},
          {"name":"Run tests","status":"completed","conclusion":"failure",
           "started_at":"2026-10-01T15:03:14Z","completed_at":"2026-10-01T15:03:55Z"},
          {"name":"Upload results","status":"completed","conclusion":"skipped"}]}
        """
        BranchChecksModel.applySteps(json, to: &job)
        XCTAssertEqual(job.steps.map(\.state), [.passed, .failed, .skipped])
        XCTAssertEqual(job.detail, "Failed at step Run tests")
        XCTAssertEqual(job.workflow, "Test")
        XCTAssertEqual(job.steps[1].duration ?? 0, 41, accuracy: 0.5)
    }

    func testApplyStepsRunningDetail() {
        var job = CheckJob(id: "1", name: "CodeQL", state: .running, jobID: 1)
        BranchChecksModel.applySteps("""
        {"steps":[{"name":"a","status":"completed","conclusion":"success"},{"name":"b","status":"in_progress"},{"name":"c","status":"queued"}]}
        """, to: &job)
        XCTAssertEqual(job.detail, "Running · step 2 of 3")
    }

    func testActionsIDs() {
        let ids = BranchChecksModel.actionsIDs(from: URL(string: "https://github.com/o/r/actions/runs/5/job/9")!)
        XCTAssertEqual(ids.run, 5)
        XCTAssertEqual(ids.job, 9)
        let none = BranchChecksModel.actionsIDs(from: URL(string: "https://example.com/x")!)
        XCTAssertNil(none.run)
        XCTAssertNil(none.job)
    }

    func testTrimLogStripsPrefixesAndANSI() {
        let raw = "Build and test\tRun tests\t2026-10-01T15:03:20.1234567Z \u{1B}[31merror:\u{1B}[0m boom\n"
            + "Build and test\tRun tests\t2026-10-01T15:03:21.0000000Z Executed 211 tests"
        XCTAssertEqual(BranchChecksModel.trimLog(raw), "error: boom\nExecuted 211 tests")
    }

    func testTrimLogKeepsLastLines() {
        let raw = (1...10).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(BranchChecksModel.trimLog(raw, maxLines: 3), "line 8\nline 9\nline 10")
    }

    func testInvalidJSON() {
        XCTAssertNil(BranchChecksModel.parse(prView: "nope", branch: "b"))
    }
}
