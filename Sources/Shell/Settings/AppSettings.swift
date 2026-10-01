import AppKit
import Observation

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum CursorStyle: String, Codable, CaseIterable, Identifiable {
    case block, bar, underline
    case hollow = "block_hollow"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .block: "Block"
        case .bar: "Bar"
        case .underline: "Underline"
        case .hollow: "Hollow Block"
        }
    }
}

enum OptionKeyMode: String, Codable, CaseIterable, Identifiable {
    case normal = "false", meta = "true", left, right
    var id: String { rawValue }
    var title: String {
        switch self {
        case .normal: "Normal (type special characters)"
        case .meta: "Esc+ (both Option keys)"
        case .left: "Esc+ (left Option only)"
        case .right: "Esc+ (right Option only)"
        }
    }
}

enum InputPosition: String, Codable, CaseIterable, Identifiable {
    case bottom, top
    var id: String { rawValue }
    var title: String { self == .bottom ? "Pin to bottom" : "Pin to top" }
}

enum PromptStyle: String, Codable, CaseIterable, Identifiable {
    /// A compact one-line header managed by Shell (cwd, git branch).
    case compact
    /// The user's own zsh prompt (PS1 / Oh My Zsh theme / powerlevel10k).
    case shell
    var id: String { rawValue }
    var title: String { self == .compact ? "Compact (directory, branch)" : "My zsh prompt (PS1 / theme)" }
}

/// The right sidebar's tab. Decoding is lenient: unknown or retired values
/// (the old "prs" tab) fall back instead of failing the whole settings file.
enum SidebarTab: String, Codable, CaseIterable {
    case files, worktrees, github
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = raw == "prs" ? .github : SidebarTab(rawValue: raw) ?? .github
    }
}

/// The GitHub sidebar tab's section.
enum GitHubSection: String, Codable, CaseIterable {
    case prs, actions
    init(from decoder: Decoder) throws {
        self = GitHubSection(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .prs
    }
}

/// How wide the native Claude view's chat column (composer and transcript) gets.
enum ChatComposerWidth: String, Codable, CaseIterable, Identifiable {
    /// Capped at `centeredMaxWidth` and centered in the pane.
    case centered
    /// Fills the pane.
    case full
    static let centeredMaxWidth: CGFloat = 1200
    var id: String { rawValue }
    var title: String { self == .centered ? "Centered" : "Full width" }
    init(from decoder: Decoder) throws {
        self = ChatComposerWidth(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .centered
    }
}

/// When the Claude Sessions entry is pinned to the top of the tab sidebar
/// (and the front of the horizontal tab bar).
enum ClaudeSessionsButton: String, Codable, CaseIterable, Identifiable {
    /// Whenever Claude Code is installed.
    case always
    /// Only while a Claude Code session is running.
    case whenActive
    case never
    var id: String { rawValue }
    var title: String {
        switch self {
        case .always: "Always"
        case .whenActive: "When sessions are active"
        case .never: "Never"
        }
    }
    init(from decoder: Decoder) throws {
        self = ClaudeSessionsButton(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .always
    }
}

/// How the native Claude view draws file edits.
enum DiffStyle: String, Codable, CaseIterable, Identifiable {
    /// Side by side when the pane is wide enough, else unified.
    case automatic
    case sideBySide
    case unified
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .sideBySide: "Side by side"
        case .unified: "Unified"
        }
    }
}

/// How the native Claude view shows tool calls in the transcript.
enum ToolCallDisplay: String, Codable, CaseIterable, Identifiable {
    /// Every run of tool calls folds into one summary row.
    case collapseAll
    /// Earlier turns fold; the latest turn shows each call.
    case collapsePrevious
    /// Every tool call on its own row.
    case showAll
    var id: String { rawValue }
    var title: String {
        switch self {
        case .collapseAll: "Collapse all tool calls"
        case .collapsePrevious: "Collapse previous turns, show the current turn"
        case .showAll: "Show all tool calls"
        }
    }
}

/// What `claude` typed at a Shell prompt opens.
enum ClaudeLaunchMode: String, Codable, CaseIterable, Identifiable {
    /// Ask each time (with a "remember my choice" option).
    case ask
    /// Shell's native Claude Code view.
    case native
    /// Claude Code's own terminal UI.
    case terminal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ask: "Ask each time"
        case .native: "Shell's native view"
        case .terminal: "Claude Code's terminal UI"
        }
    }
}

