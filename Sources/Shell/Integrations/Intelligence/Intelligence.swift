import AppKit

/// An optional feature backed by Apple's on-device language model. Each one
/// is off until the user turns it on in Settings › Apple Intelligence.
enum IntelligenceFeature: String, CaseIterable, Identifiable {
    case branchNames, paletteIntents, commandFixes, sessionSummaries, tabNames, commitMessages

    var id: String { rawValue }

    var keyPath: WritableKeyPath<AppSettings, Bool> {
        switch self {
        case .branchNames: \.intelligenceBranchNames
        case .paletteIntents: \.intelligencePaletteIntents
        case .commandFixes: \.intelligenceCommandFixes
        case .sessionSummaries: \.intelligenceSessionSummaries
        case .tabNames: \.intelligenceTabNames
        case .commitMessages: \.intelligenceCommitMessages
        }
    }

    var title: String {
        switch self {
        case .branchNames: "Suggest branch names"
        case .paletteIntents: "Understand plain English in the command palette"
        case .commandFixes: "Suggest a fix when a command fails"
        case .sessionSummaries: "Summarize Claude sessions on the dashboard"
        case .tabNames: "Suggest tab and tab group names"
        case .commitMessages: "Draft commit messages"
        }
    }

    var detail: String {
        switch self {
        case .branchNames:
            "In Start in Worktree…, describe the work (\"fix login redirect on expired session\") and pick from suggested branch names."
        case .paletteIntents:
            "Type what you want (\"split the pane and zoom it\") and the palette offers the matching command."
        case .commandFixes:
            "After a command exits with an error, a corrected command appears as ghost text. Press → to accept it; it never runs on its own."
        case .sessionSummaries:
            "Each session tile gets a one-line summary of what Claude is doing right now."
        case .tabNames:
            "Rename Tab and New Tab Group fill in a name based on the tab's folder, branch and recent commands."
        case .commitMessages:
            "In Review Changes, Write for me drafts a commit message from the staged changes. You edit it before committing."
        }
    }
}

/// Entry point for the on-device model. Everything here degrades to "no
/// suggestion": on macOS before 26, without Apple Intelligence, when a
/// feature is off, or when the model fails, times out or declines.
@MainActor
enum Intelligence {
    enum Status: Equatable {
        case available
        /// macOS before 26.
        /// This Mac can't run Apple Intelligence.
        case deviceNotEligible
        /// Apple Intelligence is off in System Settings.
        case notEnabled
        /// The model is still downloading or preparing.
        case modelNotReady
        case unavailable

        var message: String {
            switch self {
            case .available: "Apple Intelligence is on. These features run on this Mac with Apple's on-device model."
            case .deviceNotEligible: "This Mac doesn't support Apple Intelligence."
            case .notEnabled: "Turn on Apple Intelligence in System Settings to use these features."
            case .modelNotReady: "Apple Intelligence is still getting ready. Try again once the model has downloaded."
            case .unavailable: "Apple Intelligence isn't available right now."
            }
        }
    }

    static var status: Status { OnDeviceModel.status }

    static var isAvailable: Bool { status == .available }

    /// The feature is turned on and the model can run it now.
    static func isEnabled(_ feature: IntelligenceFeature) -> Bool {
        SettingsStore.shared.settings[keyPath: feature.keyPath] && isAvailable
    }

    static var anyFeatureOn: Bool {
        IntelligenceFeature.allCases.contains { SettingsStore.shared.settings[keyPath: $0.keyPath] }
    }

    /// Loads the model ahead of a request the user is likely to make soon.
    static func prewarm(for feature: IntelligenceFeature) {
        guard isEnabled(feature) else { return }
        OnDeviceModel.prewarm()
    }

    // MARK: Features

    /// Up to three new branch names for a description of the work, in the
    /// style of the repository's recent branches. Empty when unavailable.
    static func branchNames(for description: String, recentBranches: [String], existing: Set<String>) async -> [String] {
        guard isEnabled(.branchNames) else { return [] }
        let prompt = IntelligencePrompts.branchNames(description: description, recentBranches: recentBranches)
        let raw = await OnDeviceModel.branchNames(prompt: prompt)
        return IntelligencePrompts.validBranchNames(raw, existing: existing)
    }

