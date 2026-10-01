import AppKit
import SwiftUI
import XCTest
@testable import Shell

/// Hosts a SwiftUI view in an offscreen window (never ordered front) so
/// grouped forms realize their AppKit-backed controls (switches, sliders,
/// color wells, borderless buttons), which tests can then drive.
@MainActor
private final class HostedPane<V: View> {
    let window: NSWindow
    let host: NSHostingView<V>

    init(_ view: V, size: CGSize = CGSize(width: 900, height: 5000)) {
        host = NSHostingView(rootView: view)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        pump()
    }

    func pump(_ seconds: TimeInterval = 0.05) {
        host.layoutSubtreeIfNeeded()
        host.display()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        host.layoutSubtreeIfNeeded()
        host.display()
    }

    func views<T: NSView>(_ type: T.Type) -> [T] {
        var out: [T] = []
        func walk(_ v: NSView) {
            if let t = v as? T { out.append(t) }
            v.subviews.forEach(walk)
        }
        walk(host)
        return out
    }

    /// AppKit controls whose class name contains `fragment` (SwiftUI's private control classes).
    func controls(_ fragment: String) -> [NSControl] {
        views(NSControl.self).filter { String(describing: type(of: $0)).contains(fragment) }
    }

    var switches: [NSControl] { controls("Switch") }
    var sliders: [NSSlider] { views(NSSlider.self) }
    var borderlessButtons: [NSButton] { views(NSButton.self).filter { String(describing: type(of: $0)).contains("SwiftUIAppKitButton") } }
    var colorWells: [NSColorWell] { views(NSColorWell.self) }
    var textFieldStrings: [String] { views(NSTextField.self).map(\.stringValue) }

    func close() {
        window.contentView = nil
        window.close()
    }
}

/// Settings panes rendered under different settings, with their controls driven
/// to check they write to the settings store.
@MainActor
final class SettingsPanesTests: XCTestCase {
    private func host<V: View>(_ view: V, size: CGSize = CGSize(width: 900, height: 5000)) -> HostedPane<V> {
        let hosted = HostedPane(view, size: size)
        addTeardownBlock { @MainActor in hosted.close() }
        return hosted
    }

    /// Clicks each switch in turn (re-finding them after every re-render) and
    /// returns how many changed the settings.
    @discardableResult
    private func toggleEverySwitch<V: View>(in pane: HostedPane<V>, skip: Set<Int> = []) -> Int {
        var changed = 0
        let count = pane.switches.count
        for i in 0..<count where !skip.contains(i) {
            let list = pane.switches
            guard i < list.count, list[i].isEnabled else { continue }
            let before = SettingsStore.shared.settings
            list[i].performClick(nil)
            pane.pump(0.02)
            if SettingsStore.shared.settings != before { changed += 1 }
        }
        return changed
    }

    /// Moves every slider to its maximum; returns how many changed the settings.
    @discardableResult
    private func maxEverySlider<V: View>(in pane: HostedPane<V>) -> Int {
        var changed = 0
        for slider in pane.sliders where slider.isEnabled {
            let before = SettingsStore.shared.settings
            slider.doubleValue = slider.maxValue
            slider.sendAction(slider.action, to: slider.target)
            pane.pump(0.02)
            if SettingsStore.shared.settings != before { changed += 1 }
        }
        return changed
    }

    // MARK: setting(_:) binding

    func testSettingBindingReadsAndWritesTheStore() {
        withSettings({ $0.fontSize = 13 }) {
            let binding = setting(\.fontSize)
            XCTAssertEqual(binding.wrappedValue, 13)
            binding.wrappedValue = 16
            XCTAssertEqual(SettingsStore.shared.settings.fontSize, 16)
            SettingsStore.shared.settings.fontSize = 11
            XCTAssertEqual(binding.wrappedValue, 11)
        }
    }

    // MARK: General

    func testGeneralPaneDefaults() {
        withSettings({ $0 = AppSettings() }) {
            let pane = host(GeneralSettingsPane())
            XCTAssertFalse(pane.switches.isEmpty)
            XCTAssertGreaterThan(toggleEverySwitch(in: pane), 4, "switches write to the settings")
        }
    }

