import AppKit

/// Keeps the Dock icon in step with the active theme. macOS picks the light or
/// dark variant of AppIcon.icon from the system appearance, so when Shell's
/// theme disagrees (Appearance forced to Light or Dark, or a light theme in the
/// dark slot) this swaps in the matching variant, pre-rendered at build time by
/// scripts/render-app-icons.sh. When they agree it restores the native icon, so
/// macOS keeps drawing it with Liquid Glass and the user's icon style.
@MainActor
enum AppIcon {
    /// The variant currently shown: true for dark, false for light, nil for native.
    private static var shown: Bool?
    private static var started = false
    private static var cache: [Bool: NSImage] = [:]

    static func start() {
        started = true
        // effectiveAppearance doesn't change when Shell overrides its own
        // appearance, so watch the system setting directly.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppIcon.update() }
        }
        update()
    }

    /// Called whenever the active theme or the system appearance may have changed.
    static func update() {
        guard started else { return }
        let dark = ConfigController.shared.theme.isDark
        let want: Bool? = dark == systemIsDark ? nil : dark
        guard want != shown else { return }
        shown = want
        // nil restores the bundle's icon.
        NSApp.applicationIconImage = want.flatMap(image(dark:))
    }

    private static var systemIsDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    private static func image(dark: Bool) -> NSImage? {
        if let cached = cache[dark] { return cached }
        let name = dark ? "AppIconDark" : "AppIconLight"
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let body = NSImage(contentsOf: url) else {
            Log.app.error("Missing \(name, privacy: .public).png; keeping the system app icon")
            return nil
        }
        // The rendered body is 824 pt; macOS icons sit on a 1024 pt canvas
        // with a 100 pt margin, so it matches the size of other Dock icons.
        let image = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { rect in
            body.draw(in: rect.insetBy(dx: 100, dy: 100))
            return true
        }
        cache[dark] = image
        return image
    }
}
