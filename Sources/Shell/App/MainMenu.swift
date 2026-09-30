import AppKit

/// Builds the menu bar from `ShortcutAction`s so every command is
/// discoverable and user-rebindable (Settings › Keyboard Shortcuts).
@MainActor
enum MainMenu {
    static func install() {
        let main = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Shell", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item(.settings))
        appMenu.addItem(item(.reloadConfig))
        appMenu.addItem(.separator())
        appMenu.addItem(item(.zshSetup))
        appMenu.addItem(item(.homebrew))
        appMenu.addItem(item(.mcpServers))
        appMenu.addItem(item(.nodeSetup))
        appMenu.addItem(.separator())
        let services = NSMenu()
        let servicesItem = appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Shell", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Shell", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, title: "Shell", to: main)

        // Shell (iTerm2 calls this menu "Shell")
        let shell = NSMenu(title: "Shell")
        shell.addItem(item(.newWindow))
        shell.addItem(item(.newTab))
        shell.addItem(.separator())
        shell.addItem(item(.splitRight))
        shell.addItem(item(.splitDown))
        shell.addItem(.separator())
        shell.addItem(item(.closePane))
        shell.addItem(item(.closeTab))
        shell.addItem(item(.closeWindow))
        add(shell, title: "File", to: main)

        // Edit
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(item(.copy))
        edit.addItem(item(.copyLastCommand))
        edit.addItem(item(.copyLastOutput))
        edit.addItem(item(.paste))
        edit.addItem(item(.selectAll))
        edit.addItem(.separator())
        edit.addItem(item(.clearBuffer))
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        find.addItem(item(.find))
        find.addItem(item(.findNext))
        find.addItem(item(.findPrevious))
        let findItem = edit.addItem(withTitle: "Find", action: nil, keyEquivalent: "")
        findItem.submenu = find
        edit.addItem(.separator())
        let emoji = edit.addItem(withTitle: "Emoji & Symbols", action: #selector(NSApplication.orderFrontCharacterPalette(_:)), keyEquivalent: " ")
        emoji.keyEquivalentModifierMask = [.command, .control]
        add(edit, title: "Edit", to: main)

        // View
        let view = NSMenu(title: "View")
        view.addItem(item(.commandPalette))
        view.addItem(.separator())
        view.addItem(item(.toggleTabBarStyle))
        view.addItem(item(.toggleInputEditor))
        view.addItem(item(.toggleInputPosition))
        view.addItem(item(.toggleSidebar))
        view.addItem(item(.focusInput))
        view.addItem(.separator())
        view.addItem(item(.increaseFontSize))
        view.addItem(item(.decreaseFontSize))
        view.addItem(item(.resetFontSize))
        view.addItem(.separator())
        view.addItem(item(.jumpToPreviousPrompt))
        view.addItem(item(.jumpToNextPrompt))
        view.addItem(item(.scrollToTop))
        view.addItem(item(.scrollToBottom))
        view.addItem(item(.scrollPageUp))
        view.addItem(item(.scrollPageDown))
        view.addItem(.separator())
        view.addItem(item(.toggleNotifications))
        view.addItem(item(.claudeDashboard))
        view.addItem(item(.github))
        view.addItem(item(.toggleFullScreen))
        add(view, title: "View", to: main)

        // Tabs
        let tabs = NSMenu(title: "Tabs")
        tabs.addItem(item(.nextTab))
        tabs.addItem(item(.previousTab))
        tabs.addItem(item(.moveTabLeft))
        tabs.addItem(item(.moveTabRight))
        tabs.addItem(.separator())
        tabs.addItem(item(.renameTab))
        tabs.addItem(item(.newTabGroup))
        tabs.addItem(item(.moveTabToNewWindow))
        tabs.addItem(.separator())
        for a in [ShortcutAction.tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .lastTab] { tabs.addItem(item(a)) }
        add(tabs, title: "Tabs", to: main)

        // Panes
        let panes = NSMenu(title: "Panes")
        panes.addItem(item(.splitRight))
        panes.addItem(item(.splitDown))
        panes.addItem(.separator())
        for a in [ShortcutAction.selectPaneLeft, .selectPaneRight, .selectPaneUp, .selectPaneDown, .nextPane, .previousPane] {
            panes.addItem(item(a))
        }
        panes.addItem(.separator())
        panes.addItem(item(.zoomPane))
        panes.addItem(item(.equalizePanes))
        panes.addItem(item(.broadcastInput))
        add(panes, title: "Panes", to: main)

        // Window
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        add(window, title: "Window", to: main)
        NSApp.windowsMenu = window

        let help = NSMenu(title: "Help")
        // Restart to Update shows only once an update is found (UpdateMenuItem).
        help.addItem(item(.checkForUpdates))
        help.addItem(UpdateMenuItem.shared)
        help.addItem(.separator())
        help.delegate = UpdateMenuItem.shared
        // macOS adds the search field; these give it something to find.
        help.addItem(HelpMenuItem(title: "Keyboard Shortcuts", pane: .shortcuts))
        help.addItem(HelpMenuItem(title: "Claude Code & Codex Settings", pane: .integrations))
        help.addItem(HelpMenuItem(title: "Chat Text Settings", pane: .chatText))
        add(help, title: "Help", to: main)
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }

    private static func add(_ menu: NSMenu, title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        main.addItem(item)
    }

    static func item(_ action: ShortcutAction) -> NSMenuItem {
        let item = NSMenuItem(title: action.title, action: action.selector, keyEquivalent: "")
        item.representedObject = action.rawValue
        item.apply(action.shortcut)
        return item
    }
}

/// A Help menu item that opens a Settings pane.
@MainActor
final class HelpMenuItem: NSMenuItem {
    private let pane: SettingsPane

    init(title: String, pane: SettingsPane) {
        self.pane = pane
        super.init(title: title, action: #selector(open), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func open() { SettingsWindowController.shared.show(pane: pane) }
}

/// Help › Restart to Update. Hidden until the updater finds a newer release;
/// refreshed each time the Help menu opens.
@MainActor
final class UpdateMenuItem: NSMenuItem, NSMenuDelegate {
    static let shared = UpdateMenuItem()

    private init() {
        super.init(title: "Restart to Update", action: #selector(run), keyEquivalent: "")
        target = self
        isHidden = true // until menuNeedsUpdate finds an update
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    func refresh() {
        let updater = SoftwareUpdater.shared
        isHidden = false
        isEnabled = true
        switch updater.phase {
        case .ready(let r):
            title = "Restart to Update to Shell \(r.version)"
        case .available(let r):
            title = updater.installBlocker == nil ? "Install Shell \(r.version) and Restart" : "Download Shell \(r.version)…"
        case .downloading(let r):
            title = "Downloading Shell \(r.version)…"
            isEnabled = false
        default:
            isHidden = true
        }
    }

    @objc private func run() {
        let updater = SoftwareUpdater.shared
        switch updater.phase {
        case .available(let r) where updater.installBlocker != nil:
            NSWorkspace.shared.open(r.notesURL)
        case .available:
            SettingsWindowController.shared.show(pane: .general) // shows download progress
            updater.installAndRelaunch()
        default:
            updater.installAndRelaunch()
        }
    }
}
