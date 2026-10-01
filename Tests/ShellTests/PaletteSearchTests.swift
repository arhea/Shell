import XCTest
@testable import Shell

/// The palette's prefix parsing, sectioning and match highlighting, and the
/// toolbar and sidebar text built without views.
@MainActor
final class PaletteSearchTests: XCTestCase {
    private struct Row: Equatable {
        var section: PaletteSection
        var title: String
    }

    private func group(_ rows: [Row], _ query: String) -> [(PaletteSection, [String])] {
        PaletteSearch.group(rows, query: .parse(query), section: \.section, title: \.title).map { ($0.section, $0.items.map(\.title)) }
    }

    // MARK: Prefixes

    func testParsesScopePrefixes() {
        XCTAssertEqual(PaletteQuery.parse("split"), PaletteQuery(scope: .all, text: "split"))
        XCTAssertEqual(PaletteQuery.parse(">split right"), PaletteQuery(scope: .actions, text: "split right"))
        XCTAssertEqual(PaletteQuery.parse("  > split "), PaletteQuery(scope: .actions, text: "split"))
        XCTAssertEqual(PaletteQuery.parse("@code"), PaletteQuery(scope: .places, text: "code"))
        XCTAssertEqual(PaletteQuery.parse("@"), PaletteQuery(scope: .places, text: ""))
        XCTAssertEqual(PaletteQuery.parse(""), PaletteQuery(scope: .all, text: ""))
        XCTAssertEqual(PaletteQuery.parse("a > b"), PaletteQuery(scope: .all, text: "a > b"), "only a leading > scopes")
    }

    func testScopesIncludeTheirSections() {
        let actions = PaletteQuery.parse(">x")
        XCTAssertEqual(PaletteSection.allCases.filter(actions.includes), [.suggested, .actions])
        let places = PaletteQuery.parse("@x")
        XCTAssertEqual(PaletteSection.allCases.filter(places.includes), [.worktrees, .folders])
        XCTAssertEqual(PaletteSection.allCases.filter(PaletteQuery.parse("x").includes), PaletteSection.allCases)
        XCTAssertEqual(PaletteSection.allCases.filter(PaletteQuery.parse("").includes), [.suggested, .tabs, .worktrees, .folders, .actions],
                       "themes and history only while searching")
    }

    // MARK: Sections

    func testGroupsInSectionOrderAndRanksWithinASection() {
        let rows = [
            Row(section: .actions, title: "New Worktree from Branch"),
            Row(section: .worktrees, title: "tests/ui-e2e"),
            Row(section: .actions, title: "Show Worktrees Sidebar"),
            Row(section: .tabs, title: "takt"),
            Row(section: .worktrees, title: "bug/38-sigpipe"),
            Row(section: .actions, title: "Work"),
        ]
        let result = group(rows, "work")
        XCTAssertEqual(result.map(\.0), [.actions], "only matching rows; no worktree title contains w-o-r-k")
        XCTAssertEqual(result.first?.1, ["Work", "New Worktree from Branch", "Show Worktrees Sidebar"], "earlier matches rank first")

        let all = group(rows, "")
        XCTAssertEqual(all.map(\.0), [.tabs, .worktrees, .actions])
        XCTAssertEqual(all[1].1, ["tests/ui-e2e", "bug/38-sigpipe"], "no search keeps the given order")
    }

    func testSectionLimitsAndUnlimitedActionsWithThePrefix() {
        let rows = (0..<40).map { Row(section: .actions, title: "Action \($0)") }
        XCTAssertEqual(group(rows, "").first?.1.count, PaletteSection.actions.limit)
        XCTAssertEqual(group(rows, ">").first?.1.count, 40)
        XCTAssertEqual(group(rows, "@").count, 0)
    }

    func testSuggestionsSkipFiltering() {
        let rows = [Row(section: .suggested, title: "Split Right"), Row(section: .actions, title: "Split Right")]
        let result = group(rows, "split the pane please")
        XCTAssertEqual(result.map(\.0), [.suggested], "the model's pick shows even when the words don't fuzzy-match")
    }

