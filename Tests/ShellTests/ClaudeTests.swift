import XCTest
@testable import Shell

final class ClaudeArgumentsTests: XCTestCase {
    func testInteractiveLaunchesUseNativeView() {
        XCTAssertEqual(ClaudeArguments.parse([]), ClaudeArguments())
        let a = ClaudeArguments.parse(["--model", "opus", "--effort=high", "--permission-mode", "manual", "fix the build"])
        XCTAssertEqual(a?.model, "opus")
        XCTAssertEqual(a?.effort, "high")
        XCTAssertEqual(a?.permissionMode, "default")
        XCTAssertEqual(a?.prompt, "fix the build")
        XCTAssertEqual(a?.passthrough, [])
    }

    func testFlagsPassThrough() {
        let a = ClaudeArguments.parse(["-c", "--add-dir", "../a", "../b", "--agent", "reviewer", "--dangerously-skip-permissions"])
        XCTAssertEqual(a?.passthrough, ["-c", "--add-dir", "../a", "../b", "--agent", "reviewer", "--dangerously-skip-permissions"])
        XCTAssertEqual(a?.continuesSession, true)
        XCTAssertEqual(a?.allowsBypass, true)
        XCTAssertNil(a?.prompt)
    }

    func testResumeNeedsASessionID() {
        let id = "7bcc953c-5abd-4120-82da-148001c196cb"
        XCTAssertEqual(ClaudeArguments.parse(["--resume", id])?.resumeID, id)
        XCTAssertEqual(ClaudeArguments.parse(["-r", id])?.resumeID, id)
        XCTAssertNil(ClaudeArguments.parse(["--resume"]))          // picker
        XCTAssertNil(ClaudeArguments.parse(["-r", "search term"])) // picker with search
    }

    @MainActor
    func testRemoteControlFlagForTerminalUI() {
        let saved = SettingsStore.shared.settings.claudeRemoteControl
        defer { SettingsStore.shared.settings.claudeRemoteControl = saved }
        SettingsStore.shared.settings.claudeRemoteControl = true
        XCTAssertEqual(ClaudeLauncher.terminalAnswer(for: ["fix the build"]), "terminal-rc")
        XCTAssertEqual(ClaudeLauncher.terminalAnswer(for: ["--remote-control", "work"]), "terminal")
        XCTAssertEqual(ClaudeLauncher.terminalAnswer(for: ["--", "-p"]), "terminal")
        SettingsStore.shared.settings.claudeRemoteControl = false
        XCTAssertEqual(ClaudeLauncher.terminalAnswer(for: ["fix the build"]), "terminal")
    }

    func testTerminalOnlyLaunches() {
        XCTAssertNil(ClaudeArguments.parse(["-p", "hi"]))
        XCTAssertNil(ClaudeArguments.parse(["--version"]))
        XCTAssertNil(ClaudeArguments.parse(["mcp", "list"]))
        XCTAssertNil(ClaudeArguments.parse(["doctor"]))
        XCTAssertNil(ClaudeArguments.parse(["--worktree"]))
        XCTAssertNil(ClaudeArguments.parse(["one", "two"]))
        XCTAssertNil(ClaudeArguments.parse(["--model"]))
    }
}

final class GitStatusTests: XCTestCase {
    func testParsesBranchAndFiles() {
        let out = "## feat/x...origin/feat/x [ahead 2, behind 1]\0 M a.txt\0A  new.swift\0R  renamed.swift\0old.swift\0?? scratch.md\0!! build/\0D  gone.txt\0UU conflict.txt\0"
        let s = GitStatusSnapshot.parse(out)
        XCTAssertEqual(s.branch, "feat/x")
        XCTAssertEqual(s.upstream, "origin/feat/x")
        XCTAssertEqual(s.ahead, 2)
        XCTAssertEqual(s.behind, 1)
        XCTAssertEqual(s.files["a.txt"]?.kind, .modified)
        XCTAssertEqual(s.files["new.swift"]?.kind, .added)
        XCTAssertEqual(s.files["renamed.swift"]?.kind, .renamed)
        XCTAssertNil(s.files["old.swift"])
        XCTAssertEqual(s.files["scratch.md"]?.kind, .untracked)
        XCTAssertEqual(s.files["build/"]?.kind, .ignored)
        XCTAssertEqual(s.files["gone.txt"]?.kind, .deleted)
        XCTAssertEqual(s.files["conflict.txt"]?.kind, .conflicted)
        XCTAssertEqual(s.changes.count, 6)
    }

