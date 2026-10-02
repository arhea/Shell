import SwiftUI
import XCTest
@testable import Shell

private let installedJSON = #"""
{"formulae": [
  {"name": "wget", "desc": "Internet file retriever", "homepage": "https://www.gnu.org/software/wget/",
   "versions": {"stable": "1.25.0"}, "installed": [{"version": "1.24.5", "installed_on_request": true}], "outdated": true, "pinned": false},
  {"name": "openssl@3", "desc": "TLS toolkit", "versions": {"stable": "3.5.0"},
   "installed": [{"version": "3.5.0", "installed_on_request": false}], "outdated": false, "pinned": true},
  {"name": "Jq", "desc": "JSON processor", "versions": {"stable": "1.8.0"},
   "installed": [{"version": "1.7.1", "installed_on_request": true}, {"version": "1.8.0", "installed_on_request": true}], "outdated": false}
],
"casks": [
  {"token": "firefox", "name": ["Firefox"], "desc": "Web browser", "homepage": "https://www.mozilla.org/firefox/",
   "version": "140.0", "installed": "139.0", "outdated": true}
]}
"""#

private let formulaJSON = #"""
{"formulae": [
  {"name": "jq", "desc": "Lightweight JSON processor", "versions": {"stable": "1.8.0"}, "installed": []},
  {"name": "jq-extra", "desc": "", "versions": {"stable": "0.1"}, "installed": []},
  {"name": "xjq", "versions": {"stable": "2.0"}}
]}
"""#

private let caskJSON = #"""
{"casks": [{"token": "jq-cask", "name": ["JQ Cask"], "desc": "A cask", "version": "1.0", "installed": null}]}
"""#

/// A stand-in brew in `dir`: `info` prints the fixture for its mode
/// (`installed.json`, `formula.json`, `cask.json`), `search` prints canned
/// names, and `info.status`/`info.stderr` make `info --installed` fail.
private struct FakeBrew {
    let dir: URL
    var path: String { dir.appendingPathComponent("brew").path }

    init(in dir: URL) throws {
        self.dir = dir
        try installedJSON.write(to: dir.appendingPathComponent("installed.json"), atomically: true, encoding: .utf8)
        try formulaJSON.write(to: dir.appendingPathComponent("formula.json"), atomically: true, encoding: .utf8)
        try caskJSON.write(to: dir.appendingPathComponent("cask.json"), atomically: true, encoding: .utf8)
        let script = #"""
        #!/bin/sh
        dir=$(dirname "$0")
        echo "$*" >> "$dir/calls.log"
        case "$1" in
          --version) echo "Homebrew 4.5.0"; echo "Homebrew/homebrew-core (git revision abc)" ;;
          info)
            case "$*" in
              *--installed*)
                if [ -f "$dir/info.status" ]; then cat "$dir/info.stderr" >&2 2>/dev/null; exit "$(cat "$dir/info.status")"; fi
                cat "$dir/installed.json" ;;
              *--formula*) cat "$dir/formula.json" ;;
              *--cask*) cat "$dir/cask.json" ;;
            esac ;;
          search)
            if [ "$2" = "--formula" ]; then printf '==> Formulae\nxjq\njq-extra\njq\nhas space\n\n'; else printf 'jq-cask\n'; fi ;;
        esac
        """#
        try writeExecutable(script, to: dir.appendingPathComponent("brew"))
    }

    var calls: [String] {
        ((try? String(contentsOf: dir.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}

// MARK: - Parsing

final class BrewParsingTests: XCTestCase {
    func testParsesFormulaeAndCasks() {
        let packages = BrewService.parse(Data(installedJSON.utf8))
        XCTAssertEqual(packages.map(\.id), ["formula:wget", "formula:openssl@3", "formula:Jq", "cask:firefox"])
        let wget = packages[0]
        XCTAssertEqual(wget.kind, .formula)
        XCTAssertEqual(wget.displayName, "wget")
        XCTAssertEqual(wget.description, "Internet file retriever")
        XCTAssertEqual(wget.homepage, "https://www.gnu.org/software/wget/")
        XCTAssertEqual(wget.version, "1.25.0")
        XCTAssertEqual(wget.installedVersion, "1.24.5")
        XCTAssertTrue(wget.outdated)
        XCTAssertTrue(wget.installedOnRequest)
        XCTAssertFalse(wget.pinned)
        XCTAssertTrue(wget.isInstalled)

        XCTAssertTrue(packages[1].pinned)
        XCTAssertFalse(packages[1].installedOnRequest)
        XCTAssertNil(packages[1].homepage)
        XCTAssertEqual(packages[2].installedVersion, "1.8.0", "the newest installed keg")

        let firefox = packages[3]
        XCTAssertEqual(firefox.kind, .cask)
        XCTAssertEqual(firefox.name, "firefox")
        XCTAssertEqual(firefox.displayName, "Firefox")
        XCTAssertEqual(firefox.installedVersion, "139.0")
        XCTAssertTrue(firefox.installedOnRequest)
        XCTAssertTrue(firefox.outdated)
    }

    func testMissingFieldsGetDefaults() {
        let packages = BrewService.parse(Data(#"{"formulae": [{}], "casks": [{}]}"#.utf8))
        XCTAssertEqual(packages.map(\.name), ["?", "?"])
        XCTAssertEqual(packages[0].version, "")
        XCTAssertNil(packages[0].installedVersion)
        XCTAssertFalse(packages[0].isInstalled)
        XCTAssertEqual(packages[1].displayName, "?")
        XCTAssertEqual(packages[1].description, "")
    }

    func testMalformedJSONParsesToNothing() {
        XCTAssertEqual(BrewService.parse(Data("not json".utf8)), [])
        XCTAssertEqual(BrewService.parse(Data("[1, 2]".utf8)), [])
        XCTAssertEqual(BrewService.parseOutdated(Data("nope".utf8)), [])
        XCTAssertEqual(BrewService.parseOutdated(Data(#"{"formulae": [{"name": "a"}, {"nameless": 1}], "casks": [{"name": "b"}]}"#.utf8)), ["a", "b"])
    }
}

// MARK: - Service

@MainActor
final class BrewServiceTests: XCTestCase {
    private var dir: URL!
    private var fake: FakeBrew!
    private var commands: [(String, String)] = []

    override func setUp() async throws {
        dir = try makeTemporaryDirectory()
        fake = try FakeBrew(in: dir)
        commands = []
    }

    private func makeService(installed: Bool = true) -> BrewService {
        BrewService(candidates: installed ? [dir.appendingPathComponent("missing").path, fake.path] : [],
                    terminal: { [weak self] in self?.commands.append(($0, $1)) })
    }

    func testDetectsTheFirstExecutableCandidate() {
        let brew = makeService()
        XCTAssertEqual(brew.brewPath, fake.path)
        XCTAssertTrue(brew.isInstalled)
        XCTAssertFalse(makeService(installed: false).isInstalled)
        // The default lookup only checks the standard locations.
        BrewService(terminal: { _, _ in }).detect()
    }

    func testRefreshLoadsVersionAndSortedPackages() async {
        let brew = makeService()
        await brew.refresh()
        XCTAssertFalse(brew.isLoading)
        XCTAssertNil(brew.lastError)
        XCTAssertEqual(brew.version, "Homebrew 4.5.0")
        XCTAssertEqual(brew.installed.map(\.name), ["firefox", "Jq", "openssl@3", "wget"])
        XCTAssertEqual(brew.outdated.map(\.name), ["firefox", "wget"])
        XCTAssertEqual(fake.calls, ["--version", "info --json=v2 --installed"])
    }

    func testRefreshReportsBrewInfoFailures() async throws {
        try "3".write(to: dir.appendingPathComponent("info.status"), atomically: true, encoding: .utf8)
        try "Error: broken tap".write(to: dir.appendingPathComponent("info.stderr"), atomically: true, encoding: .utf8)
        let brew = makeService()
        await brew.refresh()
        XCTAssertEqual(brew.lastError, "Error: broken tap")
        XCTAssertTrue(brew.installed.isEmpty)

        try FileManager.default.removeItem(at: dir.appendingPathComponent("info.stderr"))
        await brew.refresh()
        XCTAssertEqual(brew.lastError, "brew info failed")
    }

    func testRefreshWithoutBrewDoesNothing() async {
        let brew = makeService(installed: false)
        await brew.refresh()
        XCTAssertNil(brew.version)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testSearchRanksExactThenPrefixThenShorterMatches() async {
        let brew = makeService()
        brew.search("  jq ")
        await assertEventually { !brew.searchResults.isEmpty }
        XCTAssertFalse(brew.isSearching)
        XCTAssertEqual(brew.searchResults.map(\.name), ["jq", "jq-cask", "jq-extra", "xjq"])
        XCTAssertEqual(brew.searchResults.first { $0.name == "jq-cask" }?.kind, .cask)
        XCTAssertTrue(fake.calls.contains("search --formula jq"))
        XCTAssertTrue(fake.calls.contains("search --cask jq"))
        XCTAssertTrue(fake.calls.contains("info --json=v2 --formula jq jq-extra xjq"), fake.calls.joined(separator: "\n"))
        XCTAssertTrue(fake.calls.contains("info --json=v2 --cask jq-cask"))
    }

    func testShortQueriesClearResultsAndNewSearchesCancelOldOnes() async throws {
        let brew = makeService()
        brew.search("jq")
        await assertEventually { !brew.searchResults.isEmpty }
        brew.search("j")
        XCTAssertTrue(brew.searchResults.isEmpty, "one character is too short to search")

        brew.search("wg")
        brew.search("jq") // replaces the pending "wg" search during its debounce
        await assertEventually { !brew.searchResults.isEmpty }
        XCTAssertFalse(fake.calls.contains("search --formula wg"))

        XCTAssertTrue(makeService(installed: false).searchResults.isEmpty)
        let none = makeService(installed: false)
        none.search("jq")
        XCTAssertTrue(none.searchResults.isEmpty)
    }

    func testActionsRunVisibleCommands() {
        let brew = makeService()
        let formula = BrewPackage(kind: .formula, name: "jq", displayName: "jq", description: "", homepage: nil, version: "1.8",
                                  installedVersion: nil, outdated: false, installedOnRequest: true, pinned: false)
        var cask = formula
        cask.kind = .cask
        cask.name = "firefox"
        brew.install(formula)
        brew.install(cask)
        brew.uninstall(formula)
        brew.uninstall(cask)
        brew.upgrade(formula)
        brew.upgrade(cask)
        brew.upgradeAll()
        brew.cleanup()
        brew.doctor()
        brew.installHomebrew()
        XCTAssertEqual(commands.map(\.0), [
            "brew install jq", "brew install --cask firefox",
            "brew uninstall jq", "brew uninstall --cask firefox",
            "brew upgrade jq", "brew upgrade --cask firefox",
            "brew update && brew upgrade", "brew cleanup", "brew doctor", BrewService.installCommand,
        ])
        XCTAssertEqual(commands.map(\.1).last, "Install Homebrew")
        XCTAssertEqual(commands.first?.1, "brew install")
    }
}

// MARK: - Pane

@MainActor
final class HomebrewPaneTests: XCTestCase {
    private var dir: URL!
    private var fake: FakeBrew!

    override func setUp() async throws {
        dir = try makeTemporaryDirectory()
        fake = try FakeBrew(in: dir)
    }

    private func loadedService() async -> BrewService {
        let brew = BrewService(candidates: [fake.path], terminal: { _, _ in XCTFail("rendering never runs commands") })
        await brew.refresh()
        return brew
    }

    func testNotInstalled() {
        let brew = BrewService(candidates: [], terminal: { _, _ in })
        let host = render(HomebrewPane(brew: brew))
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    func testInstalledScopeWithAndWithoutDependenciesAndFilters() async {
        let brew = await loadedService()
        render(HomebrewPane(brew: brew))
        render(HomebrewPane(brew: brew, showDependencies: true))
        render(HomebrewPane(brew: brew, query: "json"))
        render(HomebrewPane(brew: brew, query: "nothing-matches-this"))
        XCTAssertEqual(brew.installed.count, 4)
    }

    func testUpdatesScope() async {
        let brew = await loadedService()
        render(HomebrewPane(brew: brew, scope: .updates))
        let empty = BrewService(candidates: [fake.path], terminal: { _, _ in })
        render(HomebrewPane(brew: empty, scope: .updates)) // nothing loaded yet: everything up to date
        XCTAssertEqual(brew.outdated.count, 2)
    }

    func testSearchScope() async {
        let brew = await loadedService()
        render(HomebrewPane(brew: brew, scope: .search, query: "j")) // too short
        render(HomebrewPane(brew: brew, scope: .search, query: "zzz")) // no results
        brew.search("jq")
        await assertEventually { !brew.searchResults.isEmpty }
        render(HomebrewPane(brew: brew, scope: .search, query: "jq"))
    }

    func testRowsInEveryState() {
        let brew = BrewService(candidates: [], terminal: { _, _ in })
        let base = BrewPackage(kind: .formula, name: "jq", displayName: "jq", description: "JSON processor", homepage: "https://jqlang.org",
                               version: "1.8.0", installedVersion: "1.7.1", outdated: true, installedOnRequest: true, pinned: true)
        var upToDate = base
        upToDate.outdated = false
        upToDate.pinned = false
        upToDate.description = ""
        upToDate.homepage = nil
        var available = base
        available.installedVersion = nil
        var cask = base
        cask.kind = .cask
        cask.name = "firefox"
        cask.displayName = "Firefox"
        for p in [base, upToDate, available, cask] {
            render(BrewRow(package: p, brew: brew), size: CGSize(width: 600, height: 60))
        }
        XCTAssertEqual(HomebrewPane.Scope.allCases.map(\.id), ["Installed", "Updates", "Search"])
    }
}