enum TabBarStyle: String, Codable, CaseIterable, Identifiable {
    case horizontal, vertical
    var id: String { rawValue }
    var title: String { self == .horizontal ? "Horizontal (top)" : "Vertical (sidebar)" }
}

enum NewTabDirectory: String, Codable, CaseIterable, Identifiable {
    case inherit, home, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .inherit: "Same as current tab"
        case .home: "Home folder"
        case .custom: "Custom folder"
        }
    }
}

enum NewTabPlacement: String, Codable, CaseIterable, Identifiable {
    case end, afterCurrent
    var id: String { rawValue }
    var title: String { self == .end ? "At the end" : "After the current tab" }
}

/// Optional per-color overrides applied on top of the active theme.
struct ColorOverrides: Codable, Equatable {
    var background: String?
    var foreground: String?
    var cursor: String?
    var selectionBackground: String?
    var selectionForeground: String?
    var palette: [Int: String] = [:]

    var isEmpty: Bool {
        background == nil && foreground == nil && cursor == nil &&
            selectionBackground == nil && selectionForeground == nil && palette.isEmpty
    }
}

struct AppSettings: Codable, Equatable {
    // General
    var appearance: AppearanceMode = .system
    var restoreSession = true
    var confirmQuitWithRunningProcesses = true
    var newTabDirectory: NewTabDirectory = .inherit
    var customDirectory = "~"

    // Themes & colors (separate light/dark themes follow the system appearance)
    var lightTheme = "Shell Light"
    var darkTheme = "Shell Dark"
    var lightOverrides = ColorOverrides()
    var darkOverrides = ColorOverrides()
    var backgroundOpacity = 1.0
    var backgroundBlur = true
    var minimumContrast = 1.0

    // Text
    var fontFamily = ""
    var fontSize = 13.0
    var lineHeight = 1.0
    var letterSpacing = 1.0
    var ligatures = true
    var fontThicken = false

    // Cursor
    var cursorStyle: CursorStyle = .bar
    var cursorBlink = true

    // Terminal
    var scrollbackMB = 50
    var copyOnSelect = false
    var optionKey: OptionKeyMode = .left
    var naturalTextEditing = true
    var hideMouseWhileTyping = true
    var paddingX = 14
    var paddingY = 10
    var dimUnfocusedSplits = true
    var pasteProtection = true
    var highlightLinks = true
    var focusFollowsMouse = false
    var bellSound = false
    var bounceDockOnBell = true

    // Shell
    var shellPath = ""
    var shellIntegration = true
    var environment: [String: String] = [:]

    // Input editor (Warp-style)
    var inputEditor = true
    var inputPosition: InputPosition = .bottom
    var promptStyle: PromptStyle = .compact
    var showContextBar = true
    /// Status, failure tint and actions drawn over each command block.
    var showCommandBlocks = true
    var completions = true
    var completionsWhileTyping = true
    var historySuggestions = true
    var completionPreview = true
    var syntaxHighlighting = true
    var editorFontSize = 0.0 // 0 = same as terminal

    // Tabs & windows
    var tabBarStyle: TabBarStyle = .horizontal
    var sidebarWidth = 240.0
    var newTabPlacement: NewTabPlacement = .afterCurrent

    // Notifications
    var notifyCommandFinished = true
    var commandFinishedThreshold = 10.0
    var notifyOnlyWhenInactive = true
    var notificationSound = true
    var agentNotifications = true
    /// Deliver "needs your input" agent alerts as Time Sensitive, so they can
    /// break through Focus (the user still allows it per app in System Settings).
    var timeSensitiveAgentAlerts = false

    // Software update
    /// Check GitHub for a new release every six hours.
    var checkForUpdates = true
    /// Download new releases in the background and install them when Shell quits.
    var installUpdatesAutomatically = true

    // Sync
    /// Mirror portable settings through iCloud Drive (see SettingsSync). Never synced itself.
    var iCloudSync = false

    /// The agent the prompt's launch button starts (new tab, here or in a worktree).
    var defaultAgent: CodingAgent = .claude

    // Native Claude Code view
    var claudeLaunchMode: ClaudeLaunchMode = .ask
    var claudeToolCalls: ToolCallDisplay = .collapsePrevious
    var claudeDiffStyle: DiffStyle = .automatic