    func testParsesGitHubRemotes() {
        let expected = GitHubRemote(host: "github.com", owner: "takt-corp", name: "backend")
        XCTAssertEqual(GitHubRemote.parse("git@github.com:takt-corp/backend.git"), expected)
        XCTAssertEqual(GitHubRemote.parse("https://github.com/takt-corp/backend"), expected)
        XCTAssertEqual(GitHubRemote.parse("https://user@github.com/takt-corp/backend.git\n"), expected)
        XCTAssertEqual(GitHubRemote.parse("ssh://git@ssh.github.com:443/takt-corp/backend.git"), expected)
        XCTAssertNil(GitHubRemote.parse("git@gitlab.com:a/b.git"))
        XCTAssertEqual(expected.branchURL("feat/pla-1").absoluteString, "https://github.com/takt-corp/backend/tree/feat/pla-1")
        XCTAssertEqual(expected.compareURL("feat/pla-1").absoluteString, "https://github.com/takt-corp/backend/compare/feat/pla-1?expand=1")
    }

    func testParsesUnbornAndDetachedHeads() {
        XCTAssertEqual(GitStatusSnapshot.parse("## No commits yet on main\0").branch, "main")
        let detached = GitStatusSnapshot.parse("## HEAD (no branch)\0")
        XCTAssertTrue(detached.detached)
        XCTAssertNil(detached.branch)
    }
}

final class ClaudeFormattingTests: XCTestCase {
    func testMarkdownBlocks() {
        let md = "# Title\n\nSome **bold** text.\n\n```swift\nlet x = 1\n```\n\n- one\n- [x] two\n\n| a | b |\n|---|---|\n| 1 | 2 |"
        let blocks = MarkdownBlock.parse(md)
        XCTAssertEqual(blocks.count, 5)
        XCTAssertEqual(blocks[0], .heading(1, "Title"))
        XCTAssertEqual(blocks[2], .code(language: "swift", code: "let x = 1", closed: true))
        if case .list(let items) = blocks[3] { XCTAssertEqual(items.map(\.marker), ["•", "☑"]) } else { XCTFail() }
        XCTAssertEqual(blocks[4], .table(header: ["a", "b"], alignments: [.leading, .leading], rows: [["1", "2"]]))
    }

    func testGFMBlocks() {
        let md = """
        Title
        =====

        Sub
        ---

        > quoted
        > > nested

        > [!WARNING]
        > Careful **now**

        * [ ] todo
        + [x] done
        1) first

        | Left | Mid | Right |
        |:-----|:---:|------:|
        | `a|b` | x \\| y | 3 |

        ````md
        ```swift
        let x = 1
        ```
        ````

            indented code

        <details>
        <summary>More</summary>

        Hidden text
        </details>

        ![diagram](docs/arch.png)

        Claim[^1].

        [^1]: The source.
        """
        let blocks = MarkdownBlock.parse(md)
        XCTAssertEqual(blocks[0], .heading(1, "Title"))
        XCTAssertEqual(blocks[1], .heading(2, "Sub"))
        XCTAssertEqual(blocks[2], .quote([.paragraph("quoted"), .quote([.paragraph("nested")])]))
        XCTAssertEqual(blocks[3], .alert(.warning, [.paragraph("Careful **now**")]))
        if case .list(let items) = blocks[4] {
            XCTAssertEqual(items.map(\.marker), ["☐", "☑", "1."])
            XCTAssertEqual(items.map(\.text), ["todo", "done", "first"])
        } else { XCTFail("\(blocks[4])") }
        XCTAssertEqual(blocks[5], .table(header: ["Left", "Mid", "Right"], alignments: [.leading, .center, .trailing],
                                         rows: [["`a|b`", "x | y", "3"]]))
        XCTAssertEqual(blocks[6], .code(language: "md", code: "```swift\nlet x = 1\n```", closed: true))
        XCTAssertEqual(blocks[7], .code(language: "", code: "indented code", closed: true))
        XCTAssertEqual(blocks[8], .details(summary: "More", blocks: [.paragraph("Hidden text")]))
        XCTAssertEqual(blocks[9], .image(alt: "diagram", source: "docs/arch.png"))
        XCTAssertEqual(blocks[10], .paragraph("Claim[^1]."))
        XCTAssertEqual(blocks[11], .footnotes([.init(label: "1", text: "The source.")]))
        XCTAssertEqual(blocks.count, 12)
    }