    func testGeneralPaneWithEveryOptionalSection() throws {
        try FileManager.default.createDirectory(at: SettingsSync.cloudDocuments, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: SettingsSync.cloudDocuments) }
        SettingsSync.defaults.set(Date().addingTimeInterval(-120), forKey: SettingsSync.lastSyncedKey)
        addTeardownBlock { SettingsSync.defaults.removeObject(forKey: SettingsSync.lastSyncedKey) }
        withSettings({
            $0.newTabDirectory = .custom
            $0.customDirectory = "~/Projects"
            $0.notifyCommandFinished = true
            $0.commandFinishedThreshold = 30
            $0.hotkeyWindow = true
            $0.hotkey = .cmdShift("space")
            $0.iCloudSync = true
            $0.checkForUpdates = false
        }) {
            let pane = host(GeneralSettingsPane())
            XCTAssertTrue(pane.textFieldStrings.contains("~/Projects"))
            // Turning sync off from the toggle.
            toggleEverySwitch(in: pane)
            XCTAssertFalse(SettingsStore.shared.settings.iCloudSync)
        }
    }

    func testGeneralPaneTurnsSyncOnWhenICloudIsEmpty() throws {
        try FileManager.default.createDirectory(at: SettingsSync.cloudDocuments, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: SettingsSync.cloudDocuments)
            SettingsSync.defaults.removeObject(forKey: SettingsSync.lastSeenKey)
            SettingsSync.defaults.removeObject(forKey: SettingsSync.lastSyncedKey)
        }
        withSettings({ $0 = AppSettings() }) {
            let pane = host(GeneralSettingsPane())
            toggleEverySwitch(in: pane)
            XCTAssertTrue(SettingsStore.shared.settings.iCloudSync, "with nothing in iCloud Drive, sync turns on with this Mac's settings")
        }
    }

    // MARK: Text, terminal, input, tabs, advanced

    func testTextPane() {
        withSettings({ $0.fontFamily = "Menlo"; $0.cursorStyle = .hollow }) {
            let pane = host(TextSettingsPane())
            XCTAssertGreaterThan(toggleEverySwitch(in: pane), 0)
            XCTAssertGreaterThan(maxEverySlider(in: pane), 0)
            XCTAssertEqual(SettingsStore.shared.settings.lineHeight, 1.8, accuracy: 0.001)
            XCTAssertEqual(SettingsStore.shared.settings.letterSpacing, 1.4, accuracy: 0.001)
        }
    }

    func testFontPreviewRendersForEveryTheme() {
        withSettings({ $0.lineHeight = 1.5; $0.fontSize = 18 }) {
            let host = render(FontPreview())
            XCTAssertGreaterThan(host.fittingSize.height, 0)
        }
    }

    func testTerminalPane() {
        withSettings({ $0 = AppSettings() }) {
            let pane = host(TerminalSettingsPane())
            XCTAssertGreaterThanOrEqual(toggleEverySwitch(in: pane), 8)
            XCTAssertNotEqual(SettingsStore.shared.settings.copyOnSelect, AppSettings().copyOnSelect)
        }
    }

    func testInputPaneWithTheEditorOn() {
        withSettings({ $0.inputEditor = true; $0.completions = true; $0.editorFontSize = 15 }) {
            let pane = host(InputSettingsPane())
            // Skip the first switch: turning the editor off hides the rest.
            XCTAssertGreaterThan(toggleEverySwitch(in: pane, skip: [0]), 3)
        }
    }

    func testInputPaneWithTheEditorOffOrCompletionsOff() {
        withSettings({ $0.inputEditor = false }) {
            let pane = host(InputSettingsPane())
            XCTAssertEqual(pane.switches.count, 1, "only the editor toggle shows")
            toggleEverySwitch(in: pane)
            XCTAssertTrue(SettingsStore.shared.settings.inputEditor)
        }
        withSettings({ $0.inputEditor = true; $0.completions = false; $0.editorFontSize = 0 }) {
            render(InputSettingsPane())
        }
    }

    func testTabsPane() {
        withSettings({ $0.tabBarStyle = .vertical; $0.sidebarWidth = 300 }) {
            let pane = host(TabsSettingsPane())
            XCTAssertGreaterThan(maxEverySlider(in: pane), 0)
            XCTAssertEqual(SettingsStore.shared.settings.sidebarWidth, 420)
        }
        withSettings({ $0.tabBarStyle = .horizontal }) {
            let pane = host(TabsSettingsPane())
            XCTAssertTrue(pane.sliders.isEmpty, "the sidebar width only shows for vertical tabs")
        }
    }

    func testAdvancedPane() {
        withSettings({ $0.extraGhosttyConfig = "font-feature = +ss01"; $0.shellIntegration = true }) {
            let pane = host(AdvancedSettingsPane())
            toggleEverySwitch(in: pane)
            XCTAssertFalse(SettingsStore.shared.settings.shellIntegration)
        }
    }

    // MARK: Chat text

    func testChatTextPaneWithAutomaticSizes() {
        withSettings({ $0.chatFontSize = 0; $0.chatCodeFontSize = 0; $0.chatMaxWidth = 700 }) {
            let pane = host(ChatTextSettingsPane())
            XCTAssertTrue(pane.textFieldStrings.contains { $0.hasPrefix("Automatic (") })
            XCTAssertGreaterThan(maxEverySlider(in: pane), 2)
            XCTAssertEqual(SettingsStore.shared.settings.chatLineHeight, 2.4, accuracy: 0.001)
            // Each slider's reset button restores its default.
            for button in pane.borderlessButtons where button.isEnabled {
                button.performClick(nil)
                pane.pump(0.02)
            }
            XCTAssertEqual(SettingsStore.shared.settings.chatLineHeight, 1.6, accuracy: 0.001)
            // "Limit the reading width" off sets the width to 0.
            toggleEverySwitch(in: pane)
            XCTAssertEqual(SettingsStore.shared.settings.chatMaxWidth, 0)
            toggleEverySwitch(in: pane)
            XCTAssertEqual(SettingsStore.shared.settings.chatMaxWidth, AppSettings().chatMaxWidth)
        }
    }

    func testChatTextPaneWithExplicitSizes() {
        withSettings({ $0.chatFontSize = 16; $0.chatCodeFontSize = 13; $0.chatMaxWidth = 0; $0.fontFamily = "Menlo"; $0.chatComposerWidth = .full }) {
            let pane = host(ChatTextSettingsPane())
            XCTAssertFalse(pane.textFieldStrings.contains { $0.hasPrefix("Automatic (") })
        }
    }

    func testChatTextRestoreDefaults() {
        withSettings({
            $0.chatFontFamily = "Avenir"; $0.chatFontSize = 20; $0.chatLineHeight = 2; $0.chatLetterSpacing = 1
            $0.chatParagraphSpacing = 2; $0.chatCodeFontFamily = "Menlo"; $0.chatCodeFontSize = 15; $0.chatMaxWidth = 0
            $0.chatComposerWidth = .full; $0.fontSize = 17
        }) {
            ChatTextSettingsPane.restoreDefaults()
            let s = SettingsStore.shared.settings, d = AppSettings()
            XCTAssertEqual(s.chatFontFamily, d.chatFontFamily)
            XCTAssertEqual(s.chatFontSize, d.chatFontSize)
            XCTAssertEqual(s.chatLineHeight, d.chatLineHeight)
            XCTAssertEqual(s.chatLetterSpacing, d.chatLetterSpacing)
            XCTAssertEqual(s.chatParagraphSpacing, d.chatParagraphSpacing)
            XCTAssertEqual(s.chatCodeFontFamily, d.chatCodeFontFamily)
            XCTAssertEqual(s.chatCodeFontSize, d.chatCodeFontSize)
            XCTAssertEqual(s.chatMaxWidth, d.chatMaxWidth)
            XCTAssertEqual(s.chatComposerWidth, d.chatComposerWidth)
            XCTAssertEqual(s.fontSize, 17, "only chat settings are reset")
        }
        XCTAssertTrue(ChatTextSettingsPane.sample.contains("```go"))
    }

    // MARK: Appearance

    func testAppearancePaneInBothModes() {
        withSettings({ $0.backgroundOpacity = 0.8; $0.darkOverrides.background = "#000000"; $0.lightOverrides.palette[1] = "#ff0000" }) {
            let pane = host(AppearanceSettingsPane())
            XCTAssertGreaterThan(maxEverySlider(in: pane), 0)
            XCTAssertEqual(SettingsStore.shared.settings.backgroundOpacity, 1)
            XCTAssertEqual(SettingsStore.shared.settings.minimumContrast, 7)
            toggleEverySwitch(in: pane)
            // Switch the light/dark segmented picker and render the other mode.
            for control in pane.views(NSSegmentedControl.self) where control.segmentCount == 2 {
                control.selectedSegment = control.selectedSegment == 0 ? 1 : 0
                control.sendAction(control.action, to: control.target)
                pane.pump()
            }
        }
    }

    func testColorOverridesWriteHexColors() {
        withSettings({ $0.darkOverrides = ColorOverrides(); $0.lightOverrides = ColorOverrides() }) {
            for dark in [true, false] {
                let pane = host(Form { ColorOverridesSection(dark: dark) }.formStyle(.grouped))
                let wells = pane.colorWells
                XCTAssertEqual(wells.count, 20, "background, foreground, cursor, selection and 16 ANSI colors")
                for well in wells {
                    well.color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
                    well.sendAction(well.action, to: well.target)
                }
                pane.pump()
                let o = dark ? SettingsStore.shared.settings.darkOverrides : SettingsStore.shared.settings.lightOverrides
                XCTAssertEqual(o.background, "#ff0000")
                XCTAssertEqual(o.foreground, "#ff0000")
                XCTAssertEqual(o.cursor, "#ff0000")
                XCTAssertEqual(o.selectionBackground, "#ff0000")
                XCTAssertEqual(o.palette.count, 16)
            }
            XCTAssertEqual(ColorOverridesSection.ansiNames.count, 16)
        }
    }

    func testThemeCardAndTile() {
        render(ThemeCard(theme: .shellDark, label: "Dark: Shell Dark", selected: true))
        render(ThemeCard(theme: .shellLight, label: "Light: Shell Light", selected: false))
        render(ThemeTile(theme: .shellDark, selected: true))
        render(ThemeTile(theme: .shellLight, selected: false))
    }

    // MARK: Shortcuts

    func testShortcutsPaneWithOverridesAndConflicts() {
        // ⌘T on Split Right conflicts with New Tab; Find is unbound.
        let overrides: [String: KeyShortcut?] = ["splitRight": .cmd("t"), "find": nil]
        withSettings({ $0.shortcuts = overrides }) {
            let pane = host(ShortcutsSettingsPane(), size: CGSize(width: 900, height: 9000))
            // Each overridden row has a "restore default" button.
            let restore = pane.borderlessButtons
            XCTAssertGreaterThanOrEqual(restore.count, 2)
            for button in restore {
                button.performClick(nil)
                pane.pump(0.02)
            }
            XCTAssertEqual(SettingsStore.shared.settings.shortcuts.count, 0)
        }
    }

    func testShortcutsPaneDefaults() {
        withSettings({ $0.shortcuts = [:] }) {
            let pane = host(ShortcutsSettingsPane(), size: CGSize(width: 900, height: 9000))
            XCTAssertTrue(pane.borderlessButtons.isEmpty)
        }
    }

    func testShortcutRecorderShowsTheShortcutOrNone() {
        var value: KeyShortcut? = .cmdShift("d")
        let binding = Binding(get: { value }, set: { value = $0 })
        render(ShortcutRecorder(shortcut: binding))
        value = nil
        render(ShortcutRecorder(shortcut: binding))
    }

    // MARK: Claude & Codex

    private func agentHome(claude: String? = nil, codex: String? = nil) throws -> URL {
        let home = try makeTemporaryDirectory()
        if let claude {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
            try claude.write(to: home.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        }
        if let codex {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
            try codex.write(to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)
        }
        return home
    }

    func testIntegrationsPaneNotInstalled() throws {
        let agents = AgentIntegrations(home: try agentHome())
        XCTAssertEqual(agents.claude, .notInstalled)
        withSettings({ $0.agentNotifications = true }) {
            let pane = host(IntegrationsSettingsPane(agents: agents))
            XCTAssertGreaterThan(toggleEverySwitch(in: pane), 3)
        }
    }

    func testIntegrationsPaneInstalled() throws {
        let agents = AgentIntegrations(home: try agentHome(
            claude: #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "$SHELL_APP_CTL claude-hook Stop"}]}]}}"#,
            codex: AgentIntegrations.codexNotifyLine + "\n"))
        XCTAssertEqual(agents.claude, .installed)
        XCTAssertEqual(agents.codex, .installed)
        withSettings({ $0.agentNotifications = false }) {
            host(IntegrationsSettingsPane(agents: agents))
        }
    }

    func testIntegrationsPaneCodexConflictAndError() throws {
        let agents = AgentIntegrations(home: try agentHome(claude: "{ not json", codex: "notify = [\"other\"]\n"))
        if case .conflict = agents.codex {} else { XCTFail("expected a conflict, got \(agents.codex)") }
        agents.installClaude() // fails on the broken JSON and records an error
        XCTAssertNotNil(agents.lastError)
        host(IntegrationsSettingsPane(agents: agents))
    }

    // MARK: Apple Intelligence

    func testIntelligencePaneInEveryState() {
        for status: Intelligence.Status in [.available, .notEnabled, .deviceNotEligible, .modelNotReady, .unavailable] {
            render(IntelligenceSettingsPane(status: status))
        }
    }

    func testIntelligenceTogglesWriteSettingsWhenAvailable() {
        guard Intelligence.status == .available else {
            // The pane re-reads the real status, so toggles are disabled on this Mac.
            render(IntelligenceSettingsPane(status: .available))
            return
        }
        withSettings({ _ in }) {
            let pane = host(IntelligenceSettingsPane(status: .available))
            XCTAssertEqual(toggleEverySwitch(in: pane), IntelligenceFeature.allCases.count)
        }
    }

    // MARK: Software update

    private let release = UpdateRelease(
        version: "9.9.9", notesURL: URL(string: "https://github.com/arhea/Shell/releases/tag/v9.9.9")!,
        dmgName: "Shell-9.9.9.dmg", dmgURL: URL(string: "https://example.invalid/Shell-9.9.9.dmg")!, dmgSize: 1,
        checksumURL: URL(string: "https://example.invalid/Shell-9.9.9.dmg.sha256")!)

    private func updateSection(_ status: SoftwareUpdateSection.Status) -> some View {
        Form { SoftwareUpdateSection(status: status) }.formStyle(.grouped)
    }

    func testSoftwareUpdateSectionInEveryPhase() {
        typealias S = SoftwareUpdateSection.Status
        let states: [S] = [
            S(phase: .idle, currentVersion: "1.0.0"),
            S(phase: .upToDate, currentVersion: "1.0.0", lastCheck: Date().addingTimeInterval(-300)),
            S(phase: .checking, currentVersion: "1.0.0"),
            S(phase: .downloading(release), currentVersion: "1.0.0", downloadFraction: 0.4),
            S(phase: .downloading(release), currentVersion: "1.0.0", downloadFraction: 1),
            S(phase: .available(release), currentVersion: "1.0.0"),
            S(phase: .available(release), currentVersion: "1.0.0", downloadError: "The network connection was lost."),
            S(phase: .available(release), currentVersion: "1.0.0", installBlocker: "This is a development build, so it doesn't update itself."),
            S(phase: .ready(release), currentVersion: "1.0.0"),
            S(phase: .failed("GitHub couldn't be reached."), currentVersion: "1.0.0"),
        ]
        for state in states { render(updateSection(state)) }
    }

    func testSoftwareUpdateSwitchesWriteSettings() {
        withSettings({ $0.checkForUpdates = true; $0.installUpdatesAutomatically = true }) {
            let pane = host(updateSection(.init(phase: .idle, currentVersion: "1.0.0")))
            // Turning checks off disables the second switch, so toggle it first.
            XCTAssertEqual(toggleEverySwitch(in: pane, skip: [0]), 1)
            XCTAssertFalse(SettingsStore.shared.settings.installUpdatesAutomatically)
            XCTAssertEqual(toggleEverySwitch(in: pane, skip: [1]), 1)
            XCTAssertFalse(SettingsStore.shared.settings.checkForUpdates)
        }
    }

    func testSoftwareUpdateSectionReadsTheLiveUpdater() {
        // The default reads SoftwareUpdater.shared, which never checks in tests.
        render(Form { SoftwareUpdateSection() }.formStyle(.grouped))
    }
}