    // Chat text (native Claude view), like VS Code's chat font settings.
    /// Font family for replies and the composer; empty = the system font.
    var chatFontFamily = ""
    /// Points; 0 = one point larger than the terminal font.
    var chatFontSize = 0.0
    /// Line height as a multiple of the font size (VS Code's lineHeight < 8).
    var chatLineHeight = 1.6
    /// Extra space between letters, in points.
    var chatLetterSpacing = 0.0
    /// Space between paragraphs, as a multiple of the font size.
    var chatParagraphSpacing = 1.0
    /// Code blocks and `inline code`; empty = the terminal font.
    var chatCodeFontFamily = ""
    /// Points; 0 = 1.5 pt smaller than the chat text.
    var chatCodeFontSize = 0.0
    /// Reading width of the transcript text in points; 0 = the whole chat column.
    var chatMaxWidth = 700.0
    /// Width of the chat column the composer fills (and the transcript sits in).
    var chatComposerWidth: ChatComposerWidth = .centered
    /// Turn on Remote Control for every interactive Claude Code session, so it
    /// can be continued from the Claude app (phone, web).
    var claudeRemoteControl = true
    /// Defaults for new native sessions; empty = Claude Code's own default.
    var claudeModel = ""
    /// Permission mode for new sessions (a `ClaudePermissionMode` raw value);
    /// empty = Claude Code's own `permissions.defaultMode`. A `--permission-mode`
    /// on the command line wins.
    var claudePermissionMode = "auto"
    var claudeEffort = ""
    var claudeFileExplorer = true
    /// When to pin the Claude Sessions entry (the dashboard of every Claude
    /// session) to the top of the tabs.
    var claudeSessionsButton: ClaudeSessionsButton = .always
    /// Show past sessions in a drawer on the Claude Sessions page.
    var claudeSessionsHistory = true
    /// Treat a linked git worktree as trusted when its main checkout is trusted
    /// in Claude Code (and record it), so new worktrees don't ask again.
    var claudeTrustWorktrees = true
    var claudeExplorerWidth = 280.0
    var claudeExplorerChangedOnly = false
    /// Show the right sidebar (files, worktrees) in terminal panes inside a git repo.
    var terminalSidebar = false
    /// Right sidebar tab: "files", "worktrees" or "github".
    var sidebarTab: SidebarTab = .github
    /// Open the sidebar automatically in terminal panes inside a GitHub repository.
    var sidebarAutoShowGitHub = true
    /// GitHub tab section: "prs" or "actions".
    var githubSection: GitHubSection = .prs
    /// Actions list: "all" branches or the current "branch".
    var actionsScope = "all"

    // Worktrees
    /// A worktree with no uncommitted changes and no activity for this many days is stale.
    var worktreeStaleDays = 7
    var worktreeCleanupSchedule: AutoUpdateSchedule = .off
    /// Repositories (or folders of repositories) the scheduled cleanup covers.
    var worktreeCleanupPaths: [String] = []
    /// Also `git branch -d` the worktree's branch (only succeeds when merged).
    var worktreeCleanupDeleteMergedBranches = false
    /// Where Shell creates worktrees (e.g. for reviewing a PR); empty = $WORKTREES_HOME or ~/code/worktrees.
    var worktreeRoot = ""
    /// Pull Requests tab filter: all, review, mine.
    var pullRequestFilter = "all"
    /// GitHub tab board filter: forYou, mine or all.
    var githubBoardFilter = "forYou"
    /// When a check fails on a branch open in a Claude session, send the job
    /// log to that session and start a fix (opt-in).
    var sendCheckFailuresToClaude = false

    // Go
    /// Notify when Go's caches together pass `goCacheWarningGB`.
    var goCacheWarning = true
    var goCacheWarningGB = 50
    /// When over the limit, clear the build cache automatically instead of only warning.
    var goAutoCleanBuildCache = false

    // Claude & Codex storage
    /// Transcripts and sessions older than this are pruned (Claude Code's own default is 30).
    var agentHistoryDays = 30
    /// Scheduled cleanup also prunes old history (off = caches and logs only).
    var agentPruneHistory = false
    var agentStorageSchedule: AutoUpdateSchedule = .off