    func testListItemsKeepContinuationsAndCode() {
        let md = "1. Run:\n   ```bash\n   make build\n\n   make test\n   ```\n2. Then\n   more\n\n   Second paragraph\n   - nested\nafter"
        guard case .list(let items) = MarkdownBlock.parse(md).first else { return XCTFail() }
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].text, "Run:\n```bash\nmake build\n\nmake test\n```")
        XCTAssertEqual(items[1].text, "Then\nmore\n\nSecond paragraph")
        XCTAssertEqual(items[2].indent, 1)
        XCTAssertEqual(items[2].text, "nested\nafter")
        XCTAssertEqual(MarkdownBlock.parse(items[0].text).count, 2)
    }

    func testUnclosedFenceWhileStreaming() {
        XCTAssertEqual(MarkdownBlock.parse("```py\nprint(1)"), [.code(language: "py", code: "print(1)", closed: false)])
        XCTAssertEqual(MarkdownBlock.parse("text\n---"), [.heading(2, "text")])
        XCTAssertEqual(MarkdownBlock.parse("text\n\n---"), [.paragraph("text"), .rule])
    }

    func testInlineHTMLAndLinks() {
        XCTAssertEqual(InlineMarkdown.inlineHTML("a<br>b <kbd>⌘K</kbd> `<br>`"), "a\nb `⌘K` `<br>`")
        XCTAssertEqual(InlineMarkdown.inlineHTML(#"<a href="https://x.io">X</a>"#), "[X](https://x.io)")
        XCTAssertEqual(ClaudeLinks.splitLine("src/a.swift:42").line, 42)
        XCTAssertEqual(ClaudeLinks.splitLine("src/a.swift:42:7").path, "src/a.swift")
        XCTAssertEqual(ClaudeLinks.splitLine("README.md#L10-L20").line, 10)
        XCTAssertNil(ClaudeLinks.splitLine("a.swift").line)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("main.swift").path, contents: Data())
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(ClaudeLinks.fileURL("main.swift:3", directory: dir.path)?.fragment, "L3")
        XCTAssertNil(ClaudeLinks.fileURL("missing.swift", directory: dir.path))
        XCTAssertNil(ClaudeLinks.fileURL("not a path", directory: dir.path))
    }

    @MainActor
    func testInlineAttributes() {
        let s = InlineMarkdown.attributed("~~old~~ see https://takt.io and `x` [^2]", palette: .current)
        XCTAssertEqual(String(s.characters), "old see https://takt.io and x 2")
        XCTAssertTrue(s.runs.contains { $0.strikethroughStyle != nil && String(s[$0.range].characters) == "old" })
        XCTAssertEqual(s.runs.compactMap(\.link).first?.absoluteString, "https://takt.io")
        XCTAssertTrue(s.runs.contains { $0.baselineOffset == 5 })
        // Code spans and README.md-style names aren't autolinked.
        XCTAssertTrue(InlineMarkdown.attributed("see README.md and `https://x.io`", palette: .current).runs.allSatisfy { $0.link == nil })
    }

    func testQuestionsAndAnswers() {
        let input: [String: Any] = ["questions": [[
            "question": "Which DB?", "header": "Storage", "multiSelect": false,
            "options": [["label": "Spanner", "description": "Global", "preview": "CREATE TABLE…"], ["label": "Postgres", "description": ""]],
        ]]]
        let q = ClaudeQuestion.parse(input)
        XCTAssertEqual(q.first?.options.map(\.label), ["Spanner", "Postgres"])
        XCTAssertEqual(q.first?.options.first?.preview, "CREATE TABLE…")
        XCTAssertNil(q.first?.options.last?.preview)
        XCTAssertEqual(ClaudeToolFormat.summary(name: "AskUserQuestion", input: input), "Which DB?")
        let text = #"User has answered your questions: "Which DB?"="Spanner", "Why \"now\"?"="Scale". You can now continue."#
        XCTAssertEqual(ClaudeQuestion.answers(structured: nil, text: text), ["Which DB?": "Spanner", #"Why \"now\"?"#: "Scale"])
        XCTAssertEqual(ClaudeQuestion.answers(structured: ["answers": ["Q": "A"]], text: ""), ["Q": "A"])
        XCTAssertNil(ClaudeQuestion.answers(structured: nil, text: "denied"))
    }

    func testHistoryPromptsAndResults() {
        XCTAssertEqual(ClaudeCodeSession.historyPrompt("fix it"), "fix it")
        XCTAssertEqual(ClaudeCodeSession.historyPrompt("<command-message>review</command-message>\n<command-name>/review</command-name>\n<command-args>12</command-args>"), "/review 12")
        XCTAssertNil(ClaudeCodeSession.historyPrompt("<local-command-stdout>ok</local-command-stdout>"))
        XCTAssertNil(ClaudeCodeSession.historyPrompt("<system-reminder>x</system-reminder>"))
        XCTAssertEqual(ClaudeToolFormat.visibleResult("done\n\n<system-reminder>\nnote\n</system-reminder>"), "done")
        let todos = ClaudeToolFormat.todos(["todos": [["content": "Build", "activeForm": "Building", "status": "in_progress"]]])
        XCTAssertEqual(todos.first?.status, .inProgress)
    }

    func testMentionClassification() {
        let style = InlineMarkdown.MentionStyle(skills: ["deep-research"], commands: ["deep-research", "compact"],
                                                mcpServers: ["github"], agents: ["reviewer"])
        XCTAssertEqual(InlineMarkdown.classify("/deep-research", style: style), .skill)
        XCTAssertEqual(InlineMarkdown.classify("/compact", style: style), .command)
        XCTAssertEqual(InlineMarkdown.classify("@github", style: style), .mcp)
        XCTAssertEqual(InlineMarkdown.classify("@agent-reviewer", style: style), .agent)
        XCTAssertEqual(InlineMarkdown.classify("@Sources/main.swift", style: style), .file)
        XCTAssertNil(InlineMarkdown.classify("/nope", style: style))
    }

    func testPermissionModeCycleAndProjectFolder() {
        XCTAssertEqual(ClaudePermissionMode.cycle(from: .default, autoAvailable: false), .acceptEdits)
        XCTAssertEqual(ClaudePermissionMode.cycle(from: .plan, autoAvailable: false), .default)
        XCTAssertEqual(ClaudePermissionMode.cycle(from: .plan, autoAvailable: true), .auto)
        XCTAssertEqual(ClaudeCodeSession.projectDirectoryName(for: "/Users/a/code/my.app"), "-Users-a-code-my-app")
    }
}

final class MCPTests: XCTestCase {
    func testParsesStatusEntries() {
        let plugin = MCPServerEntry.parse(["name": "plugin:takt-engineering:github", "status": "needs-auth", "scope": "dynamic", "source": "plugin",
                                           "config": ["type": "http", "url": "https://api.githubcopilot.com/mcp/"]])
        XCTAssertEqual(plugin.group, .plugin)
        XCTAssertEqual(plugin.displayName, "github")
        XCTAssertEqual(plugin.pluginName, "takt-engineering")
        XCTAssertEqual(plugin.status, .needsAuth)
        XCTAssertTrue(plugin.canSignIn)
        XCTAssertFalse(plugin.isEditable)

        let project = MCPServerEntry.parse(["name": "db", "status": "connected", "scope": "project", "source": "project",
                                            "config": ["type": "stdio", "command": "npx", "args": ["-y", "db-mcp"], "env": ["TOKEN": "secret"]],
                                            "tools": [["name": "query", "annotations": ["readOnly": true]]]])
        XCTAssertEqual(project.group, .project)
        XCTAssertEqual(project.group.cliScope, "project")
        XCTAssertEqual(project.endpoint, "npx -y db-mcp")
        XCTAssertEqual(project.envKeys, ["TOKEN"])
        XCTAssertEqual(project.tools, [.init(name: "query", readOnly: true, destructive: false)])

        let connector = MCPServerEntry.parse(["name": "claude.ai Linear", "status": "connected", "scope": "claudeai", "source": "claudeai",
                                              "config": ["type": "claudeai-proxy", "url": "https://mcp.linear.app"]])
        XCTAssertEqual(connector.group, .claudeai)
        XCTAssertEqual(connector.displayName, "Linear")
    }

    func testEnvExpansionAndCommandSplitting() {
        let env = ["TOKEN": "abc"]
        XCTAssertEqual(MCPToolInspector.expand("Bearer ${TOKEN}", env), "Bearer abc")
        XCTAssertEqual(MCPToolInspector.expand("${MISSING:-fallback}/x", env), "fallback/x")
        XCTAssertEqual(MCPAddServerSheet.splitCommand("npx -y \"my server\" --flag"), ["npx", "-y", "my server", "--flag"])
        XCTAssertEqual(MCPServerDetail.normalized("claude.ai Linear"), "claude_ai_Linear")
    }

    func testToolSchemaParsing() {
        let tool = MCPToolInfo.parse(["name": "search", "description": "Find things",
                                      "annotations": ["readOnlyHint": true],
                                      "inputSchema": ["type": "object", "required": ["query"],
                                                      "properties": ["limit": ["type": "integer"], "query": ["type": "string", "description": "Text"],
                                                                     "tags": ["type": "array", "items": ["type": "string"]]]]])
        XCTAssertEqual(tool.readOnly, true)
        XCTAssertEqual(tool.parameters.map(\.name), ["query", "limit", "tags"])
        XCTAssertEqual(tool.parameters[0].required, true)
        XCTAssertEqual(tool.parameters[2].type, "[string]")
    }
}

final class ClaudeTrustTests: XCTestCase {
    func testTrustInheritsFromParents() {
        let config: [String: Any] = ["projects": ["/Users/a/code": ["hasTrustDialogAccepted": true],
                                                  "/Users/a/code/evil": ["hasTrustDialogAccepted": false]]]
        XCTAssertTrue(ClaudeTrust.isTrusted("/Users/a/code/repo/sub", config: config))
        XCTAssertTrue(ClaudeTrust.isTrusted("/Users/a/code", config: config))
        XCTAssertFalse(ClaudeTrust.isTrusted("/Users/a/Downloads/repo", config: config))
        XCTAssertFalse(ClaudeTrust.isTrusted("/tmp/x", config: [:]))
    }
}

final class WorktreeTests: XCTestCase {
    func testParsesPorcelain() {
        let out = """
        worktree /repo
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /wt/feat
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/feat/pla-1
        locked in use

        worktree /wt/old
        HEAD 3333333333333333333333333333333333333333
        detached
        prunable gitdir file points to non-existent location

        """
        let list = WorktreeInfo.parse(porcelain: out)
        XCTAssertEqual(list.map(\.path), ["/repo", "/wt/feat", "/wt/old"])
        XCTAssertTrue(list[0].isMain)
        XCTAssertEqual(list[0].branch, "main")
        XCTAssertEqual(list[1].branch, "feat/pla-1")
        XCTAssertTrue(list[1].isLocked)
        XCTAssertEqual(list[1].lockReason, "in use")
        XCTAssertTrue(list[2].isDetached)
        XCTAssertTrue(list[2].isPrunable)
        XCTAssertEqual(list[2].head, "33333333")
        XCTAssertEqual(list[2].headOID, "3333333333333333333333333333333333333333")
    }

    func testMergedRule() {
        let sha = String(repeating: "a", count: 40)
        var wt = WorktreeInfo(path: "/wt/a", headOID: sha)
        wt.changes = 0
        var pr = PullRequestInfo(number: 1, title: "t", url: URL(string: "https://github.com/o/r/pull/1")!,
                                 state: .merged, isDraft: false, headOID: sha)
        wt.pullRequest = pr
        XCTAssertTrue(wt.isMergedAndClean)
        XCTAssertTrue(wt.headMatchesMergedPR)
        wt.headOID = String(repeating: "b", count: 40)
        XCTAssertTrue(wt.isMergedAndClean)
        XCTAssertFalse(wt.headMatchesMergedPR, "local commits after the merge keep the branch")
        wt.changes = 1
        XCTAssertFalse(wt.isMergedAndClean, "uncommitted changes are never cleaned up")
        wt.changes = nil
        XCTAssertFalse(wt.isMergedAndClean, "unknown status is not cleaned up")
        wt.changes = 0
        wt.isMain = true
        XCTAssertFalse(wt.isMergedAndClean, "the main checkout is never cleaned up")
        wt.isMain = false
        wt.isLocked = true
        XCTAssertFalse(wt.isMergedAndClean)
        wt.isLocked = false
        pr.state = .open
        wt.pullRequest = pr
        XCTAssertFalse(wt.isMergedAndClean)
        pr.state = .closed
        wt.pullRequest = pr
        XCTAssertFalse(wt.isMergedAndClean, "closed without merging is not merged")
    }

    func testStaleRule() {
        let now = Date()
        var wt = WorktreeInfo(path: "/wt/a")
        wt.changes = 0
        wt.lastActivity = now.addingTimeInterval(-8 * 86400)
        XCTAssertTrue(wt.isStale(days: 7, now: now))
        XCTAssertFalse(wt.isStale(days: 10, now: now))
        wt.changes = 2
        XCTAssertFalse(wt.isStale(days: 7, now: now), "uncommitted changes are never stale")
        wt.changes = 0
        wt.isMain = true
        XCTAssertFalse(wt.isStale(days: 7, now: now), "the main checkout is never stale")
        wt.isMain = false
        wt.isLocked = true
        XCTAssertFalse(wt.isStale(days: 7, now: now))
        wt.isLocked = false
        wt.changes = nil
        XCTAssertFalse(wt.isStale(days: 7, now: now), "unknown status is not stale")
    }

    func testFindsRepositoriesUnderAFolder() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("shell-repos-\(UUID().uuidString)")
        let fm = FileManager.default
        for p in ["a/.git", "group/b/.git", "group/c/node_modules/x/.git", "deep/1/2/d/.git"] {
            try fm.createDirectory(at: base.appendingPathComponent(p), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: base) }
        let found = WorktreeService.repositories(in: base.path).map { String($0.dropFirst(base.path.count + 1)) }
        XCTAssertEqual(found, ["a", "group/b"])
        XCTAssertEqual(WorktreeService.repositories(in: base.appendingPathComponent("a").path).count, 1)
    }
}

final class WorktreeRemovalTests: XCTestCase {
    private func git(_ args: [String], in dir: URL, env: [String: String] = [:]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = dir
        p.environment = ProcessInfo.processInfo.environment.merging(env) { _, b in b }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    func testRemovesCleanStaleWorktreesAndRefusesDirtyOnes() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("shell-wt-\(UUID().uuidString)").resolvingSymlinksInPath()
        let repo = base.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-10 * 86400))
        git(["init", "-q", "-b", "main"], in: repo)
        try "a".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        git(["add", "."], in: repo)
        git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"], in: repo,
            env: ["GIT_AUTHOR_DATE": old, "GIT_COMMITTER_DATE": old])
        git(["worktree", "add", "-q", "-b", "stale", "../stale"], in: repo)
        git(["worktree", "add", "-q", "-b", "dirty", "../dirty"], in: repo)
        git(["worktree", "add", "-q", "-b", "ahead", "../ahead"], in: repo)
        try "x".write(to: base.appendingPathComponent("dirty/new.txt"), atomically: true, encoding: .utf8)
        try "y".write(to: base.appendingPathComponent("ahead/b.txt"), atomically: true, encoding: .utf8)
        git(["add", "."], in: base.appendingPathComponent("ahead"))
        git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "wip"], in: base.appendingPathComponent("ahead"))
        let ancient = Date().addingTimeInterval(-10 * 86400)
        for name in ["stale", "dirty"] {
            for f in ["index", "HEAD"] {
                try FileManager.default.setAttributes([.modificationDate: ancient], ofItemAtPath: repo.path + "/.git/worktrees/\(name)/\(f)")
            }
        }

        let list = await WorktreeService.list(repo: repo.path, git: "/usr/bin/git")
        XCTAssertEqual(list.count, 4)
        var inspected: [String: WorktreeInfo] = [:]
        for w in list { inspected[w.name] = await WorktreeService.inspect(w, git: "/usr/bin/git") }
        XCTAssertEqual(inspected["stale"]?.isStale(days: 7), true)
        XCTAssertEqual(inspected["dirty"]?.changes, 1)
        XCTAssertEqual(inspected["dirty"]?.isStale(days: 7), false)
        XCTAssertEqual(inspected["ahead"]?.isStale(days: 7), false, "fresh commit")
        XCTAssertEqual(inspected["repo"]?.isStale(days: 7), false, "main checkout")

        // Dirty: refused without force.
        let dirtyErr = await WorktreeService.remove(inspected["dirty"]!, repo: repo.path, git: "/usr/bin/git", force: false, deleteBranch: false)
        XCTAssertNotNil(dirtyErr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("dirty").path))

        // Stale: removed; merged branch deleted with -d.
        let staleErr = await WorktreeService.remove(inspected["stale"]!, repo: repo.path, git: "/usr/bin/git", force: false, deleteBranch: true)
        XCTAssertNil(staleErr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("stale").path))

        // Unmerged branch: worktree removed, branch kept (git branch -d refuses).
        let aheadErr = await WorktreeService.remove(inspected["ahead"]!, repo: repo.path, git: "/usr/bin/git", force: false, deleteBranch: true)
        XCTAssertNotNil(aheadErr)
        XCTAssertTrue(aheadErr?.contains("kept branch ahead") ?? false)
        let tracking = await WorktreeService.branchTracking(repo: repo.path, git: "/usr/bin/git")
        XCTAssertNotNil(tracking["ahead"], "unmerged branch survives")
        XCTAssertNil(tracking["stale"], "merged branch deleted")
        XCTAssertNotNil(tracking["dirty"])
    }
}

