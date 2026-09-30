import Foundation
import Observation

/// Installs and detects the hooks that let Claude Code and Codex report
/// "working / needs input / finished" to Shell. Hooks call `$SHELL_APP_CTL`,
/// which only exists inside Shell's terminals, so they are harmless elsewhere.
@MainActor
@Observable
final class AgentIntegrations {
    static let shared = AgentIntegrations()

    enum Status: Equatable {
        case notInstalled
        case installed
        case conflict(String)
        case unavailable(String)
    }

    private(set) var claude: Status = .notInstalled
    private(set) var codex: Status = .notInstalled
    private(set) var lastError: String?

    /// Latest Oh My Zsh info reported by a shell (used by the Zsh settings pane).
    private(set) var ohMyZshPath: String?
    private(set) var ohMyZshTheme: String?

    static let marker = "SHELL_APP_CTL"
    static let claudeEvents = ["UserPromptSubmit", "Notification", "Stop", "SessionEnd"]

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    var claudeSettingsURL: URL { home.appendingPathComponent(".claude/settings.json") }
    var codexConfigURL: URL { home.appendingPathComponent(".codex/config.toml") }

    private init() { refresh() }

    func shellReported(omz: String?, theme: String?) {
        ohMyZshPath = (omz?.isEmpty ?? true) ? nil : omz
        ohMyZshTheme = (theme?.isEmpty ?? true) ? nil : theme
    }

    func refresh() {
        claude = detectClaude()
        codex = detectCodex()
    }

    // MARK: Claude Code

    static func claudeCommand(_ event: String) -> String {
        "[ -n \"$SHELL_APP_CTL\" ] && \"$SHELL_APP_CTL\" claude-hook \(event) || true"
    }

    private func detectClaude() -> Status {
        guard let data = try? Data(contentsOf: claudeSettingsURL) else { return .notInstalled }
        guard let text = String(data: data, encoding: .utf8) else { return .notInstalled }
        return text.contains(Self.marker) ? .installed : .notInstalled
    }

    func installClaude() {
        do {
            var root = try readJSONObject(claudeSettingsURL)
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            for event in Self.claudeEvents {
                var groups = hooks[event] as? [[String: Any]] ?? []
                let already = groups.contains { group in
                    (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(Self.marker) == true }
                }
                if already { continue }
                var group: [String: Any] = ["hooks": [["type": "command", "command": Self.claudeCommand(event)]]]
                if event == "Notification" { group["matcher"] = "" }
                groups.append(group)
                hooks[event] = groups
            }
            root["hooks"] = hooks
            try writeJSONObject(root, to: claudeSettingsURL)
            lastError = nil
        } catch {
            lastError = "Couldn't update \(claudeSettingsURL.path): \(error.localizedDescription)"
        }
        refresh()
    }

    func uninstallClaude() {
        do {
            var root = try readJSONObject(claudeSettingsURL)
            guard var hooks = root["hooks"] as? [String: Any] else { return }
            for (event, value) in hooks {
                guard var groups = value as? [[String: Any]] else { continue }
                groups = groups.compactMap { group in
                    var g = group
                    let inner = (group["hooks"] as? [[String: Any]] ?? []).filter { ($0["command"] as? String)?.contains(Self.marker) != true }
                    if inner.isEmpty { return nil }
                    g["hooks"] = inner
                    return g
                }
                hooks[event] = groups.isEmpty ? nil : groups
            }
            root["hooks"] = hooks.isEmpty ? nil : hooks
            try writeJSONObject(root, to: claudeSettingsURL)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    // MARK: Codex

    static let codexNotifyLine =
        #"notify = ["sh", "-c", "[ -n \"$SHELL_APP_CTL\" ] && exec \"$SHELL_APP_CTL\" codex-notify \"$1\"; exit 0", "shellctl"]"#

    private func topLevelNotifyLine(in text: String) -> (index: Int, line: String)? {
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { return nil } // tables start; notify must be top-level
            if t.hasPrefix("notify") && t.dropFirst(6).trimmingCharacters(in: .whitespaces).hasPrefix("=") {
                return (i, line)
            }
        }
        return nil
    }

    private func detectCodex() -> Status {
        guard let text = try? String(contentsOf: codexConfigURL, encoding: .utf8) else {
            let codexDir = home.appendingPathComponent(".codex")
            return FileManager.default.fileExists(atPath: codexDir.path) ? .notInstalled : .notInstalled
        }
        guard let existing = topLevelNotifyLine(in: text) else { return .notInstalled }
        return existing.line.contains(Self.marker) ? .installed : .conflict(existing.line.trimmingCharacters(in: .whitespaces))
    }

    /// Installs the Codex notify hook. Replaces an existing `notify` only when `replace` is true.
    func installCodex(replace: Bool) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: codexConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let text = (try? String(contentsOf: codexConfigURL, encoding: .utf8)) ?? ""
            var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
            if let existing = topLevelNotifyLine(in: text) {
                guard replace || existing.line.contains(Self.marker) else {
                    codex = .conflict(existing.line)
                    return
                }
                lines[existing.index] = Self.codexNotifyLine
            } else {
                lines.insert(contentsOf: ["# Added by Shell.app: agent notifications in Shell tabs", Self.codexNotifyLine, ""], at: 0)
            }
            try backup(codexConfigURL)
            try lines.joined(separator: "\n").write(to: codexConfigURL, atomically: true, encoding: .utf8)
            lastError = nil
        } catch {
            lastError = "Couldn't update \(codexConfigURL.path): \(error.localizedDescription)"
        }
        refresh()
    }

    func uninstallCodex() {
        guard let text = try? String(contentsOf: codexConfigURL, encoding: .utf8),
              let existing = topLevelNotifyLine(in: text), existing.line.contains(Self.marker) else { return }
        var lines = text.components(separatedBy: "\n")
        lines.remove(at: existing.index)
        if existing.index > 0, lines[existing.index - 1].hasPrefix("# Added by Shell.app") {
            lines.remove(at: existing.index - 1)
        }
        try? backup(codexConfigURL)
        try? lines.joined(separator: "\n").write(to: codexConfigURL, atomically: true, encoding: .utf8)
        refresh()
    }

    // MARK: Helpers

    private func readJSONObject(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return obj
    }

    private func writeJSONObject(_ obj: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try backup(url)
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    private func backup(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let dest = url.appendingPathExtension("shell-backup")
        try? fm.removeItem(at: dest)
        try fm.copyItem(at: url, to: dest)
    }
}