// MARK: - Maintenance-backed panes

/// A maintenance job that never runs, for showing a pane in a given state.
@MainActor
private final class IdleJob: MaintenanceJob {
    let id: String
    let title = "Test job"
    let summary = "Does nothing"
    var isAvailable: Bool { true }
    var schedule: AutoUpdateSchedule
    init(id: String, schedule: AutoUpdateSchedule) {
        self.id = id
        self.schedule = schedule
    }
    func perform(_ run: MaintenanceRun) async -> MaintenanceOutcome { MaintenanceOutcome() }
    func notification(for record: MaintenanceRecord) -> (title: String, body: String)? { nil }
    func didFinish() async {}
}

/// Mirrors ScheduledMaintenance's persisted state.
private struct MaintenanceStateFile: Codable {
    var lastSuccess: Date?
    var lastAttempt: Date?
    var lastRun: MaintenanceRecord?
}

extension SettingsPanesTests {
    /// A ScheduledMaintenance whose saved state has `record` as its last run.
    private func maintenance(schedule: AutoUpdateSchedule, record: MaintenanceRecord?, lastSuccess: Date? = nil,
                             lastAttempt: Date? = nil) throws -> ScheduledMaintenance {
        let id = "settings-test-\(UUID().uuidString)"
        let url = SettingsStore.supportDirectory.appendingPathComponent("maintenance-\(id).json")
        try JSONEncoder().encode(MaintenanceStateFile(lastSuccess: lastSuccess, lastAttempt: lastAttempt, lastRun: record)).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let m = ScheduledMaintenance(job: IdleJob(id: id, schedule: schedule))
        XCTAssertEqual(m.lastRun, record)
        return m
    }