final class PullRequestTests: XCTestCase {
    func testParsesOpenPullRequest() {
        let pr = OpenPullRequest.parse([
            "number": 684, "title": "feature(resourcing): accept processId", "url": "https://github.com/takt-corp/backend/pull/684",
            "isDraft": true, "headRefName": "feature/PLA-2890", "baseRefName": "develop",
            "author": ["login": "someone", "is_bot": false], "reviewDecision": "",
            "updatedAt": "2026-09-27T00:53:07Z", "additions": 218, "deletions": 3, "isCrossRepository": false,
            "reviewRequests": [["__typename": "Team", "slug": "org/reviewers"], ["__typename": "User", "login": "arhea"]],
            "labels": [["name": "feature", "color": "0E8A16"]],
            "statusCheckRollup": [["__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SUCCESS"],
                                  ["__typename": "CheckRun", "status": "COMPLETED", "conclusion": "FAILURE"]],
        ])
        XCTAssertEqual(pr?.number, 684)
        XCTAssertEqual(pr?.head, "feature/PLA-2890")
        XCTAssertNil(pr?.reviewDecision)
        XCTAssertEqual(pr?.reviewRequestedLogins, ["arhea"])
        XCTAssertEqual(pr?.checks, .failing)
        XCTAssertNotNil(pr?.updatedAt)
    }

