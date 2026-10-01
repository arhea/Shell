import AppKit

/// Every user-bindable command. Defaults follow iTerm2 so muscle memory carries over.
enum ShortcutAction: String, CaseIterable, Identifiable {
    // App
    case settings, checkForUpdates, commandPalette, homebrew, nodeSetup, zshSetup, mcpServers, reloadConfig
    // Windows, tabs, panes
    case newWindow, newTab, closePane, closeTab, closeWindow
    case splitRight, splitDown
    case selectPaneLeft, selectPaneRight, selectPaneUp, selectPaneDown, nextPane, previousPane
    case zoomPane, equalizePanes, broadcastInput
    case nextTab, previousTab, moveTabLeft, moveTabRight, renameTab, newTabGroup, moveTabToNewWindow
    case tab1, tab2, tab3, tab4, tab5, tab6, tab7, tab8, lastTab
    case toggleTabBarStyle, toggleTabSidebar, claudeInNewWorktree
    // Terminal
    case copy, copyLastCommand, copyLastOutput, paste, selectAll, clearBuffer, find, findNext, findPrevious
    case jumpToPreviousPrompt, jumpToNextPrompt, scrollToTop, scrollToBottom, scrollPageUp, scrollPageDown
    case increaseFontSize, decreaseFontSize, resetFontSize
    case toggleInputEditor, toggleInputPosition, focusInput, toggleFullScreen
    case toggleNotifications, toggleSidebar, claudeDashboard, github, reviewChanges

    var id: String { rawValue }

    enum Category: String, CaseIterable {
        case app = "Application", windows = "Windows & Tabs", panes = "Split Panes", terminal = "Terminal", view = "View"
    }

    var category: Category {
        switch self {
        case .settings, .checkForUpdates, .commandPalette, .homebrew, .nodeSetup, .zshSetup, .mcpServers, .reloadConfig, .toggleNotifications: .app
        case .newWindow, .newTab, .closeTab, .closeWindow, .nextTab, .previousTab, .moveTabLeft, .moveTabRight,
             .renameTab, .newTabGroup, .moveTabToNewWindow, .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .lastTab,
             .toggleTabBarStyle, .toggleTabSidebar, .claudeInNewWorktree: .windows
        case .closePane, .splitRight, .splitDown, .selectPaneLeft, .selectPaneRight, .selectPaneUp, .selectPaneDown,
             .nextPane, .previousPane, .zoomPane, .equalizePanes, .broadcastInput: .panes
        case .copy, .copyLastCommand, .copyLastOutput, .paste, .selectAll, .clearBuffer, .find, .findNext, .findPrevious, .jumpToPreviousPrompt,
             .jumpToNextPrompt, .scrollToTop, .scrollToBottom, .scrollPageUp, .scrollPageDown: .terminal
        case .increaseFontSize, .decreaseFontSize, .resetFontSize, .toggleInputEditor, .toggleInputPosition,
             .focusInput, .toggleFullScreen, .toggleSidebar, .claudeDashboard, .github, .reviewChanges: .view
        }
    }

