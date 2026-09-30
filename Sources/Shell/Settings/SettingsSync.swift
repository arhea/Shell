import AppKit
import SystemConfiguration

/// Optional settings sync through iCloud Drive. Off by default.
///
/// When on, the portable subset of settings (look and feel, prompt, shortcuts,
/// notification and Claude preferences) is mirrored to
/// `iCloud Drive/Shell/settings.json`. Other Macs with sync on pick up changes
/// from that file. Machine-specific settings (shell path, environment,
/// worktree and maintenance settings, UI state) never leave this Mac.
///
/// It uses the iCloud Drive folder directly, so it needs no iCloud
/// entitlement and works in source builds.
@MainActor
final class SettingsSync {
    static let shared = SettingsSync()

    /// Keys of `AppSettings` that sync. An allowlist, so new settings stay
    /// local until they're deliberately added here.
    static let portableKeys: Set<String> = [
        // General
        "appearance", "restoreSession", "confirmQuitWithRunningProcesses", "newTabDirectory", "customDirectory",
        // Themes & colors
        "lightTheme", "darkTheme", "lightOverrides", "darkOverrides", "backgroundOpacity", "backgroundBlur", "minimumContrast",
        // Text & cursor
        "fontFamily", "fontSize", "lineHeight", "letterSpacing", "ligatures", "fontThicken", "cursorStyle", "cursorBlink",
        // Terminal
        "scrollbackMB", "copyOnSelect", "optionKey", "naturalTextEditing", "hideMouseWhileTyping", "paddingX", "paddingY",
        "dimUnfocusedSplits", "pasteProtection", "highlightLinks", "focusFollowsMouse", "bellSound", "bounceDockOnBell",
        // Prompt & completions
        "inputEditor", "inputPosition", "promptStyle", "showContextBar", "completions", "completionsWhileTyping",
        "historySuggestions", "completionPreview", "syntaxHighlighting", "editorFontSize",
        // Tabs & windows
        "tabBarStyle", "newTabPlacement", "sidebarAutoShowGitHub",
        // Notifications
        "notifyCommandFinished", "commandFinishedThreshold", "notifyOnlyWhenInactive", "notificationSound",
        "agentNotifications", "timeSensitiveAgentAlerts",
        // Claude
        "claudeLaunchMode", "claudeRemoteControl", "claudeModel", "claudeEffort",
        // Hotkey window & shortcuts
        "hotkeyWindow", "hotkey", "shortcuts",
        // Advanced
        "extraGhosttyConfig",
    ]

    static let cloudDocuments = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    static let folder = cloudDocuments.appendingPathComponent("Shell", isDirectory: true)
    static let fileURL = folder.appendingPathComponent("settings.json")

    /// iCloud Drive is turned on for this Mac.
    static var isAvailable: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: cloudDocuments.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Last sync, for display in Settings.
    private(set) var lastSynced: Date? {
        get { UserDefaults.standard.object(forKey: Self.lastSyncedKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastSyncedKey) }
    }

    /// `modified` stamp of the newest file this Mac wrote or applied, so it
    /// doesn't re-apply its own writes or older copies.
    private var lastSeenStamp: Date? {
        get { UserDefaults.standard.object(forKey: Self.lastSeenKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastSeenKey) }
    }

    private static let lastSyncedKey = "SettingsSync.lastSynced"
    private static let lastSeenKey = "SettingsSync.lastSeenStamp"

    private var watcher: DirectoryWatcher?
    private var pushWork: DispatchWorkItem?
    private var applyingRemote = false
    private var observer: UUID?

    private init() {}

    // MARK: Lifecycle

    func start() {
        observer = SettingsStore.shared.observe { old, new in
            MainActor.assumeIsolated { SettingsSync.shared.settingsChanged(old: old, new: new) }
        }
        if SettingsStore.shared.settings.iCloudSync { activate() }
    }

    private func settingsChanged(old: AppSettings, new: AppSettings) {
        if old.iCloudSync != new.iCloudSync {
            new.iCloudSync ? activate() : deactivate()
            return
        }
        guard new.iCloudSync, !applyingRemote, !Self.samePortable(old, new) else { return }
        schedulePush()
    }

    private func activate() {
        guard Self.isAvailable else { return }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        watcher?.stop()
        watcher = DirectoryWatcher(path: Self.folder.path, latency: 1) { paths in
            guard paths.contains(where: { $0.hasSuffix("/settings.json") || $0.hasSuffix(".settings.json.icloud") }) else { return }
            SettingsSync.shared.pullIfNewer()
        }
        // Newer copy from another Mac wins at launch; otherwise publish ours.
        if !pullIfNewer() { pushNow() }
    }