    /// Bundle ID of the editor last used from the file explorer.
    var claudePreferredEditor = ""

    // Homebrew maintenance: brew update && brew upgrade && brew doctor
    var brewAutoUpdate: AutoUpdateSchedule = .off

    // Node.js toolchain
    var nodeManager: NodeManagerKind = .n
    var nodeTrack = "lts"
    var nodeAutoUpdate: AutoUpdateSchedule = .off
    var nodePruneOldVersions = false
    var nodePackageManagers: [String] = ["npm", "pnpm", "yarn", "bun"]

    // Quick terminal (hotkey window)
    var hotkeyWindow = false
    var hotkey: KeyShortcut? = KeyShortcut(key: "`", modifiers: [.option])

    // Keyboard shortcut overrides (action id -> shortcut or nil to unbind)
    var shortcuts: [String: KeyShortcut?] = [:]

    // Apple Intelligence (on-device model). Every feature is off
    // until the user turns it on; none of these sync, since availability is per Mac.
    /// Suggest branch names from a description in "Start in Worktree…".
    var intelligenceBranchNames = false
    /// Match plain-English palette queries to a command.
    var intelligencePaletteIntents = false
    /// Offer a corrected command as ghost text after a command fails.
    var intelligenceCommandFixes = false
    /// A one-line status for each session on the Claude dashboard.
    var intelligenceSessionSummaries = false
    /// Suggest names when renaming a tab or creating a tab group.
    var intelligenceTabNames = false
    /// Draft a commit message from the staged diff in Review Changes.
    var intelligenceCommitMessages = false
    /// The one-time "Apple Intelligence features are available" banner was shown.
    var intelligenceAnnouncementShown = false

    // Advanced: raw Ghostty config appended to the generated file
    var extraGhosttyConfig = ""
}

/// Facts about how the app was launched.
enum AppEnvironment {
    /// True when the app is hosting XCTest (TEST_HOST): launch does the
    /// minimum and nothing is read from or written to the user's real files.
    static let isRunningTests: Bool =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
}

