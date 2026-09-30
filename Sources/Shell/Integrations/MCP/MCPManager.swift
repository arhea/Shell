import AppKit
import Observation

/// One MCP server as Claude Code sees it from a directory.
struct MCPServerEntry: Identifiable, Equatable {
    enum Status: String {
        case connected, needsAuth = "needs-auth", failed, pending, disabled, untrusted
        var title: String {
            switch self {
            case .connected: "Connected"
            case .needsAuth: "Needs sign-in"
            case .failed: "Failed"
            case .pending: "Connecting…"
            case .disabled: "Disabled"
            case .untrusted: "Folder not trusted"
            }
        }
    }

    enum Group: Int, CaseIterable, Comparable {
        case project, local, user, plugin, claudeai, other
        static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }
        var title: String {
            switch self {
            case .project: "Project · .mcp.json"
            case .local: "Project · only you"
            case .user: "Global · all projects"
            case .plugin: "Plugins"
            case .claudeai: "claude.ai connectors"
            case .other: "Other"
            }
        }
        /// The `claude mcp -s` scope, for groups Shell can edit.
        var cliScope: String? {
            switch self {
            case .project: "project"
            case .local: "local"
            case .user: "user"
            default: nil
            }
        }
    }

    struct Tool: Hashable {
        var name: String
        var readOnly: Bool
        var destructive: Bool
    }

    var name: String
    var status: Status
    var scope: String
    var source: String
    var error: String?
    var transport: String
    var url: String?
    var command: String?
    var args: [String]
    var envKeys: [String]
    var headerKeys: [String]
    var hasOAuth: Bool
    var serverTitle: String?
    var serverVersion: String?
    var serverDescription: String?
    var websiteURL: URL?
    var iconURL: URL?
    var tools: [Tool]
    /// The raw config, for Shell's own `tools/list` connection.
    var configJSON: Data

    var id: String { name }

    var group: Group {
        switch (scope, source) {
        case ("project", _): .project
        case ("local", _): .local
        case ("user", _): .user
        case (_, "plugin"): .plugin
        case (_, "claudeai"), ("claudeai", _): .claudeai
        default: .other
        }
    }

    var displayName: String {
        if group == .claudeai, name.hasPrefix("claude.ai ") { return String(name.dropFirst(10)) }
        if group == .plugin, name.hasPrefix("plugin:") {
            let parts = name.dropFirst(7).split(separator: ":", maxSplits: 1)
            if parts.count == 2 { return String(parts[1]) }
        }
        return name
    }

    /// Plugin that provides it ("takt-engineering"), for plugin servers.
    var pluginName: String? {
        guard group == .plugin, name.hasPrefix("plugin:") else { return nil }
        return name.dropFirst(7).split(separator: ":").first.map(String.init)
    }

    var canSignIn: Bool { transport == "http" || transport == "sse" || transport == "claudeai-proxy" }
    var isEditable: Bool { group.cliScope != nil }
    var config: [String: Any] { (try? JSONSerialization.jsonObject(with: configJSON) as? [String: Any]) ?? [:] }

    var endpoint: String {
        if let url, !url.isEmpty { return url }
        if let command { return ([command] + args).joined(separator: " ") }
        return transport
    }

    static func parse(_ s: [String: Any]) -> MCPServerEntry {
        let config = s["config"] as? [String: Any] ?? [:]
        let info = s["serverInfo"] as? [String: Any] ?? [:]
        let icon = (info["icons"] as? [[String: Any]])?.first?["src"] as? String
        let transport = config["type"] as? String ?? (config["command"] != nil ? "stdio" : "http")
        return MCPServerEntry(
            name: s["name"] as? String ?? "",
            status: Status(rawValue: s["status"] as? String ?? "") ?? .pending,
            scope: s["scope"] as? String ?? "", source: s["source"] as? String ?? "",
            error: s["error"] as? String,
            transport: transport,
            url: config["url"] as? String, command: config["command"] as? String,
            args: config["args"] as? [String] ?? [],
            envKeys: (config["env"] as? [String: Any]).map { $0.keys.sorted() } ?? [],
            headerKeys: (config["headers"] as? [String: Any]).map { $0.keys.sorted() } ?? [],
            hasOAuth: config["oauth"] != nil,
            serverTitle: (info["title"] as? String) ?? (info["name"] as? String),
            serverVersion: info["version"] as? String,
            serverDescription: info["description"] as? String,
            websiteURL: (info["websiteUrl"] as? String).flatMap(URL.init(string:)),
            iconURL: icon.flatMap(URL.init(string:)),
            tools: (s["tools"] as? [[String: Any]] ?? []).map { t in
                let a = t["annotations"] as? [String: Any] ?? [:]
                return Tool(name: t["name"] as? String ?? "",
                            readOnly: a["readOnly"] as? Bool ?? a["readOnlyHint"] as? Bool ?? false,
                            destructive: a["destructive"] as? Bool ?? a["destructiveHint"] as? Bool ?? false)
            },
            configJSON: (try? JSONSerialization.data(withJSONObject: config)) ?? Data())
    }
}