    // MARK: Highlighting

    func testMatchIndicesPreferContiguousMatches() {
        XCTAssertEqual(PaletteSearch.matchIndices("work", in: "New Worktree"), [4, 5, 6, 7])
        XCTAssertEqual(PaletteSearch.matchIndices("nwt", in: "New Worktree"), [0, 2, 8])
        XCTAssertEqual(PaletteSearch.matchIndices("", in: "x"), [])
        XCTAssertNil(PaletteSearch.matchIndices("zz", in: "New Worktree"))
        XCTAssertNil(PaletteSearch.matchIndices("toolong", in: "short"))
    }

    // MARK: Toolbar and sidebar text

    func testToolbarSubtitle() {
        let repo = ToolbarSubtitle.repo(slug: "arhea/Shell", branch: "bug/38", ahead: 2, behind: 1, isWorktree: true, changes: 3)
        XCTAssertEqual(repo, ToolbarSubtitle.Repo(lead: "arhea/Shell /", branch: "bug/38 ↑2 ↓1", trailing: " · worktree · 3 changed"))
        let clean = ToolbarSubtitle.repo(slug: "Shell", branch: "main", ahead: 0, behind: 0, isWorktree: false, changes: 0)
        XCTAssertEqual(clean.branch, "main")
        XCTAssertEqual(clean.trailing, "")
        XCTAssertEqual(ToolbarSubtitle.plain(directory: "~/code/takt", shell: "zsh"), "~/code/takt · zsh")
        XCTAssertEqual(ToolbarSubtitle.plain(directory: "~/code/takt", shell: nil), "~/code/takt")
    }

    func testClaudeSessionsSubtitle() {
        var s = ClaudeDashboard.Summary()
        XCTAssertEqual(DashboardSidebarRow.subtitle(s), "No sessions")
        s.total = 3
        s.needsInput = 1
        s.working = 2
        XCTAssertEqual(DashboardSidebarRow.subtitle(s), "1 needs you · 2 working")
        s.needsInput = 2
        s.working = 0
        XCTAssertEqual(DashboardSidebarRow.subtitle(s), "2 need you")
        s.needsInput = 0
        XCTAssertEqual(DashboardSidebarRow.subtitle(s), "3 sessions")
    }

    func testPullRequestCountsForTheViewer() {
        func pr(_ n: Int, author: String, requested: [String]) -> OpenPullRequest {
            OpenPullRequest(number: n, title: "PR \(n)", url: URL(string: "https://github.com/a/b/pull/\(n)")!, isDraft: false,
                            head: "h\(n)", base: "main", author: author, authorIsBot: false, reviewDecision: nil, updatedAt: nil,
                            additions: 0, deletions: 0, isCrossRepository: false, labels: [], checks: .none, checksSummary: "",
                            reviewRequestedLogins: requested)
        }
        var assigned = pr(4, author: "mk", requested: ["x"])
        assigned.assignees = ["me"]
        // For you matches the board: review requested or assigned (not authored).
        let prs = [pr(1, author: "me", requested: []), pr(2, author: "jl", requested: ["me"]), pr(3, author: "mk", requested: ["me", "x"]),
                   assigned, pr(5, author: "mk", requested: ["x"])]
        XCTAssertTrue(GitHubSidebarRow.counts(prs, login: "me") == (2, 3))
        XCTAssertTrue(GitHubSidebarRow.counts(prs, login: nil) == (0, 0))
    }

    func testNewShortcutBindings() {
        XCTAssertEqual(ShortcutAction.claudeInNewWorktree.defaultShortcut, .cmdOpt("n"))
        XCTAssertEqual(ShortcutAction.toggleNotifications.defaultShortcut, .cmdOpt("a"))
        XCTAssertEqual(ShortcutAction.toggleTabSidebar.defaultShortcut, .cmdCtrl("s"))
    }
}
