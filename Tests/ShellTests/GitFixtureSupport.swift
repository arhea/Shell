import AppKit
import SwiftUI
import XCTest
@testable import Shell

// Shared fixtures for the Git, worktree, GitHub and right sidebar tests:
// hermetic throwaway repositories and a fake `gh`. Nothing here touches the
// user's repositories, their git config, the network or the real `gh`.

/// Runs git hermetically (no global or system config, temp HOME) in `dir`.
@discardableResult
func gitFixture(_ args: [String], in dir: URL, env extra: [String: String] = [:], allowFailure: Bool = false,
                file: StaticString = #filePath, line: UInt = #line) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-c", "user.name=Shell Tests", "-c", "user.email=tests@example.com", "-c", "commit.gpgsign=false",
                   "-c", "init.defaultBranch=main", "-c", "core.hooksPath=/dev/null"] + args
    p.currentDirectoryURL = dir
    var env = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "HOME": dir.path, "PATH": "/usr/bin:/bin",
               "GIT_TERMINAL_PROMPT": "0"]
    for (k, v) in extra { env[k] = v }
    p.environment = env
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    if p.terminationStatus != 0 && !allowFailure {
        XCTFail("git \(args.joined(separator: " ")) failed: \(String(decoding: errData, as: UTF8.self))", file: file, line: line)
    }
    return String(decoding: data, as: UTF8.self)
}

