import Foundation
import Observation

/// Inspects and edits the user's zsh + Oh My Zsh setup. All edits to
/// ~/.zshrc are minimal, line-based, and preceded by a backup.
@MainActor
@Observable
final class ZshService {
    static let shared = ZshService()

    struct ExternalPlugin: Identifiable {
        var id: String { name }
        var name: String
        var summary: String
        var repo: String
    }

    static let externalPlugins: [ExternalPlugin] = [
        .init(name: "zsh-autosuggestions", summary: "Fish-like suggestions from history (for typing directly in the terminal)",
              repo: "https://github.com/zsh-users/zsh-autosuggestions"),
        .init(name: "zsh-syntax-highlighting", summary: "Highlights commands as you type in the terminal",
              repo: "https://github.com/zsh-users/zsh-syntax-highlighting"),
        .init(name: "zsh-completions", summary: "Hundreds of extra completion definitions (also powers Shell's completions)",
              repo: "https://github.com/zsh-users/zsh-completions"),
        .init(name: "zsh-history-substring-search", summary: "Search history for any substring with ↑/↓",
              repo: "https://github.com/zsh-users/zsh-history-substring-search"),
        .init(name: "fzf-tab", summary: "Replace zsh's completion menu with fzf (needs fzf)",
              repo: "https://github.com/Aloxaf/fzf-tab"),
    ]

    static let ohMyZshInstall = #"RUNZSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)""#

    private(set) var zshVersion: String?
    private(set) var loginShell: String = ""
    private(set) var omzPath: String?
    private(set) var theme: String?
    private(set) var enabledPlugins: [String] = []
    private(set) var availablePlugins: [String] = []
    private(set) var availableThemes: [String] = []
    private(set) var lastError: String?

    // Injectable for unit tests; the defaults are the user's real setup.
    @ObservationIgnored private let home: URL
    @ObservationIgnored private let zdotdir: String?
    @ObservationIgnored private let zsh: String
    @ObservationIgnored private let reportedOhMyZsh: @MainActor () -> String?
    @ObservationIgnored private let terminal: @MainActor (_ command: String, _ title: String) -> Void

