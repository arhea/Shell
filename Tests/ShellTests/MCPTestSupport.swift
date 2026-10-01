import Foundation
import XCTest
@testable import Shell

/// A stand-in for `claude` that speaks just enough of the stream-json control
/// protocol for `ClaudeControlClient` and `MCPManager`. It's a zsh script in a
/// temp folder; that folder doubles as its state:
///
/// - `<subtype>.json`: the response body for a control request (default `{}`);
///   `<subtype>.<n>.json` overrides it for the n-th request of that subtype.
/// - `<subtype>.error`: answer with an error response carrying the file's text.
/// - `<subtype>.silent`: never answer. `<subtype>.exit`: exit instead of answering.
/// - `stderr.txt`: written to stderr at launch. `preamble.txt`: written to stdout at launch.
/// - `cli.status` / `cli.stderr`: exit status and stderr of `claude mcp …`.
///
/// It logs control requests to `requests.log`, `claude mcp …` arguments to
/// `cli.log`, and its launch arguments, directory and environment to `launch.log`.
struct FakeClaude {
    let dir: URL
    var binary: String { dir.appendingPathComponent("claude").path }

    init(in parent: URL) throws {
        dir = parent.appendingPathComponent("fake-claude-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = #"""
        #!/bin/zsh -f
        dir=${0:A:h}
        if [[ $1 == mcp ]]; then
          print -r -- "$*" >> $dir/cli.log
          [[ -f $dir/cli.stderr ]] && print -rn -- "$(<$dir/cli.stderr)" >&2
          exit ${$(cat $dir/cli.status 2>/dev/null):-0}
        fi
        { print -r -- "args: $*"; print -r -- "pwd: $PWD"; env } > $dir/launch.log
        [[ -f $dir/stderr.txt ]] && print -r -- "$(<$dir/stderr.txt)" >&2
        [[ -f $dir/preamble.txt ]] && print -r -- "$(<$dir/preamble.txt)"
        typeset -A count
        re_id='"request_id":"([^"]*)"'
        re_sub='"subtype":"([^"]*)"'
        while IFS= read -r line; do
          print -r -- "$line" >> $dir/requests.log
          id=''; sub=''
          [[ $line =~ $re_id ]] && id=$match[1]
          [[ $line =~ $re_sub ]] && sub=$match[1]
          [[ $line == *'"type":"control_response"'* ]] && continue
          (( count[$sub]++ ))
          [[ -f $dir/$sub.exit ]] && exit 3
          [[ -f $dir/$sub.silent ]] && continue
          if [[ -f $dir/$sub.error ]]; then
            print -r -- "{\"type\":\"control_response\",\"response\":{\"subtype\":\"error\",\"request_id\":\"$id\",\"error\":\"$(<$dir/$sub.error)\"}}"
            continue
          fi
          body='{}'
          if [[ -f $dir/$sub.$count[$sub].json ]]; then body=$(<$dir/$sub.$count[$sub].json)
          elif [[ -f $dir/$sub.json ]]; then body=$(<$dir/$sub.json); fi
          print -r -- "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"$id\",\"response\":$body}}"
        done
        """#
        try script.write(to: dir.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary)
    }

    func set(_ file: String, _ contents: String) throws {
        try contents.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    /// Sets the `mcp_status` answer to these servers.
    func setStatus(_ servers: [[String: Any]], request n: Int? = nil) throws {
        let data = try JSONSerialization.data(withJSONObject: ["mcpServers": servers])
        try set(n.map { "mcp_status.\($0).json" } ?? "mcp_status.json", String(decoding: data, as: UTF8.self))
    }

    func log(_ file: String) -> String {
        (try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)) ?? ""
    }

    /// Control requests received so far, decoded.
    var requests: [[String: Any]] {
        log("requests.log").split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    /// The `request` bodies of control requests with this subtype.
    func requests(_ subtype: String) -> [[String: Any]] {
        requests.compactMap { $0["request"] as? [String: Any] }.filter { $0["subtype"] as? String == subtype }
    }

    /// A minimal environment: no PATH lookups of real tools beyond the system's.
    var environment: [String: String] { ["PATH": "/usr/bin:/bin", "FAKE_MARKER": "1"] }
}

/// A stdio MCP server (zsh) answering `initialize` and a two-page `tools/list`.
/// Its first argument picks a behavior: `ok`, `initerror`, `listerror`, `exit`.
/// Tool descriptions echo `$GREETING` and the second argument, to check
/// environment and argument expansion.
enum FakeMCPServer {
    static func write(in dir: URL, name: String = "fake-mcp") throws -> String {
        let script = #"""
        #!/bin/zsh -f
        mode=${1:-ok}
        re_id='"id":([0-9]+)'
        while IFS= read -r line; do
          [[ $line =~ $re_id ]] || continue
          id=$match[1]
          if [[ $line == *'"initialize"'* ]]; then
            [[ $mode == exit ]] && exit 0
            if [[ $mode == initerror ]]; then
              print -r -- "{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":{\"message\":\"bad init\"}}"
              continue
            fi
            print -r -- 'not json at all'
            print -r -- '{"jsonrpc":"2.0","method":"notifications/message","params":{}}'
            print -r -- "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"protocolVersion\":\"2025-06-18\"}}"
          elif [[ $line == *'tools'*'list'* ]]; then
            if [[ $mode == listerror ]]; then
              print -r -- "{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":{}}"
            elif [[ $line == *'"cursor":"page2"'* ]]; then
              print -r -- "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"tools\":[{\"name\":\"second\",\"description\":\"arg $2\"}]}}"
            else
              print -r -- "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"nextCursor\":\"page2\",\"tools\":[{\"name\":\"first\",\"description\":\"hello $GREETING\",\"annotations\":{\"readOnlyHint\":true},\"inputSchema\":{\"type\":\"object\",\"required\":[\"q\"],\"properties\":{\"q\":{\"type\":\"string\",\"description\":\"Query\"},\"limit\":{\"type\":\"integer\"}}}}]}}"
            fi
          fi
        done
        """#
        let url = dir.appendingPathComponent(name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }
}

/// Canned server dictionaries in the shape `mcp_status` reports them.
enum MCPFixtures {
    static func server(_ name: String, status: String = "connected", scope: String = "user", source: String = "",
                       config: [String: Any] = ["type": "http", "url": "https://mcp.example.com/mcp"],
                       tools: [[String: Any]] = [], error: String? = nil, info: [String: Any]? = nil) -> [String: Any] {
        var s: [String: Any] = ["name": name, "status": status, "scope": scope, "source": source, "config": config, "tools": tools]
        if let error { s["error"] = error }
        if let info { s["serverInfo"] = info }
        return s
    }

    /// One server in every group and most states.
    static var all: [[String: Any]] {
        [
            server("repo-db", scope: "project", config: ["command": "/usr/bin/true", "args": ["--db"], "env": ["TOKEN": "x"]],
                   tools: [["name": "query", "annotations": ["readOnlyHint": true]], ["name": "drop", "annotations": ["destructiveHint": true]]],
                   info: ["title": "Repo DB", "version": "1.2", "description": "Database access", "websiteUrl": "https://db.example.com",
                          "icons": [["src": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="]]]),
            server("local-files", status: "failed", scope: "local", config: ["type": "stdio", "command": "files-mcp"], error: "spawn ENOENT"),
            server("linear", status: "needs-auth", scope: "user", config: ["type": "http", "url": "https://mcp.linear.app/mcp", "headers": ["X-Key": "1"]],
                   tools: [["name": "list_issues"]]),
            server("notes", status: "disabled", scope: "user", config: ["type": "sse", "url": "https://notes.example.com/sse"]),
            server("plugin:takt-engineering:github", scope: "dynamic", source: "plugin", config: ["type": "http", "url": "https://gh.example.com", "oauth": ["clientId": "x"]],
                   tools: [["name": "get_pr"]]),
            server("claude.ai Notion", scope: "claudeai", source: "claudeai", config: ["type": "claudeai-proxy", "url": "https://claude.ai/proxy"],
                   tools: [["name": "search"]]),
            server("mystery", scope: "dynamic", source: "sdk", config: ["type": "ws"]),
        ]
    }
}

extension XCTestCase {
    /// `waitUntil` for async tests: main-actor tasks the code under test
    /// started only run while the test awaits, not while it spins the run loop.
    @MainActor
    func assertEventually(timeout: TimeInterval = 5, _ message: String = "condition never held",
                          file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail(message, file: file, line: line); return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A manager pointed at a fake `claude`, trusting (or not) its directory.
    @MainActor
    func makeMCPManager(_ fake: FakeClaude, directory: URL, trusted: Bool = true) -> MCPManager {
        let manager = MCPManager(directory: directory.path, binary: fake.binary, environment: fake.environment)
        manager.isTrusted = { _ in trusted }
        addTeardownBlock { @MainActor in manager.stop() }
        return manager
    }
}
