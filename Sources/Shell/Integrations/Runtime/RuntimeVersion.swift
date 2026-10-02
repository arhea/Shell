import Foundation

/// The language runtime a directory declares, for the prompt's runtime chip
/// ("node 22.9", "python 3.12", "go 1.23").
struct RuntimeMarker: Equatable, Sendable {
    enum Kind: String, Sendable { case node, python, go }
    var kind: Kind
    /// The version the project asks for, as written (".nvmrc", "engines", "go.mod").
    var declared: String?
    /// The directory holding the marker file.
    var directory: String
}

/// Finds and parses runtime markers. File reads and the one `node --version`
/// run happen off the main thread; results are cached per directory and PATH.
enum RuntimeDetection {
    /// Walks up from `directory` (to `stop`, at most `maxLevels`) and returns
    /// the nearest marker. Node markers win over Python, Python over Go, in
    /// the same folder.
    static func findMarker(from directory: String, stop: String = NSHomeDirectory(), maxLevels: Int = 12,
                           read: (String) -> String?) -> RuntimeMarker? {
        var dir = (directory as NSString).standardizingPath
        for _ in 0..<maxLevels {
            func file(_ name: String) -> String? { read((dir as NSString).appendingPathComponent(name)) }
            if let v = file(".nvmrc") ?? file(".node-version") {
                return RuntimeMarker(kind: .node, declared: firstToken(v), directory: dir)
            }
            if let pkg = file("package.json") {
                return RuntimeMarker(kind: .node, declared: packageEngine(pkg), directory: dir)
            }
            if let v = file(".python-version") {
                return RuntimeMarker(kind: .python, declared: firstToken(v), directory: dir)
            }
            if let mod = file("go.mod") {
                return RuntimeMarker(kind: .go, declared: goVersion(mod), directory: dir)
            }
            if dir == stop || dir == "/" { break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// The first non-comment word of a version file ("v22.9.0", "lts/iron").
    static func firstToken(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let word = line.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            if !word.isEmpty, !word.hasPrefix("#") { return word }
        }
        return nil
    }

    /// `engines.node` from package.json (">=20"), when present.
    static func packageEngine(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let engines = obj["engines"] as? [String: Any],
              let node = engines["node"] as? String, !node.isEmpty else { return nil }
        return node
    }

    /// The `go 1.23.0` directive of a go.mod.
    static func goVersion(_ mod: String) -> String? {
        for line in mod.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count >= 2, parts[0] == "go" { return String(parts[1]) }
        }
        return nil
    }

    /// "v22.9.0" → "22.9"; "3.12.4" → "3.12"; "1.23" stays; anything else nil.
    static func shortVersion(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") { s.removeFirst() }
        let parts = s.split(separator: ".")
        guard let major = parts.first, !major.isEmpty, major.allSatisfy(\.isNumber) else { return nil }
        if parts.count >= 2, parts[1].allSatisfy(\.isNumber) { return "\(major).\(parts[1])" }
        return String(major)
    }

    /// The chip text: the resolved version when known, else what's declared
    /// when it's a plain version, else just the runtime's name.
    static func label(for marker: RuntimeMarker, resolved: String?) -> String {
        if let v = resolved.flatMap(shortVersion) { return "\(marker.kind.rawValue) \(v)" }
        if let v = marker.declared.flatMap(shortVersion) { return "\(marker.kind.rawValue) \(v)" }
        return marker.kind.rawValue
    }
}

/// Caches the runtime label per directory. `label(for:)` never blocks: it
/// returns what's cached and resolves in the background.
@MainActor
final class RuntimeDetector {
    static let shared = RuntimeDetector()

    private struct Entry { var label: String?; var at: Date }
    private var byDirectory: [String: Entry] = [:]
    /// `node --version` per PATH (the resolved binary doesn't depend on the folder
    /// unless a version manager's shim reads it, which the folder key covers).
    private var nodeVersions: [String: (version: String?, at: Date)] = [:]
    private var inFlight: Set<String> = []
    private let ttl: TimeInterval = 300

    /// The cached label, or nil while it's being worked out.
    func cachedLabel(for directory: String) -> String?? {
        guard let e = byDirectory[directory], Date().timeIntervalSince(e.at) < ttl else { return nil }
        return .some(e.label)
    }

    /// Resolves the label for `directory` (cached for five minutes).
    func label(for directory: String, environment: [String: String]) async -> String? {
        if let cached = cachedLabel(for: directory) { return cached }
        guard !inFlight.contains(directory) else { return nil }
        inFlight.insert(directory)
        defer { inFlight.remove(directory) }
        let marker = await Task.detached(priority: .utility) {
            RuntimeDetection.findMarker(from: directory) { path in
                // Small files only: a huge package.json isn't worth reading for a chip.
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      (attrs[.type] as? FileAttributeType) == .typeRegular,
                      (attrs[.size] as? Int ?? 0) < 512 * 1024 else { return nil }
                return try? String(contentsOfFile: path, encoding: .utf8)
            }
        }.value
        var label: String?
        if let marker {
            var resolved: String?
            if marker.kind == .node { resolved = await nodeVersion(in: marker.directory, environment: environment) }
            label = RuntimeDetection.label(for: marker, resolved: resolved)
        }
        byDirectory[directory] = Entry(label: label, at: Date())
        if byDirectory.count > 500 { byDirectory.removeAll() }
        return label
    }

    private func nodeVersion(in directory: String, environment: [String: String]) async -> String? {
        let key = directory + "\u{0}" + (environment["PATH"] ?? "")
        if let c = nodeVersions[key], Date().timeIntervalSince(c.at) < ttl { return c.version }
        guard let node = GitRepository.findExecutable("node", environment: environment) else { return nil }
        let result = await ProcessRunner.run(node, ["--version"], environment: environment, directory: directory, timeout: 5)
        let version = result.succeeded ? String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil
        nodeVersions[key] = (version, Date())
        return version
    }
}