    var title: String {
        switch self {
        case .settings: "Settings…"
        case .checkForUpdates: "Check for Updates…"
        case .commandPalette: "Command Palette…"
        case .homebrew: "Homebrew Packages…"
        case .mcpServers: "MCP Servers…"
        case .nodeSetup: "Node.js Versions…"
        case .zshSetup: "Zsh & Oh My Zsh…"
        case .reloadConfig: "Reload Configuration"
        case .toggleNotifications: "Agent Activity"
        case .toggleSidebar: "Toggle Files & Worktrees Sidebar"
        case .claudeDashboard: "Claude Dashboard"
        case .github: "Open GitHub"
        case .newWindow: "New Window"
        case .newTab: "New Tab"
        case .closePane: "Close Pane"
        case .closeTab: "Close Tab"
        case .closeWindow: "Close Window"
        case .splitRight: "Split Right"
        case .splitDown: "Split Down"
        case .selectPaneLeft: "Select Pane Left"
        case .selectPaneRight: "Select Pane Right"
        case .selectPaneUp: "Select Pane Above"
        case .selectPaneDown: "Select Pane Below"
        case .nextPane: "Next Pane"
        case .previousPane: "Previous Pane"
        case .zoomPane: "Maximize Pane"
        case .equalizePanes: "Equalize Pane Sizes"
        case .broadcastInput: "Broadcast Input to All Panes"
        case .nextTab: "Show Next Tab"
        case .previousTab: "Show Previous Tab"
        case .moveTabLeft: "Move Tab Left"
        case .moveTabRight: "Move Tab Right"
        case .renameTab: "Rename Tab…"
        case .newTabGroup: "New Tab Group…"
        case .moveTabToNewWindow: "Move Tab to New Window"
        case .tab1: "Select Tab 1"
        case .tab2: "Select Tab 2"
        case .tab3: "Select Tab 3"
        case .tab4: "Select Tab 4"
        case .tab5: "Select Tab 5"
        case .tab6: "Select Tab 6"
        case .tab7: "Select Tab 7"
        case .tab8: "Select Tab 8"
        case .lastTab: "Select Last Tab"
        case .toggleTabBarStyle: "Toggle Vertical Tabs"
        case .toggleTabSidebar: "Show or Hide Tab Sidebar"
        case .claudeInNewWorktree: "Claude in New Worktree…"
        case .reviewChanges: "Review Changes"
        case .copy: "Copy"
        case .copyLastCommand: "Copy Last Command"
        case .copyLastOutput: "Copy Last Output"
        case .paste: "Paste"
        case .selectAll: "Select All"
        case .clearBuffer: "Clear Buffer"
        case .find: "Find…"
        case .findNext: "Find Next"
        case .findPrevious: "Find Previous"
        case .jumpToPreviousPrompt: "Jump to Previous Command"
        case .jumpToNextPrompt: "Jump to Next Command"
        case .scrollToTop: "Scroll to Top"
        case .scrollToBottom: "Scroll to Bottom"
        case .scrollPageUp: "Scroll Page Up"
        case .scrollPageDown: "Scroll Page Down"
        case .increaseFontSize: "Make Text Bigger"
        case .decreaseFontSize: "Make Text Smaller"
        case .resetFontSize: "Make Text Normal Size"
        case .toggleInputEditor: "Toggle Native Prompt"
        case .toggleInputPosition: "Toggle Input Position (Top/Bottom)"
        case .focusInput: "Focus Native Prompt"
        case .toggleFullScreen: "Toggle Full Screen"
        }
    }

    /// iTerm2-style defaults.
    var defaultShortcut: KeyShortcut? {
        switch self {
        case .settings: .cmd(",")
        case .commandPalette: .cmdShift("p")
        case .checkForUpdates, .homebrew, .nodeSetup, .zshSetup, .mcpServers, .moveTabToNewWindow, .equalizePanes: nil
        case .reloadConfig: .cmdShift(",")
        case .toggleNotifications: .cmdOpt("a")
        case .toggleSidebar: .cmdCtrl("b")
        case .claudeDashboard: .cmdCtrl("a")
        case .github: .cmdCtrl("h")
        case .newWindow: .cmd("n")
        case .newTab: .cmd("t")
        case .closePane: .cmd("w")
        case .closeTab: .cmdOpt("w")
        case .closeWindow: .cmdShift("w")
        case .splitRight: .cmd("d")
        case .splitDown: .cmdShift("d")
        case .selectPaneLeft: .cmdOpt("left")
        case .selectPaneRight: .cmdOpt("right")
        case .selectPaneUp: .cmdOpt("up")
        case .selectPaneDown: .cmdOpt("down")
        case .nextPane: .cmd("]")
        case .previousPane: .cmd("[")
        case .zoomPane: .cmdShift("return")
        case .broadcastInput: .cmdOpt("i")
        case .nextTab: .cmdShift("]")
        case .previousTab: .cmdShift("[")
        case .moveTabLeft: .init(key: "left", modifiers: [.command, .shift, .control])
        case .moveTabRight: .init(key: "right", modifiers: [.command, .shift, .control])
        case .renameTab: .cmdShift("i")
        case .newTabGroup: .cmdCtrl("g")
        case .tab1: .cmd("1")
        case .tab2: .cmd("2")
        case .tab3: .cmd("3")
        case .tab4: .cmd("4")
        case .tab5: .cmd("5")
        case .tab6: .cmd("6")
        case .tab7: .cmd("7")
        case .tab8: .cmd("8")
        case .lastTab: .cmd("9")
        case .toggleTabBarStyle: .cmdCtrl("t")
        case .toggleTabSidebar: .cmdCtrl("s")
        case .claudeInNewWorktree: .cmdOpt("n")
        case .reviewChanges: .cmdShift("r")
        case .copy: .cmd("c")
        case .copyLastCommand: .cmdShift("c")
        case .copyLastOutput: .init(key: "c", modifiers: [.command, .shift, .option])
        case .paste: .cmd("v")
        case .selectAll: .cmd("a")
        case .clearBuffer: .cmd("k")
        case .find: .cmd("f")
        case .findNext: .cmd("g")
        case .findPrevious: .cmdShift("g")
        case .jumpToPreviousPrompt: .cmdShift("up")
        case .jumpToNextPrompt: .cmdShift("down")
        case .scrollToTop: .cmd("home")
        case .scrollToBottom: .cmd("end")
        case .scrollPageUp: .cmd("pageup")
        case .scrollPageDown: .cmd("pagedown")
        case .increaseFontSize: .cmd("=")
        case .decreaseFontSize: .cmd("-")
        case .resetFontSize: .cmd("0")
        case .toggleInputEditor: .cmdCtrl("e")
        case .toggleInputPosition: .cmdCtrl("p")
        case .focusInput: .cmdOpt("l")
        case .toggleFullScreen: .cmd("return")
        }
    }