func gitFixtureWrite(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

/// A repository in a temp folder with one commit on `main`. `base` holds the
/// checkout (`repo/`) and room for worktrees and remotes beside it.
struct GitFixtureRepo {
    let base: URL
    let root: URL

    init(in parent: URL, name: String = "repo") throws {
        base = parent
        root = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q"])
        try gitFixtureWrite("# Fixture\n", to: root.appendingPathComponent("README.md"))
        try git(["add", "-A"])
        try git(["commit", "-q", "-m", "Initial commit"])
    }

    @discardableResult
    func git(_ args: [String], in dir: URL? = nil, env: [String: String] = [:], allowFailure: Bool = false,
             file: StaticString = #filePath, line: UInt = #line) throws -> String {
        try gitFixture(args, in: dir ?? root, env: env, allowFailure: allowFailure, file: file, line: line)
    }

    func write(_ text: String, _ path: String, in dir: URL? = nil) throws {
        try gitFixtureWrite(text, to: (dir ?? root).appendingPathComponent(path))
    }

    func commit(_ message: String, file: String = "file.txt", in dir: URL? = nil, date: String? = nil) throws {
        try write(message + "\n", file, in: dir)
        try git(["add", "-A"], in: dir)
        let env = date.map { ["GIT_COMMITTER_DATE": $0, "GIT_AUTHOR_DATE": $0] } ?? [:]
        try git(["commit", "-q", "-m", message], in: dir, env: env)
    }

    func head(in dir: URL? = nil) throws -> String {
        try git(["rev-parse", "HEAD"], in: dir).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Adds a linked worktree on a new branch at `base/<name>`.
    @discardableResult
    func addWorktree(_ name: String, branch: String? = nil) throws -> URL {
        let path = base.appendingPathComponent(name, isDirectory: true)
        if let branch {
            try git(["worktree", "add", "-q", "-b", branch, path.path])
        } else {
            try git(["worktree", "add", "-q", "--detach", path.path])
        }
        return path
    }

    /// Points `origin` at a GitHub URL and fakes a remote-tracking `main`
    /// (no network: the refs are written locally).
    func fakeGitHubOrigin(_ url: String = "git@github.com:acme/widgets.git") throws {
        try git(["remote", "add", "origin", url])
        try git(["update-ref", "refs/remotes/origin/main", head()])
        try git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        try git(["config", "branch.main.remote", "origin"])
        try git(["config", "branch.main.merge", "refs/heads/main"])
    }

    /// Makes `branch` track `origin/<branch>` at `commit` (nil: an upstream that's gone).
    func track(_ branch: String, at commit: String?) throws {
        if let commit { try git(["update-ref", "refs/remotes/origin/\(branch)", commit]) }
        try git(["config", "branch.\(branch).remote", "origin"])
        try git(["config", "branch.\(branch).merge", "refs/heads/\(branch)"])
    }

    /// Ages a worktree's last activity: its commit date is passed in at commit
    /// time; this backdates its index and HEAD files.
    func backdateGitFiles(of worktree: URL, by days: Double) throws {
        let gitDir = try git(["rev-parse", "--absolute-git-dir"], in: worktree).trimmingCharacters(in: .whitespacesAndNewlines)
        let date = Date().addingTimeInterval(-days * 86400)
        for f in ["index", "HEAD"] {
            let path = gitDir + "/" + f
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
            }
        }
    }
}

/// A stand-in `gh`: a zsh script answering by rules matched against its
/// arguments, first match wins. Each rule is a zsh glob over `"$*"` plus the
/// stdout, stderr and exit status to answer with. Every call is logged.
struct FakeGH {
    let dir: URL
    private let rules: URL
    var path: String { dir.appendingPathComponent("gh").path }

    init(in parent: URL) throws {
        dir = parent.appendingPathComponent("fake-gh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        rules = dir.appendingPathComponent("rules", isDirectory: true)
        try FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true)
        let script = #"""
        #!/bin/zsh -f
        dir=${0:A:h}
        print -r -- "$*" >> $dir/calls.log
        for rule in $dir/rules/*(N/); do
          pat=$(<$rule/pattern)
          if [[ "$*" == ${~pat} ]]; then
            [[ -f $rule/stdout ]] && print -rn -- "$(<$rule/stdout)"
            [[ -f $rule/stderr ]] && print -rn -- "$(<$rule/stderr)" >&2
            [[ -f $rule/sleep ]] && sleep $(<$rule/sleep)
            exit ${$(<$rule/status):-0}
          fi
        done
        print -r -- "fake gh: no rule for: $*" >&2
        exit 1
        """#
        try script.write(to: dir.appendingPathComponent("gh"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    /// Adds a rule; earlier rules win.
    func on(_ pattern: String, stdout: String = "", stderr: String = "", status: Int32 = 0, sleep: Double? = nil) throws {
        let count = (try? FileManager.default.contentsOfDirectory(atPath: rules.path).count) ?? 0
        let rule = rules.appendingPathComponent(String(format: "%04d", count), isDirectory: true)
        try FileManager.default.createDirectory(at: rule, withIntermediateDirectories: true)
        try pattern.write(to: rule.appendingPathComponent("pattern"), atomically: true, encoding: .utf8)
        try stdout.write(to: rule.appendingPathComponent("stdout"), atomically: true, encoding: .utf8)
        try stderr.write(to: rule.appendingPathComponent("stderr"), atomically: true, encoding: .utf8)
        try "\(status)".write(to: rule.appendingPathComponent("status"), atomically: true, encoding: .utf8)
        if let sleep { try "\(sleep)".write(to: rule.appendingPathComponent("sleep"), atomically: true, encoding: .utf8) }
    }

    func on(_ pattern: String, json: Any, status: Int32 = 0) throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        try on(pattern, stdout: String(decoding: data, as: UTF8.self), status: status)
    }

    /// Drops every rule (for a test that changes the answers midway).
    func reset() throws {
        try FileManager.default.removeItem(at: rules)
        try FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true)
    }

    var calls: [String] {
        ((try? String(contentsOf: dir.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func calls(matching prefix: String) -> [String] { calls.filter { $0.hasPrefix(prefix) } }

    /// The environment the code under test gets: the fake first on PATH, no
    /// user git config.
    func environment(home: URL) -> [String: String] {
        ["PATH": "\(dir.path):/usr/bin:/bin", "HOME": home.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
         "GIT_TERMINAL_PROMPT": "0"]
    }
}

/// Base class for this area's tests: tool lookups never fall back to Homebrew
/// (so the real `gh` is never found), and git run by the code under test
/// ignores the user's global and system config.
@MainActor
class GitAreaTestCase: XCTestCase {
    private var savedFallbacks: [String] = []
    private var savedEnv: [String: String?] = [:]
    private var savedSettings: AppSettings?

    override func setUp() async throws {
        try await super.setUp()
        savedFallbacks = GitRepository.fallbackSearchDirectories
        GitRepository.fallbackSearchDirectories = ["/usr/bin"]
        for (k, v) in ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"] {
            savedEnv[k] = ProcessInfo.processInfo.environment[k]
            setenv(k, v, 1)
        }
        savedSettings = SettingsStore.shared.settings
    }

    override func tearDown() async throws {
        GitRepository.fallbackSearchDirectories = savedFallbacks
        for (k, v) in savedEnv {
            if let v { setenv(k, v, 1) } else { unsetenv(k) }
        }
        if let savedSettings { SettingsStore.shared.settings = savedSettings }
        try await super.tearDown()
    }

    /// Polls (letting main-actor work run) until `condition` holds.
    func eventually(timeout: TimeInterval = 5, _ message: String = "condition", file: StaticString = #filePath, line: UInt = #line,
                    _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(message)", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A temp folder (symlinks resolved, so it matches what git reports).
    func gitTempDirectory() throws -> URL {
        let url = try makeTemporaryDirectory()
        guard let real = realpath(url.path, nil) else { return url }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real), isDirectory: true)
    }
}

// MARK: - Pressing controls by position

/// The window's focusable controls' frames, in the host's (top-left) coordinates.
@MainActor
func gitControlFrames<V: View>(_ w: ClaudeViewWindow<V>) -> [CGRect] {
    w.controls().map { $0.convert($0.bounds, to: w.host) }
}

/// Presses the `n`th control (in `order`) among those whose frame passes `filter`.
@MainActor
@discardableResult
func gitPress<V: View>(_ w: ClaudeViewWindow<V>, at n: Int = 0, file: StaticString = #filePath, line: UInt = #line,
                       sortedBy order: (CGRect, CGRect) -> Bool = { abs($0.minY - $1.minY) > 2 ? $0.minY < $1.minY : $0.minX < $1.minX },
                       _ filter: (CGRect) -> Bool) -> Bool {
    let frames = gitControlFrames(w)
    let picked = frames.indices.filter { filter(frames[$0]) }.sorted { order(frames[$0], frames[$1]) }
    guard picked.indices.contains(n) else {
        XCTFail("no control \(n) matching; frames: \(frames)", file: file, line: line)
        return false
    }
    w.press(picked[n], file: file, line: line)
    return true
}

/// Clicks segment `index` of the `nth` segmented control with `segments` segments.
@MainActor
func gitClickSegment<V: View>(_ w: ClaudeViewWindow<V>, _ index: Int, segments: Int, nth: Int = 0,
                              file: StaticString = #filePath, line: UInt = #line, where filter: (CGRect) -> Bool = { _ in true }) {
    func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
    let matching = all(w.host).compactMap { $0 as? NSSegmentedControl }
        .filter { $0.segmentCount == segments && filter($0.convert($0.bounds, to: w.host)) }
    guard matching.indices.contains(nth) else { return XCTFail("no segmented control with \(segments) segments", file: file, line: line) }
    let seg = matching[nth]
    let r = seg.convert(seg.bounds, to: w.host)
    let width = r.width / CGFloat(segments)
    w.click(x: r.minX + width * (CGFloat(index) + 0.5), y: r.midY)
    w.layout(settle: 0.02)
}

/// Builders for GitHub values.
enum GitFixturePR {
    static func open(_ number: Int, title: String? = nil, head: String? = nil, base: String = "main", author: String = "octocat",
                     bot: Bool = false, draft: Bool = false, decision: String? = nil, checks: OpenPullRequest.Checks = .passing,
                     summary: String = "1 passing", requested: [String] = [], reviews: [OpenPullRequest.Review] = [],
                     unresolved: Int = 0, labels: [(name: String, color: String)] = [], failedRunIDs: [Int] = [],
                     updated: Date? = Date(timeIntervalSinceNow: -3600), fork: Bool = false) -> OpenPullRequest {
        OpenPullRequest(
            number: number, title: title ?? "Pull request \(number)", url: URL(string: "https://github.com/acme/widgets/pull/\(number)")!,
            isDraft: draft, head: head ?? "feature-\(number)", base: base, author: author, authorIsBot: bot,
            reviewDecision: decision, updatedAt: updated, additions: 10 * number, deletions: number,
            isCrossRepository: fork, labels: labels, checks: checks, checksSummary: summary, reviewRequestedLogins: requested,
            reviews: reviews, unresolvedThreads: unresolved, failedRunIDs: failedRunIDs)
    }

    static func info(_ number: Int, state: PullRequestInfo.State = .open, draft: Bool = false, review: String? = nil,
                     headOID: String? = nil) -> PullRequestInfo {
        PullRequestInfo(number: number, title: "PR \(number)", url: URL(string: "https://github.com/acme/widgets/pull/\(number)")!,
                        state: state, isDraft: draft, reviewDecision: review, headOID: headOID)
    }

    /// A `gh pr list --json …` entry (the Worktrees sidebar's lookup).
    static func listEntry(_ number: Int, branch: String, state: String = "OPEN", draft: Bool = false, review: String = "",
                          oid: String? = nil) -> [String: Any] {
        var o: [String: Any] = ["number": number, "title": "PR \(number)", "url": "https://github.com/acme/widgets/pull/\(number)",
                                "state": state, "isDraft": draft, "headRefName": branch, "reviewDecision": review]
        if let oid { o["headRefOid"] = oid }
        return o
    }

    /// A GraphQL board node.
    static func node(_ number: Int, head: String, base: String = "main", author: String = "octocat", draft: Bool = false,
                     decision: String? = nil, checks: [[String: Any]] = [], reviews: [[String: Any]] = [],
                     requested: [[String: Any]] = [], threads: [Bool] = [], updated: String = "2026-09-30T10:00:00Z",
                     typename: String = "User") -> [String: Any] {
        var o: [String: Any] = [
            "number": number, "title": "Board PR \(number)", "url": "https://github.com/acme/widgets/pull/\(number)",
            "isDraft": draft, "headRefName": head, "baseRefName": base, "isCrossRepository": false,
            "updatedAt": updated, "additions": number, "deletions": 1,
            "author": ["login": author, "__typename": typename],
            "labels": ["nodes": [["name": "bug", "color": "d73a4a"], ["name": "weird", "color": "zz"]]],
            "reviewRequests": ["nodes": requested],
            "latestReviews": ["nodes": reviews],
            "reviewThreads": ["nodes": threads.map { ["isResolved": $0] }],
            "commits": ["nodes": [["commit": ["statusCheckRollup": ["contexts": ["nodes": checks]]]]]],
        ]
        if let decision { o["reviewDecision"] = decision }
        return o
    }

    static func board(login: String = "octocat", nodes: [[String: Any]], squash: Bool = true, merge: Bool = true,
                      rebase: Bool = false, preferred: String = "MERGE") -> [String: Any] {
        ["data": ["viewer": ["login": login],
                  "repository": ["squashMergeAllowed": squash, "mergeCommitAllowed": merge, "rebaseMergeAllowed": rebase,
                                 "viewerDefaultMergeMethod": preferred, "pullRequests": ["nodes": nodes]]]]
    }
}