    func testCheckRollup() {
        XCTAssertEqual(OpenPullRequest.rollup([]).0, .none)
        XCTAssertEqual(OpenPullRequest.rollup([["status": "IN_PROGRESS"], ["status": "COMPLETED", "conclusion": "SUCCESS"]]).0, .pending)
        XCTAssertEqual(OpenPullRequest.rollup([["__typename": "StatusContext", "state": "SUCCESS"], ["status": "COMPLETED", "conclusion": "SKIPPED"]]).0, .passing)
        XCTAssertEqual(OpenPullRequest.rollup([["__typename": "StatusContext", "state": "ERROR"]]).0, .failing)
    }
}

final class ActionsTests: XCTestCase {
    func testRunStates() {
        XCTAssertEqual(WorkflowRun.state(status: "in_progress", conclusion: ""), .running)
        XCTAssertEqual(WorkflowRun.state(status: "queued", conclusion: ""), .queued)
        XCTAssertEqual(WorkflowRun.state(status: "waiting", conclusion: ""), .queued)
        XCTAssertEqual(WorkflowRun.state(status: "completed", conclusion: "success"), .success)
        XCTAssertEqual(WorkflowRun.state(status: "completed", conclusion: "timed_out"), .failure)
        XCTAssertEqual(WorkflowRun.state(status: "completed", conclusion: "cancelled"), .cancelled)
        XCTAssertEqual(WorkflowRun.state(status: "completed", conclusion: "skipped"), .skipped)
    }