    /// Effective shortcut after user overrides.
    @MainActor
    var shortcut: KeyShortcut? {
        let overrides = SettingsStore.shared.settings.shortcuts
        if let override = overrides[rawValue] { return override }
        return defaultShortcut
    }

    /// Selector sent through the responder chain when this action fires.
    var selector: Selector {
        switch self {
        case .copy: #selector(NSText.copy(_:))
        case .paste: #selector(NSText.paste(_:))
        case .selectAll: #selector(NSText.selectAll(_:))
        case .toggleFullScreen: #selector(NSWindow.toggleFullScreen(_:))
        default: #selector(ShortcutActionHandling.performShortcutAction(_:))
        }
    }
}

/// Implemented by responders (window controllers, app delegate) that handle
/// menu-driven actions. The action id travels in `NSMenuItem.representedObject`.
@MainActor @objc protocol ShortcutActionHandling {
    func performShortcutAction(_ sender: Any?)
}

extension ShortcutAction {
    /// Resolves the action from a menu item or palette sender.
    static func from(sender: Any?) -> ShortcutAction? {
        if let item = sender as? NSMenuItem, let id = item.representedObject as? String {
            return ShortcutAction(rawValue: id)
        }
        if let action = sender as? ShortcutActionBox { return action.action }
        return nil
    }
}

/// Lets non-menu callers (command palette, key handlers) dispatch actions.
final class ShortcutActionBox: NSObject {
    let action: ShortcutAction
    init(_ action: ShortcutAction) { self.action = action }
}

extension NSMenuItem {
    /// Applies a shortcut, translating shifted punctuation the way AppKit expects.
    func apply(_ shortcut: KeyShortcut?) {
        guard let shortcut else {
            keyEquivalent = ""
            keyEquivalentModifierMask = []
            return
        }
        var equivalent = shortcut.keyEquivalent
        var mask = shortcut.modifierFlags
        let shifted: [String: String] = [
            "[": "{", "]": "}", "=": "+", "-": "_", "1": "!", "2": "@", "3": "#", "4": "$", "5": "%",
            "6": "^", "7": "&", "8": "*", "9": "(", "0": ")", ";": ":", "'": "\"", ",": "<", ".": ">",
            "/": "?", "\\": "|", "`": "~",
        ]
        if mask.contains(.shift), let s = shifted[shortcut.key] {
            equivalent = s
            mask.remove(.shift)
        }
        keyEquivalent = equivalent
        keyEquivalentModifierMask = mask
    }
}