/// Manages MCP servers for a directory through Claude Code itself: a headless
/// `claude` reports status and tools and runs sign-in, and `claude mcp`
/// adds and removes servers, so nothing here edits Claude Code's files.
@MainActor
@Observable
final class MCPManager {
    private(set) var directory: String
    private(set) var repository: GitRepository?
    private(set) var servers: [MCPServerEntry] = []
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var busy: Set<String> = []
    /// Servers waiting on a browser sign-in.
    private(set) var signingIn: [String: URL] = [:]
    private(set) var toolDetails: [String: [MCPToolInfo]] = [:]
    private(set) var toolErrors: [String: String] = [:]
    private(set) var loadingTools: Set<String> = []
    private(set) var lastUpdated: Date?
    /// Whether the directory is trusted in Claude Code (project servers only run if so).
    private(set) var trusted = true

    @ObservationIgnored private var client: ClaudeControlClient?
    @ObservationIgnored private let binary: String
    @ObservationIgnored private var environment: [String: String]
    @ObservationIgnored private var initialized = false

    init(directory: String, binary: String? = nil, environment: [String: String]? = nil) {
        self.directory = directory
        self.environment = environment ?? MCPManager.defaultEnvironment()
        self.binary = binary ?? GitRepository.findExecutable("claude", environment: self.environment) ?? "claude"
    }

    /// The environment the last `claude` launch exported (PATH, credentials),
    /// else the app's own with the usual tool directories added.
    static func defaultEnvironment() -> [String: String] {
        if let env = ClaudeLauncher.lastEnvironment { return env }
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extra = ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        return env
    }

