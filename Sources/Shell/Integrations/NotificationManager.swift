import AppKit
@preconcurrency import UserNotifications

/// Native notifications for long-running commands, OSC 9/777 desktop
/// notifications, and Claude/Codex agent events. Clicking one focuses the pane.
@MainActor
final class NotificationManager: NSObject {
    static let shared = NotificationManager()

    /// Update notifications carry a Restart Now button.
    static let updateCategory = "update"
    private nonisolated static let restartAction = "restart-to-update"

    private var authorized: Bool?
    private var delivered: [UUID: [String]] = [:]

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let restart = UNNotificationAction(identifier: Self.restartAction, title: "Restart Now", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.updateCategory, actions: [restart], intentIdentifiers: []),
        ])
    }

    /// `timeSensitive` lets the alert break through Focus. It only takes effect
    /// when the app is signed with the time-sensitive entitlement and the user
    /// allows it; otherwise macOS delivers it as a normal notification.
    func post(title: String, body: String, session: TerminalSession?, force: Bool, timeSensitive: Bool = false) {
        let settings = SettingsStore.shared.settings
        if !force, let session, settings.notifyOnlyWhenInactive,
           NSApp.isActive, session.isFocused, session.surfaceView.window?.isKeyWindow == true {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if settings.notificationSound { content.sound = .default }
        if timeSensitive { content.interruptionLevel = .timeSensitive }
        if let session {
            content.userInfo = ["session": session.id.uuidString]
            content.threadIdentifier = session.id.uuidString
            content.subtitle = session.abbreviatedDirectory
        }
        let id = UUID().uuidString
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        if let session { delivered[session.id, default: []].append(id) }

        Task {
            let center = UNUserNotificationCenter.current()
            if authorized != true {
                authorized = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            }
            guard authorized == true else { return }
            try? await center.add(request)
        }
        updateDockBadge()
    }

    /// A notification not tied to a pane; clicking it opens a Settings pane.
    func postAppNotification(title: String, body: String, pane: SettingsPane?, category: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let category { content.categoryIdentifier = category }
        if SettingsStore.shared.settings.notificationSound { content.sound = .default }
        if let pane { content.userInfo = ["pane": pane.rawValue] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { center.add(request) }
        }
    }

    func clearNotifications(for sessionID: UUID) {
        guard let ids = delivered.removeValue(forKey: sessionID) else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        updateDockBadge()
    }

    /// Dock badge = panes where an agent is waiting on you or has finished.
    func updateDockBadge() {
        let count = SessionRegistry.shared.all.filter {
            switch $0.agent {
            case .needsInput, .finished: true
            default: false
            }
        }.count
        let label = count > 0 ? "\(count)" : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let sid = response.notification.request.content.userInfo["session"] as? String
        let pane = response.notification.request.content.userInfo["pane"] as? String
        let restart = response.actionIdentifier == Self.restartAction
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                NSApp.activate()
                if restart {
                    SoftwareUpdater.shared.installAndRelaunch()
                } else if let sid, let uuid = UUID(uuidString: sid), let session = SessionRegistry.shared.session(uuid) {
                    session.onRequestFocus?()
                } else if let pane, let p = SettingsPane(rawValue: pane) {
                    SettingsWindowController.shared.show(pane: p)
                }
            }
        }
        completionHandler()
    }
}
