import Foundation

/// Quoting for command lines Shell builds (worktree commands, `cd` into a
/// folder, pasted paths). An allowlist: anything but plain path characters is
/// single-quoted, including empty strings, newlines and tabs.
enum ShellQuote {
    private static let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./@%+=:,-")

    static func quote(_ s: String) -> String {
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A path with the home folder shown as `~` (left unquoted so it expands).
    static func path(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path.hasPrefix(home + "/") { return "~/" + quote(String(path.dropFirst(home.count + 1))) }
        return quote(path)
    }
}