    func testParsesRun() {
        let run = WorkflowRun.parse(["databaseId": 36282469666, "number": 2743, "displayTitle": "Checking Pull Request 684/merge",
                                     "workflowName": "Takt / Pull Request", "status": "in_progress", "conclusion": "",
                                     "headBranch": "feature/PLA-2890", "event": "pull_request", "attempt": 2,
                                     "url": "https://github.com/takt-corp/backend/actions/runs/36282469666",
                                     "createdAt": "2026-09-27T00:25:52Z", "startedAt": "2026-09-27T00:25:52Z"])
        XCTAssertEqual(run?.isActive, true)
        XCTAssertEqual(run?.attempt, 2)
        XCTAssertNotNil(run?.duration)
    }
}

final class AgentStorageTests: XCTestCase {
    func testCategoriesFindOnlyRemovableItems() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("shell-home-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let root = home.resolvingSymlinksInPath().path
        let sid = "03cef7a5-70f9-443d-a800-4ec0868f84c1"
        let files = [
            ".claude/projects/-Users-a-repo/\(sid).jsonl",
            ".claude/projects/-Users-a-repo/\(sid)/subagents/x.jsonl",
            ".claude/projects/-Users-a-repo/memory/MEMORY.md",
            ".claude/file-history/\(sid)/abc@v1",
            ".claude/settings.json",
            ".claude/shell-snapshots/snapshot-zsh-1.sh",
            "Library/Caches/ClaudeCode/claude-502/-Users-a-repo/\(sid)/scratchpad/x.txt",
            "Library/Caches/ClaudeCode/cc-socks/123.sock",
            "Library/Caches/claude-cli-nodejs/-Users-a-repo/mcp-logs-linear/2026-09-01.jsonl",
            ".local/share/claude/versions/2.1.9",
            ".local/share/claude/versions/2.1.10",
            ".codex/sessions/2026/09/01/rollout-1.jsonl",
            ".codex/logs_2.sqlite",
            ".codex/config.toml",
            ".codex/.tmp/plugins/p.json",
        ]
        for f in files {
            let u = home.appendingPathComponent(f)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: u)
        }
        let cats = Dictionary(uniqueKeysWithValues: AgentStorage.categories(home: home).map { ($0.id, $0) })
        func rel(_ u: URL) -> String {
            let p = u.resolvingSymlinksInPath().path
            return p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : p
        }
        func names(_ id: String) -> [String] { cats[id]!.items().map(rel).sorted() }