    private func record(_ outcome: MaintenanceRecord.Outcome, changes: [String] = [], warnings: [String] = [],
                        summary: String? = nil, logPath: String = "/nonexistent/log") -> MaintenanceRecord {
        MaintenanceRecord(startedAt: Date().addingTimeInterval(-3700), finishedAt: Date().addingTimeInterval(-3600), outcome: outcome,
                          failedStep: outcome == .failed ? "git worktree remove" : nil, changes: changes, warnings: warnings,
                          logPath: logPath, summary: summary)
    }

    private func logFile() throws -> String {
        let url = try makeTemporaryDirectory().appendingPathComponent("run.log")
        try Data("log".utf8).write(to: url)
        return url.path
    }

    // MARK: Worktrees

    /// A repository, a folder of two repositories and an empty folder, all temporary.
    private func repositories() throws -> (repo: String, folder: String, empty: String) {
        let root = try makeTemporaryDirectory()
        let fm = FileManager.default
        let repo = root.appendingPathComponent("single-repo")
        try fm.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let folder = root.appendingPathComponent("code")
        for name in ["one", "two"] {
            try fm.createDirectory(at: folder.appendingPathComponent("\(name)/.git"), withIntermediateDirectories: true)
        }
        let empty = root.appendingPathComponent("empty")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        return (repo.path, folder.path, empty.path)
    }