    /// The id of the palette command that best matches a plain-English query,
    /// or nil when nothing fits.
    static func paletteIntent(for query: String, choices: [IntelligencePrompts.Choice]) async -> String? {
        guard isEnabled(.paletteIntents), !choices.isEmpty else { return nil }
        let prompt = IntelligencePrompts.paletteIntent(query: query, choices: choices)
        guard let id = await OnDeviceModel.choose(prompt: prompt, ids: choices.map(\.id)) else { return nil }
        return choices.contains(where: { $0.id == id }) ? id : nil
    }

    /// A corrected command for one that just failed, or nil.
    static func commandFix(command: String, exitCode: Int, output: String, directory: String, branch: String?) async -> String? {
        guard isEnabled(.commandFixes), IntelligencePrompts.shouldSuggestFix(exitCode: exitCode, output: output) else { return nil }
        let prompt = IntelligencePrompts.commandFix(command: command, exitCode: exitCode, output: output, directory: directory, branch: branch)
        guard let fix = await OnDeviceModel.commandFix(prompt: prompt) else { return nil }
        return IntelligencePrompts.validatedFix(fix, original: command, output: output)
    }

    /// A short line saying what a Claude session is doing, from the tail of its transcript.
    static func sessionStatus(transcript: String) async -> String? {
        guard isEnabled(.sessionSummaries) else { return nil }
        let prompt = IntelligencePrompts.sessionStatus(transcript: transcript)
        return await OnDeviceModel.line(prompt: prompt, kind: .status).flatMap { IntelligencePrompts.cleanLine($0, maxLength: 80) }
    }

    /// A short name for a tab or a group of tabs.
    static func tabName(context: String, group: Bool) async -> String? {
        guard isEnabled(.tabNames) else { return nil }
        let prompt = IntelligencePrompts.tabName(context: context, group: group)
        return await OnDeviceModel.line(prompt: prompt, kind: .name).flatMap { IntelligencePrompts.cleanLine($0, maxLength: 32) }
    }
}

/// Prompt building and output checking. Pure, so it's unit-tested without the model.
enum IntelligencePrompts {
    struct Choice: Equatable {
        var id: String
        var title: String
    }

    /// Rough budget for text pulled from the terminal or a transcript. The
    /// on-device model's context is about 4K tokens (instructions, schema,
    /// prompt and answer together), and English runs about 4 characters a token.
    static let maxContextCharacters = 6000

    /// Keeps the end of `text` (where errors and the latest activity are),
    /// cut at a line boundary.
    static func tail(_ text: String, maxCharacters: Int = maxContextCharacters) -> String {
        guard text.count > maxCharacters else { return text }
        let cut = String(text.suffix(maxCharacters))
        guard let newline = cut.firstIndex(of: "\n") else { return cut }
        return String(cut[cut.index(after: newline)...])
    }

    // MARK: Branch names

