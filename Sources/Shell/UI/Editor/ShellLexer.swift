import Foundation

/// A small shell tokenizer for syntax highlighting and word boundaries in the
/// input editor. It is intentionally forgiving: unterminated quotes simply run
/// to the end of the buffer.
enum ShellLexer {
    enum Kind {
        case command, argument, option, string, variable, operatorToken, comment, redirect, assignment
    }

    struct Token {
        var kind: Kind
        var range: NSRange
        var text: String
    }

    private static let operatorChars: Set<Character> = ["|", "&", ";", "(", ")", "<", ">"]
    private static let commandPrefixes: Set<String> = ["sudo", "time", "nohup", "exec", "command", "builtin", "env", "nice", "caffeinate", "noglob", "xargs"]

    static func tokenize(_ text: String) -> [Token] {
        let chars = Array(text.utf16)
        var tokens: [Token] = []
        var i = 0
        var expectCommand = true
        let ns = text as NSString

        func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
        func ch(_ c: UInt16) -> Character { Character(UnicodeScalar(c) ?? " ") }

        while i < chars.count {
            let c = chars[i]
            if isSpace(c) {
                if c == 10 { expectCommand = true }
                i += 1
                continue
            }
            // Comments only start at word boundaries.
            if c == 35 /* # */ && (i == 0 || isSpace(chars[i - 1])) {
                let r = NSRange(location: i, length: chars.count - i)
                tokens.append(Token(kind: .comment, range: r, text: ns.substring(with: r)))
                break
            }
            if operatorChars.contains(ch(c)) {
                var j = i + 1
                while j < chars.count, operatorChars.contains(ch(chars[j])) { j += 1 }
                let r = NSRange(location: i, length: j - i)
                let op = ns.substring(with: r)
                let isRedirect = op.contains("<") || op.contains(">")
                tokens.append(Token(kind: isRedirect ? .redirect : .operatorToken, range: r, text: op))
                if !isRedirect { expectCommand = true }
                i = j
                continue
            }
            // A word: runs until unquoted whitespace/operator.
            let start = i
            var quote: UInt16 = 0
            var sawQuote = false
            var sawDollar = false
            while i < chars.count {
                let d = chars[i]
                if quote != 0 {
                    if d == 92 /* \ */ && quote == 34 && i + 1 < chars.count { i += 2; continue }
                    if d == quote { quote = 0 }
                    i += 1
                    continue
                }
                if d == 92 && i + 1 < chars.count { i += 2; continue }
                if d == 34 || d == 39 || d == 96 { quote = d; sawQuote = true; i += 1; continue }
                if d == 36 { sawDollar = true }
                if isSpace(d) || operatorChars.contains(ch(d)) { break }
                i += 1
            }
            let r = NSRange(location: start, length: i - start)
            let word = ns.substring(with: r)
            let kind: Kind
            if expectCommand {
                if word.contains("="), !word.hasPrefix("="), let eq = word.firstIndex(of: "="),
                   word[..<eq].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                    kind = .assignment
                } else {
                    kind = .command
                    expectCommand = commandPrefixes.contains(word)
                }
            } else if word.hasPrefix("-") {
                kind = .option
            } else if sawQuote && (word.first == "\"" || word.first == "'") {
                kind = .string
            } else if sawDollar && word.hasPrefix("$") {
                kind = .variable
            } else {
                kind = .argument
            }
            tokens.append(Token(kind: kind, range: r, text: word))
        }
        return tokens
    }

    /// The UTF-16 range of the word being typed at `cursor` (start..cursor).
    static func currentWordRange(in text: String, cursor: Int) -> NSRange {
        let chars = Array(text.utf16.prefix(cursor))
        var wordStart = 0
        var quote: UInt16 = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quote != 0 {
                if c == 92 && quote == 34 && i + 1 < chars.count { i += 2; continue }
                if c == quote { quote = 0 }
                i += 1
                continue
            }
            if c == 92 && i + 1 < chars.count { i += 2; continue }
            if c == 34 || c == 39 { quote = c; i += 1; continue }
            if c == 32 || c == 9 || c == 10 || operatorChars.contains(Character(UnicodeScalar(c) ?? " ")) {
                wordStart = i + 1
            }
            i += 1
        }
        return NSRange(location: wordStart, length: chars.count - wordStart)
    }

    /// True if the cursor is positioned where a command name is expected.
    static func isCommandPosition(in text: String, cursor: Int) -> Bool {
        let before = String(decoding: Array(text.utf16.prefix(cursor)), as: UTF16.self)
        let tokens = tokenize(before)
        let word = currentWordRange(in: text, cursor: cursor)
        let complete = tokens.filter { $0.range.location + $0.range.length <= word.location }
        guard let last = complete.last else { return true }
        if last.kind == .operatorToken { return true }
        if last.kind == .command { return commandPrefixes.contains(last.text) }
        return false
    }
}

/// Knows which command names exist so the editor can flag typos.
@MainActor
final class CommandIndex {
    static let shared = CommandIndex()

    private var executables: Set<String> = []
    private var shellNames: Set<String> = []
    private var scannedPath = ""

    static let builtins: Set<String> = [
        "alias", "autoload", "bg", "bindkey", "break", "builtin", "bye", "cd", "chdir", "command", "compadd", "continue",
        "declare", "dirs", "disable", "disown", "echo", "emulate", "enable", "eval", "exec", "exit", "export", "false",
        "fc", "fg", "float", "functions", "getopts", "hash", "history", "integer", "jobs", "kill", "let", "limit",
        "local", "logout", "noglob", "popd", "print", "printf", "pushd", "pwd", "r", "read", "readonly", "rehash",
        "return", "sched", "set", "setopt", "shift", "source", "suspend", "test", "times", "trap", "true", "ttyctl",
        "type", "typeset", "ulimit", "umask", "unalias", "unfunction", "unhash", "unlimit", "unset", "unsetopt",
        "vared", "wait", "whence", "where", "which", "zcompile", "zle", "zmodload", "zparseopts", "zstyle", ".", ":",
        "[", "[[", "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "select",
        "function", "time", "repeat", "{", "}", "!", "coproc", "nocorrect",
    ]

    private init() {
        scan(path: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    func update(path: String?, aliases: String?, functions: String?) {
        if let path, path != scannedPath { scan(path: path) }
        var names = Set<String>()
        for list in [aliases, functions] {
            for n in (list ?? "").split(separator: " ") { names.insert(String(n)) }
        }
        if !names.isEmpty { shellNames = names }
    }

    private func scan(path: String) {
        scannedPath = path
        let dirs = path.split(separator: ":").map(String.init)
        Task.detached(priority: .utility) {
            var found = Set<String>()
            let fm = FileManager.default
            for dir in dirs {
                guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for item in items { found.insert(item) }
            }
            let result = found
            await MainActor.run { CommandIndex.shared.executables.formUnion(result) }
        }
    }

    func isKnown(_ name: String, cwd: String?) -> Bool {
        if name.isEmpty { return true }
        if Self.builtins.contains(name) || shellNames.contains(name) || executables.contains(name) { return true }
        if name.contains("/") {
            let expanded = (name as NSString).expandingTildeInPath
            let full = expanded.hasPrefix("/") ? expanded : ((cwd ?? "") as NSString).appendingPathComponent(expanded)
            return FileManager.default.isExecutableFile(atPath: full)
        }
        // Quoted/variable commands can't be judged; don't flag them.
        return name.contains("$") || name.contains("\"") || name.contains("'") || name.contains("=")
    }

    func path(for name: String) -> String? {
        for dir in scannedPath.split(separator: ":") {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}
