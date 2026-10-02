import Foundation
import FoundationModels

/// Calls into Apple's on-device model (FoundationModels). Each
/// request gets a fresh session so nothing carries over between requests.
/// Errors, guardrail refusals, rate limits and timeouts all come back as nil.
@MainActor
enum OnDeviceModel {
    /// Permissive guardrails: terminal text is full of words like "kill",
    /// "force" and "exploit" that the default guardrails can refuse on.
    private nonisolated static let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)

    /// Generous for a small model on a short answer; a late suggestion is worse than none.
    private nonisolated static let timeout: Duration = .seconds(8)

    static var status: Intelligence.Status {
        switch model.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
        case .unavailable(.modelNotReady): return .modelNotReady
        case .unavailable: return .unavailable
        }
    }

    static func prewarm() {
        LanguageModelSession(model: model).prewarm()
    }

    // MARK: Requests

    static func branchNames(prompt: String) async -> [String] {
        let result = await run(BranchNameIdeas.self, prompt: prompt, options: GenerationOptions(temperature: 0.5)) {
            """
            You name git branches. Given a description of some work, reply with three short branch names.
            Use lowercase words joined by hyphens, five words at most. If the repository's branches use a \
            prefix such as feat/, fix/ or chore/, or a ticket-style prefix, follow the same style; otherwise \
            don't add one. Never include spaces, quotes or punctuation other than hyphens and one slash.
            """
        }
        return result?.names ?? []
    }

    /// One of `ids`, or nil for "none".
    static func choose(prompt: String, ids: [String]) async -> String? {
        let schema = DynamicGenerationSchema(name: "CommandChoice", properties: [
            .init(name: "command", description: "The id of the matching command, or none",
                  schema: DynamicGenerationSchema(name: "CommandID", anyOf: ids + ["none"])),
        ])
        guard let generation = try? GenerationSchema(root: schema, dependencies: []) else { return nil }
        let content = await withTimeout {
            let session = LanguageModelSession(model: model, instructions: """
                You map a user's request in a terminal app to one of the app's commands. \
                Answer with the id of the single best command, or none when no command does what they asked.
                """)
            return try await session.respond(to: prompt, schema: generation, options: GenerationOptions(temperature: 0)).content
        }
        guard let id = try? content?.value(String.self, forProperty: "command"), id != "none" else { return nil }
        return id
    }

    static func commandFix(prompt: String) async -> (command: String, reason: String)? {
        let result = await run(CommandFixIdea.self, prompt: prompt, options: GenerationOptions(temperature: 0)) {
            """
            You help fix failed shell commands on macOS (zsh, BSD userland, Homebrew). Read the command and its \
            error. If a small change to the command would fix it (a typo, a wrong flag or subcommand, a missing \
            argument, the wrong tool), give the corrected command. Keep everything else the same. If the error \
            needs something other than a different command, or you aren't confident, say it isn't fixable. \
            Never suggest deleting files or forcing anything.
            """
        }
        guard let result, result.fixable else { return nil }
        return (result.command, result.reason)
    }

    enum LineKind { case status, name }

    static func line(prompt: String, kind: LineKind) async -> String? {
        switch kind {
        case .status:
            return await run(StatusLine.self, prompt: prompt, options: GenerationOptions(temperature: 0.3)) {
                """
                You summarize what a coding agent is doing for a dashboard. Reply with one line of eight words at \
                most, starting with a verb ending in -ing, such as "Refactoring the auth middleware" or \
                "Waiting for approval to run tests". Mention the concrete thing being worked on.
                """
            }?.line
        case .name:
            return await run(ShortName.self, prompt: prompt, options: GenerationOptions(temperature: 0.5)) {
                """
                You name terminal tabs. Reply with a name of one to three words in Title Case that says what the \
                tab is for, such as "API Server", "Auth Refactor" or "Release Build". Prefer the project or task \
                over generic words like Terminal, Shell or Tab.
                """
            }?.name
        }
    }

    // MARK: Plumbing

    private static func run<T: Generable & Sendable>(_ type: T.Type, prompt: String, options: GenerationOptions,
                                          instructions: () -> String) async -> T? {
        let text = instructions()
        return await withTimeout {
            let session = LanguageModelSession(model: model, instructions: text)
            return try await session.respond(to: prompt, generating: type, options: options).content
        }
    }

    /// Runs `body`, giving up after `timeout`. Failures are logged, not surfaced.
    private static func withTimeout<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                do {
                    return try await body()
                } catch is CancellationError {
                    return nil
                } catch {
                    Log.intelligence.debug("on-device model request failed: \(String(describing: error), privacy: .public)")
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

// MARK: - Output types

@Generable
struct BranchNameIdeas {
    @Guide(description: "Three different git branch names for the work", .count(3))
    var names: [String]
}

@Generable
struct CommandFixIdea {
    @Guide(description: "True only if a corrected command would fix the error")
    var fixable: Bool
    @Guide(description: "The corrected command on one line, or an empty string if not fixable")
    var command: String
    @Guide(description: "Why the command failed, one short sentence of twelve words at most, without repeating the command")
    var reason: String
}

@Generable
struct StatusLine {
    @Guide(description: "What the agent is doing now, eight words at most")
    var line: String
}

@Generable
struct ShortName {
    @Guide(description: "A tab name of one to three words in Title Case")
    var name: String
}