        XCTAssertEqual(names("claude-transcripts"), [".claude/projects/-Users-a-repo/\(sid)", ".claude/projects/-Users-a-repo/\(sid).jsonl"],
                       "memory/ is never a candidate")
        XCTAssertEqual(names("claude-checkpoints"), [".claude/file-history/\(sid)"])
        XCTAssertEqual(names("claude-scratch"), ["Library/Caches/ClaudeCode/claude-502/-Users-a-repo/\(sid)"], "live sockets are skipped")
        XCTAssertEqual(names("claude-logs"), ["Library/Caches/claude-cli-nodejs/-Users-a-repo/mcp-logs-linear/2026-09-01.jsonl"])
        XCTAssertEqual(names("claude-versions"), [".local/share/claude/versions/2.1.9"], "the newest version is kept")
        XCTAssertEqual(names("codex-sessions"), [".codex/sessions/2026/09/01/rollout-1.jsonl"])
        XCTAssertEqual(names("codex-logs"), [".codex/logs_2.sqlite"])
        XCTAssertTrue(names("codex-caches").contains(".codex/.tmp/plugins"))
        XCTAssertFalse(files.filter { $0.hasSuffix("settings.json") || $0.hasSuffix("config.toml") }.contains { f in
            cats.values.flatMap { $0.items() }.contains { $0.path.hasSuffix(f) }
        }, "config files are never candidates")

        // Age cutoffs: an old transcript goes, a fresh one stays.
        let old = home.appendingPathComponent(".claude/projects/-Users-a-repo/\(sid).jsonl")
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86400)], ofItemAtPath: old.path)
        let items = cats["claude-transcripts"]!.items().map(AgentStorage.measure)
        let stale = items.filter { $0.lastModified < Date().addingTimeInterval(-30 * 86400) }
        XCTAssertEqual(stale.map(\.url.lastPathComponent), ["\(sid).jsonl"])
        let r = AgentStorage.remove(stale)
        XCTAssertTrue(r.failures.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent(".claude/projects/-Users-a-repo/memory/MEMORY.md").path))
        XCTAssertEqual(AgentStorage.claudeCleanupDays(home: home), 30)
    }
}
