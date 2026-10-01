import Foundation

/// Claude Code's "Do you trust this folder?" decision, stored in ~/.claude.json
/// as `projects[<path>].hasTrustDialogAccepted`.
///
/// Print mode (`claude -p`), which the native view and the MCP manager use,
/// skips that dialog — and with it the approval of a repository's hooks and
/// `.mcp.json` servers. So Shell only starts those in folders that are trusted:
/// in Claude Code's terminal UI, with the native view's "Trust and Start", or
/// (optionally) because they're a worktree of a trusted repository.
enum ClaudeTrust {
    /// Unit tests point this at a temporary file; nil means ~/.claude.json.
    nonisolated(unsafe) static var configURLOverride: URL?
    static var configURL: URL {
        configURLOverride ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    /// True when `directory` or one of its parents was trusted.
    static func isTrusted(_ directory: String, config: [String: Any]? = nil, configURL: URL = configURL) -> Bool {
        let projects = (config ?? loadConfig(configURL))?["projects"] as? [String: Any] ?? [:]
        var path = URL(fileURLWithPath: directory).standardizedFileURL.path
        while true {
            if (projects[path] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true { return true }
            guard path != "/", !path.isEmpty else { return false }
            path = (path as NSString).deletingLastPathComponent
        }
    }

    /// Trusted already, or a linked worktree of a trusted repository (when the
    /// setting allows it) — in which case the worktree is recorded as trusted
    /// so Claude Code's terminal UI and hooks agree.
    @MainActor
    static func ensureTrusted(_ directory: String) -> Bool {
        if isTrusted(directory) { return true }
        guard SettingsStore.shared.settings.claudeTrustWorktrees,
              let worktree = worktreeRoot(containing: directory),
              let main = mainCheckout(ofWorktree: worktree),
              isTrusted(main) else { return false }
        return (try? trust(worktree)) != nil && isTrusted(directory)
    }

    /// Records `directory` as trusted, keeping everything else in the file.
    /// Claude Code rewrites ~/.claude.json often, so this re-reads right before
    /// writing and checks the result.
    static func trust(_ directory: String, configURL: URL = configURL) throws {
        let std = URL(fileURLWithPath: directory).standardizedFileURL
        let paths = Set([std.path, std.resolvingSymlinksInPath().path])
        for _ in 0..<3 {
            let loaded = loadConfig(configURL)
            if loaded == nil, FileManager.default.fileExists(atPath: configURL.path) {
                throw CocoaError(.fileReadCorruptFile) // never overwrite a file we can't parse
            }
            var config = loaded ?? [:]
            var projects = config["projects"] as? [String: Any] ?? [:]
            for path in paths {
                var entry = projects[path] as? [String: Any] ?? [:]
                entry["hasTrustDialogAccepted"] = true
                projects[path] = entry
            }
            config["projects"] = projects
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .withoutEscapingSlashes])
            try data.write(to: configURL, options: .atomic)
            if isTrusted(std.path, configURL: configURL) { return }
            Thread.sleep(forTimeInterval: 0.15) // lost a race with Claude Code's own write; try again
        }
        throw CocoaError(.fileWriteUnknown)
    }

    /// The top of the git checkout containing `directory`, when that checkout
    /// is a linked worktree (its `.git` is a file, not a folder).
    static func worktreeRoot(containing directory: String) -> String? {
        var path = URL(fileURLWithPath: directory).standardizedFileURL.path
        let fm = FileManager.default
        while path != "/", !path.isEmpty {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path + "/.git", isDirectory: &isDir) { return isDir.boolValue ? nil : path }
            path = (path as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// The main checkout of a linked worktree, from its `.git` file
    /// ("gitdir: /repo/.git/worktrees/name").
    static func mainCheckout(ofWorktree worktree: String) -> String? {
        guard let text = try? String(contentsOfFile: worktree + "/.git", encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        var gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !gitdir.hasPrefix("/") { gitdir = URL(fileURLWithPath: worktree).appendingPathComponent(gitdir).standardizedFileURL.path }
        guard let range = gitdir.range(of: "/.git/worktrees/", options: .backwards) else { return nil }
        return String(gitdir[..<range.lowerBound])
    }

    private static func loadConfig(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
