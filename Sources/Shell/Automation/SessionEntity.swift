import AppIntents
import AppKit
import Foundation

/// A Shell pane, as Shortcuts sees it: a snapshot of the session's state
/// taken when the entity is resolved. The ID is the session's UUID, which
/// session restore keeps across relaunches.
struct SessionEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Shell Session", numericFormat: "\(placeholder: .int) Shell sessions")
    static let defaultQuery = SessionQuery()

    let id: UUID

    @Property(title: "Title")
    var title: String

    @Property(title: "Directory")
    var directory: String

    @Property(title: "Git Branch")
    var branch: String?

    @Property(title: "Running Command")
    var runningCommand: String?

    @Property(title: "Last Command")
    var lastCommand: String?

    @Property(title: "Last Exit Code")
    var lastExitCode: Int?

    @Property(title: "Is Busy")
    var isBusy: Bool

    @Property(title: "Is Focused")
    var isFocused: Bool

    @Property(title: "Agent Status")
    var agentStatus: AgentStatusAppEnum

    @Property(title: "Agent")
    var agentName: String?

    @Property(title: "Agent Message")
    var agentMessage: String?

    var displayRepresentation: DisplayRepresentation {
        let subtitle = [abbreviated(directory), branch].compactMap { $0 }.joined(separator: " · ")
        return DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)", image: .init(systemName: "terminal"))
    }

    private func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    @MainActor
    init(_ session: TerminalSession) {
        id = session.id
        title = ShellAutomation.location(of: session)?.tab.title ?? session.displayTitle
        directory = session.workingDirectory ?? NSHomeDirectory()
        branch = session.gitBranch
        runningCommand = session.state == .running ? session.runningCommand : nil
        lastCommand = session.lastCommand
        lastExitCode = session.lastExitCode
        isBusy = session.isBusy
        isFocused = session.isFocused && NSApp.isActive
        agentStatus = AgentStatusAppEnum(session.agent)
        agentName = session.agent?.kind.displayName
        switch session.agent {
        case .needsInput(_, let msg)?, .finished(_, let msg)?: agentMessage = msg
        default: agentMessage = nil
        }
    }
}

enum AgentStatusAppEnum: String, AppEnum {
    case none, working, needsInput, finished

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Agent Status"
    static let caseDisplayRepresentations: [AgentStatusAppEnum: DisplayRepresentation] = [
        .none: "No Agent",
        .working: "Working",
        .needsInput: "Needs Input",
        .finished: "Finished",
    ]

    var label: String {
        switch self {
        case .none: "No Agent"
        case .working: "Working"
        case .needsInput: "Needs Input"
        case .finished: "Finished"
        }
    }

    init(_ status: AgentStatus?) {
        switch status {
        case .working?: self = .working
        case .needsInput?: self = .needsInput
        case .finished?: self = .finished
        case nil: self = .none
        }
    }
}

// MARK: - Query

/// Resolves sessions by ID and powers Shortcuts' "Find Shell Sessions" action
/// (filter by title, directory, branch, agent status or busy state).
struct SessionQuery: EntityPropertyQuery {
    typealias ComparatorMappingType = @Sendable (SessionEntity) -> Bool

    static let findIntentDescription: IntentDescription? = IntentDescription(
        "Finds open Shell sessions (panes), for example the ones where an agent needs input.",
        categoryName: "Sessions")

    // Built once and never mutated; the builder's types just aren't marked
    // Sendable. The metadata extractor needs this literal `static let` form.
    nonisolated(unsafe) static let properties = QueryProperties {
        Property(\SessionEntity.$title) {
            EqualToComparator { value in { @Sendable entity in entity.title == value } }
            ContainsComparator { value in { @Sendable entity in entity.title.localizedCaseInsensitiveContains(value) } }
        }
        Property(\SessionEntity.$directory) {
            EqualToComparator { value in { @Sendable entity in entity.directory == Self.expand(value) } }
            ContainsComparator { value in { @Sendable entity in entity.directory.localizedCaseInsensitiveContains(value) } }
            HasPrefixComparator { value in { @Sendable entity in entity.directory.hasPrefix(Self.expand(value)) } }
        }
        Property(\SessionEntity.$branch) {
            EqualToComparator { value in { @Sendable entity in entity.branch == value } }
            ContainsComparator { value in { @Sendable entity in entity.branch?.localizedCaseInsensitiveContains(value) ?? false } }
        }
        Property(\SessionEntity.$agentStatus) {
            EqualToComparator { value in { @Sendable entity in entity.agentStatus == value } }
            NotEqualToComparator { value in { @Sendable entity in entity.agentStatus != value } }
        }
        Property(\SessionEntity.$isBusy) {
            EqualToComparator { value in { @Sendable entity in entity.isBusy == value } }
        }
    }

    nonisolated(unsafe) static let sortingOptions = SortingOptions {
        SortableBy(\SessionEntity.$title)
        SortableBy(\SessionEntity.$directory)
    }

    private static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [SessionEntity] {
        identifiers.compactMap { SessionRegistry.shared.session($0) }.map(SessionEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [SessionEntity] {
        ShellAutomation.orderedSessions.map(SessionEntity.init)
    }

    func entities(matching comparators: [ComparatorMappingType], mode: ComparatorMode,
                  sortedBy: [Sort<SessionEntity>], limit: Int?) async throws -> [SessionEntity] {
        let all = await MainActor.run { ShellAutomation.orderedSessions.map(SessionEntity.init) }
        var result = all.filter { entity in
            switch mode {
            case .and: comparators.allSatisfy { $0(entity) }
            case .or: comparators.isEmpty || comparators.contains { $0(entity) }
            @unknown default: comparators.allSatisfy { $0(entity) }
            }
        }
        for sort in sortedBy.reversed() {
            let key: (SessionEntity) -> String
            switch sort.by {
            case \SessionEntity.$title: key = \.title
            case \SessionEntity.$directory: key = \.directory
            default: continue
            }
            result.sort { a, b in
                let order = key(a).localizedStandardCompare(key(b))
                return sort.order == .ascending ? order == .orderedAscending : order == .orderedDescending
            }
        }
        if let limit { result = Array(result.prefix(limit)) }
        return result
    }
}

// MARK: - Results

/// The result of Run Command with Wait for Completion on.
struct CommandResultEntity: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Shell Command Result"

    @Property(title: "Command")
    var command: String

    @Property(title: "Exit Code")
    var exitCode: Int?

    @Property(title: "Succeeded")
    var succeeded: Bool

    @Property(title: "Output")
    var output: String

    @Property(title: "Duration (Seconds)")
    var duration: Double?

    @Property(title: "Session")
    var session: SessionEntity?

    init() {
        command = ""
        succeeded = false
        output = ""
    }

    var displayRepresentation: DisplayRepresentation {
        let status = exitCode.map { $0 == 0 ? "succeeded" : "failed (exit \($0))" } ?? "finished"
        return DisplayRepresentation(title: "\(command)", subtitle: "\(status)")
    }
}

/// What Wait for Agent saw.
struct AgentUpdateEntity: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Agent Update"

    @Property(title: "Status")
    var status: AgentStatusAppEnum

    @Property(title: "Agent")
    var agent: String

    @Property(title: "Message")
    var message: String?

    @Property(title: "Session")
    var session: SessionEntity?

    init() {
        status = .none
        agent = ""
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(agent): \(status.label)", subtitle: "\(message ?? "")")
    }
}