    func testWorktreesPaneWithoutRepositories() throws {
        try withSettings({ $0.worktreeCleanupPaths = []; $0.worktreeStaleDays = 1; $0.worktreeRoot = "" }) {
            let pane = host(WorktreesSettingsPane(maintenance: try maintenance(schedule: .off, record: nil)))
            XCTAssertTrue(pane.borderlessButtons.isEmpty)
            toggleEverySwitch(in: pane)
            XCTAssertTrue(SettingsStore.shared.settings.worktreeCleanupDeleteMergedBranches)
        }
    }

    func testWorktreesPaneListsRepositoriesAndRemovesThem() throws {
        let paths = try repositories()
        try withSettings({ $0.worktreeCleanupPaths = [paths.repo, paths.folder, paths.empty]; $0.worktreeStaleDays = 14 }) {
            let m = try maintenance(schedule: .daily, record: record(.success, changes: ["one/feature"], warnings: ["two/locked"],
                                                                      summary: "freed 1 GB", logPath: try logFile()),
                                    lastSuccess: Date().addingTimeInterval(-3600))
            let pane = host(WorktreesSettingsPane(maintenance: m))
            // One "remove" button per listed path.
            let remove = pane.borderlessButtons
            XCTAssertEqual(remove.count, 3)
            remove.first?.performClick(nil)
            pane.pump()
            XCTAssertEqual(SettingsStore.shared.settings.worktreeCleanupPaths.count, 2)
        }
    }