    var zshrcURL: URL {
        let dir = zdotdir.map { URL(fileURLWithPath: $0) } ?? home
        return dir.appendingPathComponent(".zshrc")
    }
    var customPath: String? { omzPath.map { "\($0)/custom" } }
    var isOhMyZshInstalled: Bool { omzPath != nil }
    var isZshDefault: Bool { (loginShell as NSString).lastPathComponent == "zsh" }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         zdotdir: String? = ProcessInfo.processInfo.environment["ZDOTDIR"],
         zsh: String = "/bin/zsh",
         reportedOhMyZsh: @escaping @MainActor () -> String? = { AgentIntegrations.shared.ohMyZshPath },
         terminal: @escaping @MainActor (_ command: String, _ title: String) -> Void = { AppDelegate.shared.runInTerminal($0, title: $1) }) {
        self.home = home
        self.zdotdir = zdotdir
        self.zsh = zsh
        self.reportedOhMyZsh = reportedOhMyZsh
        self.terminal = terminal
    }

    func refresh() async {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell { loginShell = String(cString: sh) }
        let v = await ProcessRunner.run(zsh, ["--version"])
        zshVersion = String(decoding: v.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        let reported = reportedOhMyZsh()
        let candidates = [reported, home.appendingPathComponent(".oh-my-zsh").path].compactMap { $0 }
        omzPath = candidates.first { FileManager.default.fileExists(atPath: "\($0)/oh-my-zsh.sh") }

        let rc = (try? String(contentsOf: zshrcURL, encoding: .utf8)) ?? ""
        theme = Self.parseTheme(rc)
        enabledPlugins = Self.parsePlugins(rc) ?? []

        if let omz = omzPath {
            let fm = FileManager.default
            var plugins = Set((try? fm.contentsOfDirectory(atPath: "\(omz)/plugins")) ?? [])
            plugins.formUnion(((try? fm.contentsOfDirectory(atPath: "\(omz)/custom/plugins")) ?? []).filter { $0 != "example" })
            availablePlugins = plugins.filter { !$0.hasPrefix(".") }.sorted()
            var themes = ((try? fm.contentsOfDirectory(atPath: "\(omz)/themes")) ?? [])
                .filter { $0.hasSuffix(".zsh-theme") }.map { String($0.dropLast(10)) }
            for item in (try? fm.contentsOfDirectory(atPath: "\(omz)/custom/themes")) ?? [] {
                if item.hasSuffix(".zsh-theme") { themes.append(String(item.dropLast(10))) }
                else if fm.fileExists(atPath: "\(omz)/custom/themes/\(item)/\(item).zsh-theme") { themes.append("\(item)/\(item)") }
            }
            availableThemes = themes.filter { $0 != "example" }.sorted()
        }
    }

    func isPluginInstalled(_ name: String) -> Bool {
        guard let omz = omzPath else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: "\(omz)/plugins/\(name)") || fm.fileExists(atPath: "\(omz)/custom/plugins/\(name)")
    }

    // MARK: Parsing

    static func parseTheme(_ rc: String) -> String? {
        for line in rc.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("ZSH_THEME=") else { continue }
            return String(t.dropFirst(10)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        return nil
    }

    /// Returns the plugins listed in the first uncommented `plugins=(…)` block.
    static func parsePlugins(_ rc: String) -> [String]? {
        guard let range = pluginsRange(rc) else { return nil }
        let block = String(rc[range])
        guard let open = block.firstIndex(of: "("), let close = block.lastIndex(of: ")") else { return nil }
        let inner = block[block.index(after: open)..<close]
        return inner.components(separatedBy: .newlines)
            .map { $0.components(separatedBy: "#")[0] }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    static func pluginsRange(_ rc: String) -> Range<String.Index>? {
        var searchStart = rc.startIndex
        while let r = rc.range(of: "plugins=(", range: searchStart..<rc.endIndex) {
            let lineStart = rc[..<r.lowerBound].lastIndex(of: "\n").map { rc.index(after: $0) } ?? rc.startIndex
            let prefix = rc[lineStart..<r.lowerBound]
            if prefix.trimmingCharacters(in: .whitespaces).isEmpty, let close = rc[r.upperBound...].firstIndex(of: ")") {
                return lineStart..<rc.index(after: close)
            }
            searchStart = r.upperBound
        }
        return nil
    }

    // MARK: Editing

    func setTheme(_ name: String) {
        edit { rc in
            var lines = rc.components(separatedBy: "\n")
            if let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("ZSH_THEME=") }) {
                lines[i] = "ZSH_THEME=\"\(name)\""
            } else if let i = lines.firstIndex(where: { $0.contains("oh-my-zsh.sh") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }) {
                lines.insert("ZSH_THEME=\"\(name)\"", at: i)
            } else {
                lines.insert("ZSH_THEME=\"\(name)\"", at: 0)
            }
            return lines.joined(separator: "\n")
        }
    }

    func setPlugin(_ name: String, enabled: Bool) {
        var list = enabledPlugins
        if enabled {
            guard !list.contains(name) else { return }
            // zsh-syntax-highlighting must be loaded last.
            if let idx = list.firstIndex(of: "zsh-syntax-highlighting") { list.insert(name, at: idx) } else { list.append(name) }
        } else {
            list.removeAll { $0 == name }
        }
        edit { rc in
            let block = "plugins=(\(list.joined(separator: " ")))"
            if let range = Self.pluginsRange(rc) {
                var copy = rc
                copy.replaceSubrange(range, with: block)
                return copy
            }
            var lines = rc.components(separatedBy: "\n")
            if let i = lines.firstIndex(where: { $0.contains("oh-my-zsh.sh") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }) {
                lines.insert(block, at: i)
            } else {
                lines.append(block)
            }
            return lines.joined(separator: "\n")
        }
    }

    private func edit(_ transform: (String) -> String) {
        let fm = FileManager.default
        let original = (try? String(contentsOf: zshrcURL, encoding: .utf8)) ?? ""
        let updated = transform(original)
        guard updated != original else { return }
        do {
            if fm.fileExists(atPath: zshrcURL.path) {
                let backup = zshrcURL.deletingLastPathComponent().appendingPathComponent(".zshrc.shell-backup")
                try? fm.removeItem(at: backup)
                try fm.copyItem(at: zshrcURL, to: backup)
            }
            try updated.write(to: zshrcURL, atomically: true, encoding: .utf8)
            lastError = nil
        } catch {
            lastError = "Couldn't write \(zshrcURL.path): \(error.localizedDescription)"
        }
        theme = Self.parseTheme(updated)
        enabledPlugins = Self.parsePlugins(updated) ?? []
    }

    // MARK: Commands (run in a visible tab)

    func installOhMyZsh() { terminal(Self.ohMyZshInstall, "Install Oh My Zsh") }
    func updateOhMyZsh() { terminal("omz update", "Update Oh My Zsh") }
    func makeZshDefault() { terminal("chsh -s /bin/zsh", "Default shell") }

    func installExternal(_ plugin: ExternalPlugin) {
        guard let custom = customPath else { return }
        let dest = "\(custom)/plugins/\(plugin.name)"
        terminal("git clone --depth=1 \(plugin.repo) \(ShellEscape.quote(dest))", plugin.name)
        setPlugin(plugin.name, enabled: true)
    }

    func installPowerlevel10k() {
        guard let custom = customPath else { return }
        let dest = "\(custom)/themes/powerlevel10k"
        terminal("git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \(ShellEscape.quote(dest))", "powerlevel10k")
        setTheme("powerlevel10k/powerlevel10k")
    }

    /// Restarts idle shells so .zshrc changes take effect (keeps Shell's integration).
    func reloadOpenShells() {
        for session in SessionRegistry.shared.all where session.state == .idle {
            session.submit(command: "_shellapp_reload")
        }
    }
}