    private func deactivate() {
        watcher?.stop()
        watcher = nil
        pushWork?.cancel()
    }

    // MARK: Enabling

    enum Remote {
        case none
        case exists(device: String?, modified: Date?)
    }

    /// What's already in iCloud Drive, so Settings can ask before overwriting.
    func remoteState() -> Remote {
        guard let file = Self.readRemote() else { return .none }
        return .exists(device: file.device, modified: file.modified)
    }

    /// Turns sync on. `useRemote` applies the iCloud copy first; otherwise
    /// this Mac's settings replace it.
    func enable(useRemote: Bool) {
        if useRemote, let file = Self.readRemote() {
            apply(file)
        } else {
            // `activate` then treats the iCloud copy as old and writes ours over it.
            Self.markRemoteStale()
        }
        SettingsStore.shared.settings.iCloudSync = true
    }

    // MARK: Push / pull

    private func schedulePush() {
        pushWork?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { SettingsSync.shared.pushNow() } }
        pushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func pushNow() {
        guard SettingsStore.shared.settings.iCloudSync, Self.isAvailable,
              let portable = Self.portable(SettingsStore.shared.settings) else { return }
        // Nothing to publish if iCloud already has these settings.
        let current = SettingsStore.shared.settings
        if let remote = Self.readRemote(), Self.merge(remote: remote.settings, into: current) == current {
            lastSynced = Date()
            return
        }
        let stamp = Date()
        let file: [String: Any] = [
            "format": 1,
            "modified": Self.dateFormatter.string(from: stamp),
            "device": (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "",
            "settings": portable,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys]) else { return }
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try data.write(to: Self.fileURL, options: .atomic)
            lastSeenStamp = stamp
            lastSynced = stamp
        } catch {
            log.error("settings sync push failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Applies the iCloud copy when it's newer than anything this Mac has
    /// written or applied. Returns true when it applied something.
    @discardableResult
    func pullIfNewer() -> Bool {
        guard SettingsStore.shared.settings.iCloudSync, let file = Self.readRemote() else { return false }
        if let seen = lastSeenStamp, let modified = file.modified, modified <= seen { return false }
        apply(file)
        return true
    }

    private func apply(_ file: RemoteFile) {
        lastSeenStamp = file.modified ?? Date()
        lastSynced = Date()
        guard let merged = Self.merge(remote: file.settings, into: SettingsStore.shared.settings),
              merged != SettingsStore.shared.settings else { return }
        applyingRemote = true
        SettingsStore.shared.settings = merged
        applyingRemote = false
    }

    // MARK: File format

    struct RemoteFile {
        var modified: Date?
        var device: String?
        var settings: [String: Any]
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func readRemote() -> RemoteFile? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            // Not downloaded yet: iCloud keeps a ".settings.json.icloud" placeholder.
            let placeholder = folder.appendingPathComponent(".settings.json.icloud")
            if fm.fileExists(atPath: placeholder.path) { try? fm.startDownloadingUbiquitousItem(at: fileURL) }
            return nil
        }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> RemoteFile? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = obj["settings"] as? [String: Any] else { return nil }
        let modified = (obj["modified"] as? String).flatMap { dateFormatter.date(from: $0) }
        return RemoteFile(modified: modified, device: obj["device"] as? String, settings: settings)
    }

    /// Makes the next `pullIfNewer` ignore the current iCloud copy.
    private static func markRemoteStale() {
        UserDefaults.standard.set(Date(), forKey: lastSeenKey)
    }

    // MARK: Merging (pure, tested)

    /// The portable subset of `settings` as a JSON object.
    static func portable(_ settings: AppSettings) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(settings),
              let all = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return all.filter { portableKeys.contains($0.key) }
    }

    /// Whether `a` and `b` agree on every portable setting. Compared after
    /// decoding, since JSON order isn't stable (sets encode as arrays).
    static func samePortable(_ a: AppSettings, _ b: AppSettings) -> Bool {
        guard let pa = portable(a) else { return false }
        return merge(remote: pa, into: b) == b
    }

    /// `local` with the portable keys from `remote` applied. Unknown and
    /// non-portable keys in `remote` are ignored; nil if the result doesn't decode.
    static func merge(remote: [String: Any], into local: AppSettings) -> AppSettings? {
        guard let data = try? JSONEncoder().encode(local),
              var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for (key, value) in remote where portableKeys.contains(key) { dict[key] = value }
        guard let merged = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: merged)
    }
}