    func testWorktreesPaneStatusLines() throws {
        let paths = try repositories()
        try withSettings({ $0.worktreeCleanupPaths = [paths.repo] }) {
            let states: [ScheduledMaintenance] = [
                // Never run, but scheduled.
                try maintenance(schedule: .weekly, record: nil),
                // Succeeded with nothing to do; next run overdue.
                try maintenance(schedule: .daily, record: record(.success), lastSuccess: Date().addingTimeInterval(-3 * 86400)),
                // Failed, retried later.
                try maintenance(schedule: .daily, record: record(.failed), lastSuccess: Date().addingTimeInterval(-86400 * 2),
                                lastAttempt: Date().addingTimeInterval(-60)),
                // Stopped, with no schedule.
                try maintenance(schedule: .off, record: record(.cancelled)),
            ]
            for m in states {
                render(WorktreesSettingsPane(maintenance: m))
            }
        }
    }

    func testWorktreesPanePreview() throws {
        let paths = try repositories()
        let stale = WorktreeInfo(path: paths.folder + "/one-feature", branch: "feature/old", lastActivity: Date().addingTimeInterval(-30 * 86400))
        let other = WorktreeInfo(path: paths.folder + "/two-fix", branch: nil)
        let candidates = [
            WorktreeCleanupJob.Candidate(repo: paths.folder + "/one", worktree: stale),
            WorktreeCleanupJob.Candidate(repo: paths.folder + "/two", worktree: other),
        ]
        try withSettings({ $0.worktreeCleanupPaths = [paths.folder] }) {
            let m = try maintenance(schedule: .off, record: nil)
            render(WorktreesSettingsPane(maintenance: m, preview: candidates, previewSizes: [stale.path: 2_000_000]))
            render(WorktreesSettingsPane(maintenance: m, preview: [candidates[0]]))
            render(WorktreesSettingsPane(maintenance: m, preview: []))
        }
    }

