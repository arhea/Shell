import Foundation
import Observation

struct BrewPackage: Identifiable, Hashable {
    enum Kind: String { case formula, cask }
    var kind: Kind
    var name: String
    var displayName: String
    var description: String
    var homepage: String?
    var version: String
    var installedVersion: String?
    var outdated: Bool
    var installedOnRequest: Bool
    var pinned: Bool

    var id: String { "\(kind.rawValue):\(name)" }
    var isInstalled: Bool { installedVersion != nil }
}

/// Homebrew status, installed packages, updates and search.
@MainActor
@Observable
final class BrewService {
    static let shared = BrewService()

    private(set) var brewPath: String?
    private(set) var version: String?
    private(set) var installed: [BrewPackage] = []
    private(set) var searchResults: [BrewPackage] = []
    private(set) var isLoading = false
    private(set) var isSearching = false
    private(set) var lastError: String?
    private var searchTask: Task<Void, Never>?

    static let installCommand = #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#

    private init() { detect() }

    func detect() {
        // Test hook: point Shell at a stand-in brew without touching the real one.
        if let override = ProcessInfo.processInfo.environment["SHELL_APP_BREW"], FileManager.default.isExecutableFile(atPath: override) {
            brewPath = override
            return
        }
        brewPath = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew", "/home/linuxbrew/.linuxbrew/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var isInstalled: Bool { brewPath != nil }
    var outdated: [BrewPackage] { installed.filter(\.outdated) }

    private var env: [String: String] { ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_ANALYTICS": "1"] }

    func refresh() async {
        detect()
        guard let brew = brewPath else { return }
        isLoading = true
        defer { isLoading = false }
        let v = await ProcessRunner.run(brew, ["--version"], environment: env)
        version = String(decoding: v.stdout, as: UTF8.self).split(separator: "\n").first.map(String.init)
        let r = await ProcessRunner.run(brew, ["info", "--json=v2", "--installed"], environment: env)
        guard r.status == 0 else {
            lastError = r.stderr.isEmpty ? "brew info failed" : r.stderr
            return
        }
        installed = Self.parse(r.stdout).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        lastError = nil
    }

    func search(_ query: String) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, let brew = brewPath else {
            searchResults = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            isSearching = true
            defer { isSearching = false }
            let formulae = await ProcessRunner.run(brew, ["search", "--formula", q], environment: env)
            let casks = await ProcessRunner.run(brew, ["search", "--cask", q], environment: env)
            if Task.isCancelled { return }
            func names(_ r: ProcessRunner.Result) -> [String] {
                String(decoding: r.stdout, as: UTF8.self).split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("==>") && !$0.contains(" ") }
            }
            let rank: (String, String) -> Bool = { a, b in
                let ea = a == q, eb = b == q
                if ea != eb { return ea }
                let pa = a.hasPrefix(q), pb = b.hasPrefix(q)
                if pa != pb { return pa }
                return a.count < b.count
            }
            let fNames = Array(names(formulae).sorted(by: rank).prefix(25))
            let cNames = Array(names(casks).sorted(by: rank).prefix(15))
            var results: [BrewPackage] = []
            if !fNames.isEmpty {
                let info = await ProcessRunner.run(brew, ["info", "--json=v2", "--formula"] + fNames, environment: env)
                results += Self.parse(info.stdout)
            }
            if !cNames.isEmpty {
                let info = await ProcessRunner.run(brew, ["info", "--json=v2", "--cask"] + cNames, environment: env)
                results += Self.parse(info.stdout)
            }
            if Task.isCancelled { return }
            searchResults = results.sorted { rank($0.name, $1.name) }
        }
    }

    // MARK: Actions (run visibly in a terminal tab)

    func install(_ p: BrewPackage) { run("brew install \(p.kind == .cask ? "--cask " : "")\(p.name)", title: "brew install") }
    func uninstall(_ p: BrewPackage) { run("brew uninstall \(p.kind == .cask ? "--cask " : "")\(p.name)", title: "brew uninstall") }
    func upgrade(_ p: BrewPackage) { run("brew upgrade \(p.kind == .cask ? "--cask " : "")\(p.name)", title: "brew upgrade") }
    func upgradeAll() { run("brew update && brew upgrade", title: "brew upgrade") }
    func cleanup() { run("brew cleanup", title: "brew cleanup") }
    func doctor() { run("brew doctor", title: "brew doctor") }
    func installHomebrew() { run(Self.installCommand, title: "Install Homebrew") }

    private func run(_ command: String, title: String) {
        AppDelegate.shared.runInTerminal(command, title: title)
    }

    // MARK: Parsing

    /// Names from `brew outdated --json=v2`.
    nonisolated static func parseOutdated(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let items = (root["formulae"] as? [[String: Any]] ?? []) + (root["casks"] as? [[String: Any]] ?? [])
        return items.compactMap { $0["name"] as? String }
    }

    nonisolated static func parse(_ data: Data) -> [BrewPackage] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [BrewPackage] = []
        for f in root["formulae"] as? [[String: Any]] ?? [] {
            let name = f["name"] as? String ?? "?"
            let installedList = f["installed"] as? [[String: Any]] ?? []
            let versions = f["versions"] as? [String: Any]
            out.append(BrewPackage(
                kind: .formula, name: name, displayName: name,
                description: f["desc"] as? String ?? "",
                homepage: f["homepage"] as? String,
                version: versions?["stable"] as? String ?? "",
                installedVersion: installedList.last?["version"] as? String,
                outdated: f["outdated"] as? Bool ?? false,
                installedOnRequest: installedList.last?["installed_on_request"] as? Bool ?? false,
                pinned: f["pinned"] as? Bool ?? false))
        }
        for c in root["casks"] as? [[String: Any]] ?? [] {
            let token = c["token"] as? String ?? "?"
            out.append(BrewPackage(
                kind: .cask, name: token, displayName: (c["name"] as? [String])?.first ?? token,
                description: c["desc"] as? String ?? "",
                homepage: c["homepage"] as? String,
                version: c["version"] as? String ?? "",
                installedVersion: c["installed"] as? String,
                outdated: c["outdated"] as? Bool ?? false,
                installedOnRequest: true,
                pinned: false))
        }
        return out
    }
}