    static func branchNames(description: String, recentBranches: [String]) -> String {
        var prompt = "Describe the work as git branch names.\n\nWork: \(description.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        let examples = recentBranches.prefix(12)
        if !examples.isEmpty {
            prompt += "\nThis repository's recent branches, for naming style:\n" + examples.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        return prompt
    }

    /// Git-valid, lowercase, de-duplicated names that don't already exist; at most three.
    static func validBranchNames(_ names: [String], existing: Set<String>) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in names {
            let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "`'\"."))
            // A name with spaces means the model answered in prose; don't dash it into shape.
            guard lowered.count <= 60, lowered.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  let name = AgentLauncher.branchName(from: lowered),
                  !existing.contains(name), seen.insert(name).inserted else { continue }
            result.append(name)
            if result.count == 3 { break }
        }
        return result
    }

    // MARK: Palette

    static func paletteIntent(query: String, choices: [Choice]) -> String {
        "Pick the command that does what the user asked for, or \"none\" if no command fits.\n\n"
            + "Request: \(query.trimmingCharacters(in: .whitespacesAndNewlines))\n\nCommands:\n"
            + choices.map { "- \($0.id): \($0.title)" }.joined(separator: "\n")
    }

    /// Reads like a request rather than a command name: three or more words.
    static func looksLikeRequest(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).count >= 3
    }

    // MARK: Command fixes

    /// Exit codes from signals the user sent (^C, ^Z, kill) aren't errors to fix.
    static let ignoredExitCodes: Set<Int> = [130, 131, 137, 141, 143, 146, 148]

    /// Whether a failure is worth asking about: not a signal, and it said
    /// something (a silent exit 1 is usually grep/test/diff doing its job),
    /// unless the command wasn't found.
    static func shouldSuggestFix(exitCode: Int, output: String) -> Bool {
        guard exitCode != 0, !ignoredExitCodes.contains(exitCode) else { return false }
        return exitCode == 127 || !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func commandFix(command: String, exitCode: Int, output: String, directory: String, branch: String?) -> String {
        var prompt = "A zsh command on macOS failed.\n\nDirectory: \(directory)\n"
        if let branch { prompt += "Git branch: \(branch)\n" }
        prompt += "Command: \(command)\nExit status: \(exitCode)\n\nOutput (last lines):\n\(tail(output, maxCharacters: 4000))\n"
        return prompt
    }

    /// Words that make a command destructive or privileged. A suggested fix
    /// may only use one if the original command already did.
    static let riskyWords: Set<String> = [
        "rm", "rmdir", "dd", "mkfs", "shred", "diskutil", "chmod", "chown", "kill", "killall", "pkill",
        "--force", "-f", "-rf", "-fr", "--hard", "--force-with-lease", "reset", "clean", "truncate", "mv",
    ]

    /// The fix as it will be offered, or nil when it's empty, unchanged,
    /// malformed, or riskier than what the user ran.
    static func validatedFix(_ fix: String, original: String, output: String) -> String? {
        var cmd = fix.trimmingCharacters(in: .whitespacesAndNewlines)
        if cmd.hasPrefix("$ ") { cmd.removeFirst(2) }
        cmd = cmd.trimmingCharacters(in: CharacterSet(charactersIn: "`")).trimmingCharacters(in: .whitespaces)
        let originalTrimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, cmd.count <= 400, !cmd.contains("\n"), cmd != originalTrimmed,
              !InputEditorView.hasUnterminatedQuote(cmd) else { return nil }
        let before = Set(words(originalTrimmed))
        let after = words(cmd)
        if after.contains(where: { riskyWords.contains($0) && !before.contains($0) }) { return nil }
        // Only reach for sudo when the error was about permissions.
        if after.contains("sudo"), !before.contains("sudo") {
            let o = output.lowercased()
            guard o.contains("permission denied") || o.contains("operation not permitted") || o.contains("must be run as root") else { return nil }
        }
        return cmd
    }

    private static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace || $0 == ";" || $0 == "|" || $0 == "&" || $0 == "(" || $0 == ")" }).map(String.init)
    }

    // MARK: Summaries and names

    static func sessionStatus(transcript: String) -> String {
        "This is the latest activity from a Claude Code session in a terminal. Say what Claude is doing right now.\n\n"
            + tail(transcript, maxCharacters: 3500)
    }

    static func tabName(context: String, group: Bool) -> String {
        (group ? "Name this group of terminal tabs by what they have in common.\n\n" : "Name this terminal tab by what it's being used for.\n\n")
            + tail(context, maxCharacters: 3000)
    }

    /// First line, trimmed of quotes and trailing periods; nil if empty or too long.
    static func cleanLine(_ text: String, maxLength: Int) -> String? {
        var line = text.split(separator: "\n").first.map(String.init) ?? ""
        line = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”"))
        while line.hasSuffix(".") { line.removeLast() }
        line = line.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, line.count <= maxLength else { return nil }
        return line
    }
}