    // MARK: Agent storage

    /// Two categories in a temporary folder: a Claude cache and Codex history,
    /// each with an old and a fresh item.
    private func storageModel() throws -> AgentStorageModel {
        let root = try makeTemporaryDirectory()
        let fm = FileManager.default
        func category(_ id: String, _ agent: StorageCategory.Agent, _ kind: StorageCategory.Kind) throws -> StorageCategory {
            let dir = root.appendingPathComponent(id)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, age) in [("old", 400.0 * 86400), ("fresh", 60.0)] {
                let file = dir.appendingPathComponent(name)
                try Data(repeating: 1, count: 4096).write(to: file)
                try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: file.path)
            }
            return StorageCategory(id: id, agent: agent, kind: kind, title: "Test \(id)", detail: "Detail for \(id)", roots: [dir],
                                   requiresClosed: nil, items: { AgentStorage.children(dir) })
        }
        return AgentStorageModel(categories: [try category("cache", .claude, .cache), try category("history", .codex, .history)])
    }

    func testAgentStoragePaneMeasuresInjectedFolders() throws {
        let model = try storageModel()
        XCTAssertTrue(model.measured.isEmpty)
        let m = try maintenance(schedule: .off, record: nil)
        try withSettings({ $0.agentHistoryDays = 30; $0.agentPruneHistory = false }) {
            let pane = host(AgentStoragePane(model: model, maintenance: m))
            // Appearing starts a measurement of the injected (temporary) folders only.
            XCTAssertTrue(waitUntil(timeout: 5) { !model.isMeasuring && model.measured.count == model.categories.count })
            pane.pump()
            XCTAssertGreaterThan(model.total, 0)
            XCTAssertEqual(model.removable(try XCTUnwrap(model.categories.first)).count, 1, "only the old item is removable")
            toggleEverySwitch(in: pane)
            XCTAssertTrue(SettingsStore.shared.settings.agentPruneHistory)
        }
    }

    func testAgentStoragePaneAfterACleanupAndARun() async throws {
        let model = try storageModel()
        model.measure()
        let deadline = Date().addingTimeInterval(5)
        while model.measured.count < 2 || model.isMeasuring, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let cache = try XCTUnwrap(model.categories.first)
        let message = await model.clean(cache)
        XCTAssertTrue(message.contains("freed"))
        XCTAssertEqual(model.lastResult, message)
        let m = try maintenance(schedule: .weekly, record: record(.success, summary: "freed 4 KB", logPath: try logFile()))
        render(AgentStoragePane(model: model, maintenance: m))
        let failed = try maintenance(schedule: .off, record: record(.failed))
        render(AgentStoragePane(model: model, maintenance: failed))
    }

    // MARK: Settings window

    func testSettingsPaneTitlesAndSymbols() {
        XCTAssertEqual(Set(SettingsPane.allCases.map(\.title)).count, SettingsPane.allCases.count)
        XCTAssertEqual(Set(SettingsPane.allCases.map(\.symbol)).count, SettingsPane.allCases.count)
        XCTAssertTrue(SettingsPane.allCases.allSatisfy { $0.id == $0.rawValue })
        XCTAssertEqual(SettingsPane.integrations.title, "Claude & Codex")
        XCTAssertEqual(SettingsPane(rawValue: "worktrees"), .worktrees)
    }

    func testSettingsWindowSwitchesBetweenPanes() throws {
        let controller = SettingsWindowController()
        addTeardownBlock { @MainActor in controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window.isVisible, "the window is never shown in tests")
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertTrue(window.frameAutosaveName.isEmpty, "tests don't write the window frame to the real defaults")
        let content = try XCTUnwrap(window.contentView)
        // Panes that don't touch the user's real tools or folders.
        let panes: [SettingsPane] = [.general, .appearance, .text, .chatText, .terminal, .input, .tabs, .shortcuts,
                                     .worktrees, .intelligence, .advanced]
        for pane in panes {
            controller.navigation.pane = pane
            content.layoutSubtreeIfNeeded()
            content.display()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertEqual(controller.navigation.pane, pane)
        }
    }

    func testSettingsRootViewRendersEachPane() {
        let navigation = SettingsNavigation()
        XCTAssertEqual(navigation.pane, .general)
        for pane: SettingsPane in [.general, .text, .advanced] {
            navigation.pane = pane
            render(SettingsRootView(navigation: navigation), size: CGSize(width: 900, height: 640))
        }
    }
}
