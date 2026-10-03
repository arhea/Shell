import Foundation
import FoundationModels

/// "Write for me" in Review Changes: a commit message drafted on device from
/// the staged diff. Off unless Settings › Apple Intelligence › Draft commit
/// messages is on; nil whenever the model is unavailable, slow or declines.
@MainActor
enum CommitMessageDraft {
    static var isAvailable: Bool { Intelligence.isEnabled(.commitMessages) }

    static func draft(diff: String, recentSubjects: [String]) async -> String? {
        guard isAvailable else { return nil }
        let prompt = prompt(diff: diff, recentSubjects: recentSubjects)
        guard let result = await generate(prompt) else { return nil }
        return format(subject: result.subject, body: result.body)
    }

    // MARK: Pure parts (unit-tested)

    /// The staged diff trimmed to fit the model's small context.
    static func prompt(diff: String, recentSubjects: [String]) -> String {
        var p = "Write a git commit message for these staged changes.\n"
        let examples = recentSubjects.prefix(8)
        if !examples.isEmpty {
            p += "\nRecent commit subjects in this repository, for style:\n" + examples.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        let limit = 3500
        let trimmed = diff.count > limit ? String(diff.prefix(limit)) + "\n[diff truncated]" : diff
        return p + "\nDiff:\n" + trimmed
    }

    /// Subject (one line, no trailing period, at most 72 characters), a blank
    /// line, then the wrapped body. Nil when there's no usable subject.
    static func format(subject: String, body: String) -> String? {
        var s = subject.split(separator: "\n").first.map(String.init) ?? ""
        s = s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        while s.hasSuffix(".") { s.removeLast() }
        guard !s.isEmpty else { return nil }
        if s.count > 72 { s = String(s.prefix(72)).trimmingCharacters(in: .whitespaces) }
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty ? s : s + "\n\n" + b
    }

    // MARK: Model

    private nonisolated static let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)

    private static func generate(_ prompt: String) async -> CommitMessageIdea? {
        await withTaskGroup(of: CommitMessageIdea?.self) { group in
            group.addTask {
                let session = LanguageModelSession(model: model, instructions: """
                    You write git commit messages. Reply with a short imperative subject line (under 72 characters) \
                    and a body of one to three sentences saying what changed and why. If the repository's recent \
                    subjects use a prefix such as feat:, fix: or chore:, use the same style. Describe the change, \
                    not the diff mechanics.
                    """)
                do {
                    return try await session.respond(to: prompt, generating: CommitMessageIdea.self,
                                                     options: GenerationOptions(temperature: 0.3)).content
                } catch {
                    Log.intelligence.debug("commit message draft failed: \(String(describing: error), privacy: .public)")
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

@Generable
struct CommitMessageIdea {
    @Guide(description: "The commit subject line, imperative, under 72 characters")
    var subject: String
    @Guide(description: "One to three sentences explaining what changed and why")
    var body: String
}
