import XCTest
@testable import Shell

@MainActor
final class AgentLauncherTests: XCTestCase {
    private let info = AgentLauncher.RepoInfo(toplevel: "/Users/me/code/Shell", repoName: "Shell", baseRemote: "origin", baseBranch: "main")
    private let root = "/Users/me/code/worktrees"

    func testNewBranchFromDefaultBranch() {
        let plan = AgentLauncher.plan(info: info, branch: "eng-42", name: "ENG-42", agent: .claude, worktreeRoot: root,
                                      branchExists: false, existingWorktree: nil, pathTaken: { _ in false })
        XCTAssertEqual(plan.directory, "/Users/me/code/Shell")
        XCTAssertEqual(plan.command, "git fetch origin main; git worktree add --no-track -b eng-42 /Users/me/code/worktrees/Shell/eng-42 origin/main && cd /Users/me/code/worktrees/Shell/eng-42 && claude -n ENG-42")
    }

    func testExistingBranchAndWorktree() {
        let existing = AgentLauncher.plan(info: info, branch: "eng-42", name: "ENG-42", agent: .claude, worktreeRoot: root,
                                          branchExists: true, existingWorktree: nil, pathTaken: { $0.hasSuffix("/eng-42") })
        XCTAssertEqual(existing.command, "git worktree add /Users/me/code/worktrees/Shell/eng-42-2 eng-42 && cd /Users/me/code/worktrees/Shell/eng-42-2 && claude -n ENG-42")

        let reuse = AgentLauncher.plan(info: info, branch: "eng-42", name: "ENG-42", agent: .claude, worktreeRoot: root,
                                       branchExists: true, existingWorktree: "/tmp/wt", pathTaken: { _ in false })
        XCTAssertEqual(reuse, AgentLauncher.Plan(directory: "/tmp/wt", command: "claude -n ENG-42", name: "ENG-42"))
    }

    func testLocalBaseWithoutRemote() {
        var local = info
        local.baseRemote = nil
        let plan = AgentLauncher.plan(info: local, branch: "swift-otter", name: "swift-otter", agent: .claude, worktreeRoot: root,
                                      branchExists: false, existingWorktree: nil, pathTaken: { _ in false })
        XCTAssertTrue(plan.command.hasPrefix("git worktree add -b swift-otter /Users/me/code/worktrees/Shell/swift-otter main && cd "))
    }

    func testBranchNames() {
        XCTAssertEqual(AgentLauncher.branchName(from: "feat/login"), "feat/login")
        XCTAssertEqual(AgentLauncher.branchName(from: "  fix the login bug "), "fix-the-login-bug")
        XCTAssertNil(AgentLauncher.branchName(from: ""))
        XCTAssertNil(AgentLauncher.branchName(from: "-x"))
        XCTAssertNil(AgentLauncher.branchName(from: "a..b"))
        XCTAssertNil(AgentLauncher.branchName(from: "feat/"))
        XCTAssertNil(AgentLauncher.branchName(from: "wip:thing"))
        XCTAssertNil(AgentLauncher.branchName(from: "x.lock"))
        XCTAssertNil(AgentLauncher.branchName(from: "feat/.hidden"))
    }

    func testQuotingAndNames() {
        XCTAssertEqual(AgentLauncher.shellQuote("eng-42"), "eng-42")
        XCTAssertEqual(AgentLauncher.shellQuote("it's here"), "'it'\\''s here'")
        XCTAssertEqual(AgentLauncher.shellPath("/Users/me/My Worktrees/x", home: "/Users/me"), "~/'My Worktrees/x'")
        XCTAssertEqual(AgentLauncher.shellPath("/Users/me/code/x", home: "/Users/me"), "~/code/x")
        XCTAssertNotNil(AgentLauncher.randomName().wholeMatch(of: /[a-z]+-[a-z]+/))
    }

    func testRemoteOnlyBranchIsTracked() {
        let plan = AgentLauncher.plan(info: info, branch: "feat/login", name: "feat/login", agent: .claude, worktreeRoot: root,
                                      branchExists: false, existingWorktree: nil, trackRemote: "origin", pathTaken: { _ in false })
        XCTAssertEqual(plan.command, "git worktree add --track -b feat/login /Users/me/code/worktrees/Shell/feat-login origin/feat/login && cd /Users/me/code/worktrees/Shell/feat-login && claude -n feat/login")
    }

    func testBranchListMergesLocalAndRemote() {
        let refs = [
            "refs/heads/main\t1700000300\tRelease 1.2",
            "refs/heads/feat/login\t1700000100\tAdd login",
            "refs/remotes/origin/HEAD\t1700000300\tRelease 1.2",
            "refs/remotes/origin/main\t1700000300\tRelease 1.2",
            "refs/remotes/origin/fix/crash\t1700000200\tFix crash\twith a tab",
            "refs/remotes/upstream/fix/crash\t1700000000\tOlder",
        ].joined(separator: "\n")
        let worktrees = [WorktreeInfo(path: "/wt/login", branch: "feat/login")]
        let list = BranchOption.parse(refs: refs, worktrees: worktrees, defaultBranch: "main")
        XCTAssertEqual(list.map(\.id), ["main", "origin/fix/crash", "feat/login"])
        XCTAssertEqual(list[0].isDefault, true)
        XCTAssertEqual(list[1].remote, "origin")
        XCTAssertEqual(list[1].subject, "Fix crash\twith a tab")
        XCTAssertEqual(list[2].worktreePath, "/wt/login")
    }

    func testPermissionModeFlag() {
        XCTAssertEqual(CodingAgent.claude.command(name: "swift-otter", permissionMode: "auto"), "claude -n swift-otter --permission-mode auto")
        XCTAssertEqual(CodingAgent.claude.command(name: "swift-otter", permissionMode: ""), "claude -n swift-otter")
        XCTAssertEqual(CodingAgent.claude.command(name: "swift-otter"), "claude -n swift-otter")
        let plan = AgentLauncher.plan(info: info, branch: "x", name: "x", agent: .claude, permissionMode: "plan", worktreeRoot: root,
                                      branchExists: false, existingWorktree: "/tmp/wt", pathTaken: { _ in false })
        XCTAssertEqual(plan.command, "claude -n x --permission-mode plan")
    }
}