/// Loads, stores and publishes the user's settings. Persisted as JSON so it
/// can be edited by hand and synced with dotfiles.
@MainActor
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            scheduleSave()
            for observer in observers.values { observer(oldValue, settings) }
        }
    }

    @ObservationIgnored private var observers: [UUID: (AppSettings, AppSettings) -> Void] = [:]
    @ObservationIgnored private var saveWork: DispatchWorkItem?

    /// ~/Library/Application Support/Shell: settings, the generated Ghostty
    /// config, history, session restore, themes and maintenance state. Unit
    /// tests get a throwaway folder so they never touch the real one.
    /// Debug builds honor `SHELL_APP_SUPPORT_DIR`, so a dev build can run
    /// beside the installed app without sharing its settings or session restore.
    static let supportDirectory: URL = {
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["SHELL_APP_SUPPORT_DIR"], !dir.isEmpty, !AppEnvironment.isRunningTests {
            let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        #endif
        let url = AppEnvironment.isRunningTests
            ? FileManager.default.temporaryDirectory.appendingPathComponent("ShellTests-\(getpid())", isDirectory: true)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Shell", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var fileURL: URL { supportDirectory.appendingPathComponent("settings.json") }

    private init() {
        settings = Self.load() ?? AppSettings()
    }

    /// Registers a change observer. Returns a token for removal.
    @discardableResult
    func observe(_ body: @escaping (AppSettings, AppSettings) -> Void) -> UUID {
        let id = UUID()
        observers[id] = body
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }

    /// Decodes settings by layering the file over the defaults, so settings
    /// files from older versions (missing keys) still load.
    static func load(from url: URL = fileURL) -> AppSettings? {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaultsData = try? JSONEncoder().encode(AppSettings()),
              var merged = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any]
        else { return nil }
        for (k, v) in stored { merged[k] = v }
        migrate(stored: stored, into: &merged)
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: mergedData)
        } catch {
            log.error("settings decode failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Carries older settings forward. Before `chatComposerWidth`, turning off
    /// the reading width (`chatMaxWidth` 0) made the whole chat fill the pane;
    /// keep that as Full width. Turning off the old Claude dashboard toggle
    /// becomes Never.
    nonisolated static func migrate(stored: [String: Any], into merged: inout [String: Any]) {
        if stored["chatComposerWidth"] == nil, let width = stored["chatMaxWidth"] as? Double, width <= 0 {
            merged["chatComposerWidth"] = ChatComposerWidth.full.rawValue
        }
        // `claudeDashboard: false` (before `claudeSessionsButton`) hid the entry.
        if stored["claudeSessionsButton"] == nil, stored["claudeDashboard"] as? Bool == false {
            merged["claudeSessionsButton"] = ClaudeSessionsButton.never.rawValue
        }
        merged["claudeDashboard"] = nil
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func saveNow() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(settings).write(to: Self.fileURL, options: .atomic)
        } catch {
            // A failed save would otherwise lose the change silently at the next launch.
            Log.settings.error("couldn't save \(Self.fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func reset() { settings = AppSettings() }
}

extension AppSettings {
    /// True when the two differ only in fields that don't change how terminal
    /// panes, editors or window chrome look (sidebar state, schedules,
    /// maintenance, notification and Claude defaults). Lets windows skip
    /// re-theming every pane for those. Anything not listed here, including
    /// fields added later, counts as visual.
    func differsOnlyInNonVisualState(from other: AppSettings) -> Bool {
        self.withoutNonVisualState == other.withoutNonVisualState
    }

    private var withoutNonVisualState: AppSettings {
        var s = self
        let d = AppSettings()
        s.restoreSession = d.restoreSession
        s.confirmQuitWithRunningProcesses = d.confirmQuitWithRunningProcesses
        s.newTabDirectory = d.newTabDirectory
        s.customDirectory = d.customDirectory
        s.sidebarWidth = d.sidebarWidth
        s.newTabPlacement = d.newTabPlacement
        s.notifyCommandFinished = d.notifyCommandFinished
        s.commandFinishedThreshold = d.commandFinishedThreshold
        s.notifyOnlyWhenInactive = d.notifyOnlyWhenInactive
        s.notificationSound = d.notificationSound
        s.agentNotifications = d.agentNotifications
        s.timeSensitiveAgentAlerts = d.timeSensitiveAgentAlerts
        s.iCloudSync = d.iCloudSync
        s.checkForUpdates = d.checkForUpdates
        s.installUpdatesAutomatically = d.installUpdatesAutomatically
        s.claudeModel = d.claudeModel
        s.claudePermissionMode = d.claudePermissionMode
        s.claudeEffort = d.claudeEffort
        s.claudeTrustWorktrees = d.claudeTrustWorktrees
        s.claudeExplorerWidth = d.claudeExplorerWidth
        s.claudeExplorerChangedOnly = d.claudeExplorerChangedOnly
        s.sidebarTab = d.sidebarTab
        s.githubSection = d.githubSection
        s.actionsScope = d.actionsScope
        s.worktreeStaleDays = d.worktreeStaleDays
        s.worktreeCleanupSchedule = d.worktreeCleanupSchedule
        s.worktreeCleanupPaths = d.worktreeCleanupPaths
        s.worktreeCleanupDeleteMergedBranches = d.worktreeCleanupDeleteMergedBranches
        s.worktreeRoot = d.worktreeRoot
        s.pullRequestFilter = d.pullRequestFilter
        s.githubBoardFilter = d.githubBoardFilter
        s.sendCheckFailuresToClaude = d.sendCheckFailuresToClaude
        s.goCacheWarning = d.goCacheWarning
        s.goCacheWarningGB = d.goCacheWarningGB
        s.goAutoCleanBuildCache = d.goAutoCleanBuildCache
        s.agentHistoryDays = d.agentHistoryDays
        s.agentPruneHistory = d.agentPruneHistory
        s.agentStorageSchedule = d.agentStorageSchedule
        s.claudePreferredEditor = d.claudePreferredEditor
        s.brewAutoUpdate = d.brewAutoUpdate
        s.nodeManager = d.nodeManager
        s.nodeTrack = d.nodeTrack
        s.nodeAutoUpdate = d.nodeAutoUpdate
        s.nodePruneOldVersions = d.nodePruneOldVersions
        s.nodePackageManagers = d.nodePackageManagers
        s.hotkeyWindow = d.hotkeyWindow
        s.hotkey = d.hotkey
        s.intelligenceAnnouncementShown = d.intelligenceAnnouncementShown
        return s
    }
}
