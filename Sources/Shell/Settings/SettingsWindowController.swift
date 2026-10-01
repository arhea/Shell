import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, text, chatText, terminal, input, tabs, shortcuts, shell, homebrew, node, go, worktrees, integrations, agentStorage, intelligence, advanced
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Themes & Colors"
        case .text: "Text & Cursor"
        case .chatText: "Chat Text"
        case .terminal: "Terminal"
        case .input: "Prompt & Completions"
        case .tabs: "Tabs & Windows"
        case .shortcuts: "Keyboard Shortcuts"
        case .shell: "Zsh & Oh My Zsh"
        case .homebrew: "Homebrew"
        case .node: "Node.js"
        case .go: "Go"
        case .worktrees: "Worktrees"
        case .integrations: "Claude & Codex"
        case .agentStorage: "Agent Storage"
        case .intelligence: "Apple Intelligence"
        case .advanced: "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .text: "textformat"
        case .chatText: "text.bubble"
        case .terminal: "terminal"
        case .input: "text.cursor"
        case .tabs: "rectangle.stack"
        case .shortcuts: "keyboard"
        case .shell: "chevron.left.forwardslash.chevron.right"
        case .homebrew: "mug"
        case .node: "hexagon"
        case .go: "shippingbox.and.arrow.backward"
        case .worktrees: "square.stack.3d.up"
        case .integrations: "sparkles"
        case .agentStorage: "externaldrive"
        case .intelligence: "apple.intelligence"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    var pane: SettingsPane = .general
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()
    let navigation = SettingsNavigation()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false
        window.center()
        // Unit tests create this window too; keep them out of the real defaults.
        if !AppEnvironment.isRunningTests { window.setFrameAutosaveName("ShellSettings") }
        super.init(window: window)
        window.delegate = self
        let host = NSHostingController(rootView: SettingsRootView(navigation: navigation))
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(NSSize(width: 900, height: 640))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(pane: SettingsPane? = nil) {
        if let pane { navigation.pane = pane }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct SettingsRootView: View {
    @Bindable var navigation: SettingsNavigation
    @State private var visibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            List(selection: $navigation.pane) {
                Section {
                    ForEach([SettingsPane.general, .appearance, .text, .chatText, .terminal, .input, .tabs, .shortcuts, .advanced]) { row($0) }
                }
                Section("Tools") {
                    ForEach([SettingsPane.shell, .homebrew, .worktrees]) { row($0) }
                }
                Section("Languages") {
                    ForEach([SettingsPane.node, .go]) { row($0) }
                }
                Section("Agents") {
                    ForEach([SettingsPane.integrations, .agentStorage]) { row($0) }
                }
                Section("Apple Intelligence") {
                    row(.intelligence)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .navigationTitle(navigation.pane.title)
        }
    }

    private func row(_ pane: SettingsPane) -> some View {
        Label(pane.title, systemImage: pane.symbol).tag(pane)
    }

    @ViewBuilder private var detail: some View {
        switch navigation.pane {
        case .general: GeneralSettingsPane()
        case .appearance: AppearanceSettingsPane()
        case .text: TextSettingsPane()
        case .chatText: ChatTextSettingsPane()
        case .terminal: TerminalSettingsPane()
        case .input: InputSettingsPane()
        case .tabs: TabsSettingsPane()
        case .shortcuts: ShortcutsSettingsPane()
        case .shell: ZshSettingsPane()
        case .homebrew: HomebrewPane()
        case .node: NodePane()
        case .go: GoSettingsPane()
        case .worktrees: WorktreesSettingsPane()
        case .integrations: IntegrationsSettingsPane()
        case .agentStorage: AgentStoragePane()
        case .intelligence: IntelligenceSettingsPane()
        case .advanced: AdvancedSettingsPane()
        }
    }
}

/// Binding into the shared settings store.
@MainActor
func setting<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
    Binding(
        get: { SettingsStore.shared.settings[keyPath: keyPath] },
        set: { SettingsStore.shared.settings[keyPath: keyPath] = $0 })
}