    var grouped: [(MCPServerEntry.Group, [MCPServerEntry])] {
        let groups = Dictionary(grouping: servers, by: \.group)
        return MCPServerEntry.Group.allCases.compactMap { g in
            guard let list = groups[g], !list.isEmpty else { return nil }
            return (g, list.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending })
        }
    }

    var needsAuthCount: Int { servers.filter { $0.status == .needsAuth }.count }

    func server(_ name: String) -> MCPServerEntry? { servers.first { $0.name == name } }

    // MARK: Lifecycle

    func switchDirectory(_ dir: String) {
        guard dir != directory else { return }
        directory = dir
        stop()
        servers = []
        toolDetails = [:]
        toolErrors = [:]
        stopped = false
        refresh()
    }

    /// Set by `stop()` (window closed): in-flight loads must not start a new
    /// `claude` afterwards.
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    func stop() {
        stopped = true
        loadTask?.cancel()
        loadTask = nil
        client?.stop()
        client = nil
        initialized = false
        repository?.stop()
        repository = nil
    }

    private func ensureClient() async throws -> ClaudeControlClient {
        if stopped || Task.isCancelled { throw CancellationError() }
        if let client, client.isRunning, initialized { return client }
        client?.stop()
        // In an untrusted folder, ask from home so the repo's .mcp.json never starts.
        trusted = ClaudeTrust.isTrusted(directory)
        let c = ClaudeControlClient(binary: binary, directory: trusted ? directory : NSHomeDirectory(), environment: environment)
        c.onExit = { [weak self, weak c] in
            guard let self, self.client === c else { return }
            self.initialized = false
        }
        try c.start()
        client = c
        try await c.request(["subtype": "initialize"], timeout: 60)
        initialized = true
        return c
    }

    /// Loads status; while servers are still connecting, polls a few more times.
    func load() async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        if repository == nil {
            let repo = await GitRepository.discover(from: directory, environment: environment)
            guard !stopped, !Task.isCancelled else { repo?.stop(); return }
            repository = repo
        }
        do {
            _ = try await ensureClient()
            for attempt in 0..<12 {
                try await refreshStatus()
                if !servers.contains(where: { $0.status == .pending }) || attempt == 11 { break }
                try await Task.sleep(for: .seconds(1.5))
            }
        } catch {
            if !(error is CancellationError) { lastError = describe(error) }
        }
    }

    func refreshStatus() async throws {
        let c = try await ensureClient()
        let r = try await c.request(["subtype": "mcp_status"])
        var list = (r["mcpServers"] as? [[String: Any]] ?? []).map(MCPServerEntry.parse)
        if !trusted { list += untrustedProjectServers() }
        if list != servers { servers = list }
        lastUpdated = Date()
    }

    /// Starts (or restarts) loading; cancelled by `stop()`.
    func refresh() {
        loadTask?.cancel()
        loadTask = Task { await load() }
    }

    /// The repo's .mcp.json servers, listed (not started) while the folder is untrusted.
    private func untrustedProjectServers() -> [MCPServerEntry] {
        let root = repository?.root.path ?? directory
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(".mcp.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = obj["mcpServers"] as? [String: Any] else { return [] }
        return servers.compactMap { name, value in
            guard let config = value as? [String: Any] else { return nil }
            var e = MCPServerEntry.parse(["name": name, "status": "untrusted", "scope": "project", "source": "project", "config": config])
            e.status = .untrusted
            e.error = "Claude Code hasn't been trusted in this folder, so this server isn't started. Open `claude` in the terminal UI here and trust the folder."
            return e
        }
    }

    /// Restarts the headless Claude so config changes (add/remove) load.
    func reload() {
        client?.stop()
        client = nil
        initialized = false
        refresh()
    }

    // MARK: Actions

    /// Starts the OAuth flow (or the claude.ai connector page) in the browser
    /// and waits for the server to connect.
    func signIn(_ name: String) {
        guard !busy.contains(name) else { return }
        busy.insert(name)
        lastError = nil
        Task {
            defer { busy.remove(name) }
            do {
                let c = try await ensureClient()
                let r = try await c.request(["subtype": "mcp_authenticate", "serverName": name], timeout: 60)
                if let s = r["authUrl"] as? String, let url = URL(string: s) {
                    signingIn[name] = url
                    NSWorkspace.shared.open(url)
                }
                let callbackExpected = r["callbackExpected"] as? Bool ?? true
                // Claude Code finishes the OAuth callback itself; watch for the connection.
                for i in 0..<120 {
                    try await Task.sleep(for: .seconds(2))
                    if !callbackExpected, i % 3 == 2 { _ = try? await c.request(["subtype": "mcp_reconnect", "serverName": name], timeout: 30) }
                    try await refreshStatus()
                    if let s = server(name), s.status == .connected || s.status == .failed { break }
                    if signingIn[name] == nil { break } // cancelled
                }
                signingIn[name] = nil
                if server(name)?.status == .connected { MCPManager.announceChange(name) }
            } catch {
                signingIn[name] = nil
                lastError = "Sign-in for \(name) failed: \(describe(error))"
            }
        }
    }

    func cancelSignIn(_ name: String) { signingIn[name] = nil }

    func signOut(_ name: String) {
        perform(name, ["subtype": "mcp_clear_auth", "serverName": name], announce: true)
    }

    func reconnect(_ name: String) {
        perform(name, ["subtype": "mcp_reconnect", "serverName": name], announce: true)
    }

    func setEnabled(_ name: String, _ enabled: Bool) {
        perform(name, ["subtype": "mcp_toggle", "serverName": name, "enabled": enabled], announce: true)
    }

    private func perform(_ name: String, _ body: [String: Any], announce: Bool) {
        busy.insert(name)
        lastError = nil
        Task {
            defer { busy.remove(name) }
            do {
                let c = try await ensureClient()
                try await c.request(body, timeout: 60)
                try await refreshStatus()
                if announce { MCPManager.announceChange(name) }
            } catch {
                lastError = "\(name): \(describe(error))"
            }
        }
    }

    /// Adds a server with `claude mcp add-json`.
    func add(name: String, scope: String, config: [String: Any]) async -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: config), let json = String(data: data, encoding: .utf8) else {
            return "Invalid configuration"
        }
        if let err = await runCLI(["mcp", "add-json", "--scope", scope, name, json]) { return err }
        reload()
        return nil
    }

    /// Removes a server with `claude mcp remove`.
    func remove(_ entry: MCPServerEntry) async -> String? {
        guard let scope = entry.group.cliScope else { return "\(entry.name) is managed by \(entry.group.title) and can't be removed here." }
        if let err = await runCLI(["mcp", "remove", "--scope", scope, entry.name]) { return err }
        toolDetails[entry.name] = nil
        reload()
        return nil
    }

    /// Runs `claude …`; returns an error message, or nil on success.
    private func runCLI(_ args: [String]) async -> String? {
        let r = await ProcessRunner.run(binary, args, environment: environment, directory: directory, timeout: 120)
        if r.succeeded { return nil }
        if r.timedOut { return "claude didn't finish within 2 minutes" }
        let text = (r.stderr + String(decoding: r.stdout, as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "claude exited with \(r.status)" : text
    }

    // MARK: Tool descriptions

    /// Connects to the server directly for `tools/list` (descriptions and parameters).
    func loadToolDetails(_ entry: MCPServerEntry) {
        guard !loadingTools.contains(entry.name) else { return }
        loadingTools.insert(entry.name)
        toolErrors[entry.name] = nil
        let configJSON = entry.configJSON, env = environment, dir = directory
        Task {
            defer { loadingTools.remove(entry.name) }
            do {
                toolDetails[entry.name] = try await MCPToolInspector.listTools(configJSON: configJSON, environment: env, directory: dir)
            } catch {
                toolErrors[entry.name] = describe(error)
            }
        }
    }

    /// Whether Shell can query the server itself (no OAuth, supported transport).
    func canInspect(_ entry: MCPServerEntry) -> Bool {
        switch entry.transport {
        case "stdio": return entry.status != .untrusted
        case "http": return !entry.hasOAuth && entry.status != .needsAuth && entry.group != .claudeai
        default: return false
        }
    }

    private func describe(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if case ClaudeControlClient.ClientError.notRunning = error, let tail = client?.stderrTail.last {
            return "\(text): \(tail)"
        }
        return text
    }

    // MARK: Change notifications

    /// Tells open native Claude sessions to reconnect a server after its auth or state changed.
    static func announceChange(_ name: String) {
        NotificationCenter.default.post(name: .mcpServerDidChange, object: nil, userInfo: ["name": name])
    }
}

extension Notification.Name {
    /// userInfo["name"]: the MCP server whose sign-in or enabled state changed.
    static let mcpServerDidChange = Notification.Name("ShellMCPServerDidChange")
}
