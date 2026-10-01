import AppKit
import Observation

/// Keeps Shell up to date from its GitHub releases. Every six hours (and after
/// wake) it asks GitHub for the latest release; when it's newer, it downloads
/// the DMG in the background, verifies it (checksum, Developer ID team,
/// Gatekeeper) and stages the app. The staged app replaces this one when Shell
/// quits, or right away with Restart to Update.
@MainActor
@Observable
final class SoftwareUpdater {
    static let shared = SoftwareUpdater()
    static let checkInterval: TimeInterval = 6 * 3600

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        /// Newer, not downloaded: automatic install is off, this copy can't
        /// replace itself, or the last download failed (`downloadError`).
        case available(UpdateRelease)
        case downloading(UpdateRelease)
        /// Downloaded, verified and staged; installs at quit.
        case ready(UpdateRelease)
        case failed(String)
    }

    private struct State: Codable {
        var lastCheck: Date?
        var etag: String?
        /// The release behind `etag`, for when GitHub answers 304 Not Modified.
        var release: UpdateRelease?
        /// The last version we notified about, so each is announced once.
        var notifiedVersion: String?
    }

    private(set) var phase: Phase = .idle
    private(set) var lastCheck: Date?
    /// How much of the DMG has arrived while `.downloading`, 0...1. At 1 the
    /// download is done and the app is being verified.
    private(set) var downloadFraction: Double?
    /// Why the last download of an `.available` release failed.
    private(set) var downloadError: String?

    @ObservationIgnored private var state = State()
    @ObservationIgnored private var stagedApp: URL?
    @ObservationIgnored private var relaunchAfterQuit = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    var currentVersion: String { UpdateInstaller.currentVersion }
    var releasesURL: URL { URL(string: "https://github.com/\(UpdateInstaller.repository)/releases")! }

    private var stateURL: URL { SettingsStore.supportDirectory.appendingPathComponent("updates.json") }
    private var settings: AppSettings { SettingsStore.shared.settings }

    private init() {
        if let data = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(State.self, from: data) {
            state = s
            lastCheck = s.lastCheck
        }
    }

    /// Why this copy can't replace itself (so updates are only announced), or nil.
    var installBlocker: String? {
        guard UpdateInstaller.teamID != nil else {
            return "This is a development build, so it doesn't update itself."
        }
        let path = Bundle.main.bundlePath
        if path.contains("/AppTranslocation/") {
            return "Move Shell to your Applications folder to install updates."
        }
        let dir = (path as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: dir), FileManager.default.isWritableFile(atPath: path) else {
            return "Shell can't replace itself in \(dir). Download new versions from GitHub."
        }
        return nil
    }

    private var isBusy: Bool {
        switch phase {
        case .checking, .downloading: true
        default: false
        }
    }

    // MARK: Scheduling

    func start() {
        // Staged downloads are for the session that made them.
        let staging = UpdateInstaller.stagingRoot
        Task.detached(priority: .background) { try? FileManager.default.removeItem(at: staging) }
        configure()
    }

    /// Automatic checks run only in Developer ID builds (not while developing
    /// Shell itself) and only when the setting is on.
    func configure() {
        timer?.invalidate()
        timer = nil
        guard settings.checkForUpdates, UpdateInstaller.teamID != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        timer?.tolerance = 5 * 60
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                    MainActor.assumeIsolated { self?.checkIfDue() }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard settings.checkForUpdates, !isBusy else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.checkInterval { return }
        Task { await check(userInitiated: false) }
    }

    // MARK: Checking

    func check(userInitiated: Bool) async {
        guard !isBusy else { return }
        let previous = phase
        phase = .checking
        let release: UpdateRelease?
        do {
            switch try await UpdateInstaller.fetchLatest(etag: state.etag) {
            case .notModified:
                release = state.release
            case .release(let r, let etag):
                release = r
                state.release = r
                state.etag = r == nil ? nil : etag
            }
        } catch {
            Log.update.error("update check failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
            return
        }
        lastCheck = Date()
        state.lastCheck = lastCheck
        persist()

        guard let release, AppVersion.isNewer(release.version, than: currentVersion) else {
            phase = .upToDate
            return
        }
        if case .ready(let staged) = previous, staged.version == release.version {
            phase = previous
            return
        }
        Log.update.info("Shell \(release.version, privacy: .public) is available")
        if !userInitiated, settings.installUpdatesAutomatically, installBlocker == nil {
            announce(release, ready: await download(release))
        } else {
            phase = .available(release)
            if !userInitiated { announce(release, ready: false) }
        }
    }

    /// Downloads, verifies and stages `release`. On failure the release stays
    /// `.available` with `downloadError` set, so it can be retried.
    @discardableResult
    private func download(_ release: UpdateRelease) async -> Bool {
        guard let teamID = UpdateInstaller.teamID, let bundleID = Bundle.main.bundleIdentifier else { return false }
        phase = .downloading(release)
        downloadError = nil
        downloadFraction = 0
        let monitor = UpdateInstaller.DownloadMonitor()
        let total = Double(max(release.dmgSize, 1))
        let progress = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, case .downloading = self.phase else { return }
                self.downloadFraction = min(1, Double(monitor.bytesReceived) / total)
            }
        }
        defer {
            progress.cancel()
            downloadFraction = nil
        }
        do {
            stagedApp = try await UpdateInstaller.stage(release, teamID: teamID, bundleID: bundleID, monitor: monitor)
            phase = .ready(release)
            Log.update.info("Shell \(release.version, privacy: .public) is staged")
            return true
        } catch {
            Log.update.error("update \(release.version, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            stagedApp = nil
            downloadError = error.localizedDescription
            phase = .available(release)
            return false
        }
    }

    private func announce(_ release: UpdateRelease, ready: Bool) {
        guard state.notifiedVersion != release.version else { return }
        state.notifiedVersion = release.version
        persist()
        let body = if ready {
            "Restart Shell to install it, or it installs the next time you quit."
        } else if installBlocker == nil {
            "You have \(currentVersion). Choose Help › Install Shell \(release.version) and Restart."
        } else {
            "You have \(currentVersion). Click to download it."
        }
        let category = installBlocker == nil ? NotificationManager.updateCategory : nil
        NotificationManager.shared.postAppNotification(title: "Shell \(release.version) is available", body: body,
                                                       pane: .general, category: category)
    }

    private func persist() {
        do {
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        } catch {
            Log.update.error("couldn't save \(self.stateURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Installing

    /// Downloads the update if needed, then quits, installs and relaunches.
    /// Tabs come back through session restore. A failed download is reported
    /// in an alert with the option to try again.
    func installAndRelaunch() {
        guard installBlocker == nil else { return }
        Task {
            switch phase {
            case .ready: break
            case .available(let release):
                guard await download(release) else {
                    presentDownloadFailure(release)
                    return
                }
            default: return
            }
            relaunchAfterQuit = true
            NSApp.terminate(nil)
            relaunchAfterQuit = false // only reached when the quit was cancelled
        }
    }

    /// Called last while quitting (after child processes are stopped): hands a
    /// staged update to the install helper when the user asked to restart or
    /// automatic installs are on.
    func installOnQuit() {
        guard case .ready = phase, let stagedApp, installBlocker == nil,
              relaunchAfterQuit || settings.installUpdatesAutomatically else { return }
        UpdateInstaller.spawnInstaller(staged: stagedApp, target: Bundle.main.bundleURL, relaunch: relaunchAfterQuit,
                                       log: ScheduledMaintenance.logDirectory.appendingPathComponent("update.log"))
    }

    private func presentDownloadFailure(_ release: UpdateRelease) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't download Shell \(release.version)"
        alert.informativeText = downloadError ?? "The download failed."
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Open Download Page")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: installAndRelaunch()
        case .alertSecondButtonReturn: NSWorkspace.shared.open(release.notesURL)
        default: break
        }
    }

    // MARK: Check for Updates…

    func checkInteractively() {
        Task {
            await check(userInitiated: true)
            presentResult()
        }
    }

    private func presentResult() {
        let alert = NSAlert()
        switch phase {
        case .upToDate:
            alert.messageText = "You're up to date"
            alert.informativeText = "Shell \(currentVersion) is the latest version."
            alert.runModal()
        case .failed(let message):
            alert.alertStyle = .warning
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = message
            alert.runModal()
        case .available(let release), .ready(let release):
            let ready = if case .ready = phase { true } else { false }
            alert.messageText = ready ? "Shell \(release.version) is ready to install" : "Shell \(release.version) is available"
            let blocker = installBlocker
            let note = blocker ?? downloadError.map { "The last download failed: \($0)" }
            alert.informativeText = "You have \(currentVersion)." + (note.map { "\n\n\($0)" } ?? "")
            if blocker == nil {
                alert.addButton(withTitle: ready ? "Restart Now" : "Install and Restart")
                alert.addButton(withTitle: "Release Notes")
                alert.addButton(withTitle: "Later")
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    if !ready { SettingsWindowController.shared.show(pane: .general) } // shows download progress
                    installAndRelaunch()
                case .alertSecondButtonReturn: NSWorkspace.shared.open(release.notesURL)
                default: break
                }
            } else {
                alert.addButton(withTitle: "Open Download Page")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.notesURL) }
            }
        case .downloading:
            SettingsWindowController.shared.show(pane: .general)
        case .idle, .checking:
            break
        }
    }
}
