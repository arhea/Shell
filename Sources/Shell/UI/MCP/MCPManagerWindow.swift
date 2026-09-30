import AppKit
import SwiftUI

/// The "MCP Servers" window. One window, pointed at the directory of whatever
/// pane opened it (the repo's `.mcp.json`, your local and global servers,
/// plugins and claude.ai connectors).
@MainActor
final class MCPManagerWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: MCPManagerWindowController?
    let manager: MCPManager
    let selection: MCPSelection

    /// Opens the manager for a terminal session's directory (or its native Claude session).
    static func show(for session: TerminalSession?, select: String? = nil) {
        let claude = session?.nativeClaude
        let dir = claude?.directory ?? session?.workingDirectory ?? NSHomeDirectory()
        show(directory: dir, binary: claude?.request.binary, environment: claude?.request.environment, select: select)
    }

    static func show(directory: String, binary: String? = nil, environment: [String: String]? = nil, select: String? = nil) {
        if let existing = shared {
            existing.manager.switchDirectory(directory)
            if let select { existing.selection.name = select }
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let manager = MCPManager(directory: directory, binary: binary, environment: environment)
        let controller = MCPManagerWindowController(manager: manager)
        controller.selection.name = select
        shared = controller
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        manager.refresh()
    }

    private init(manager: MCPManager) {
        self.manager = manager
        selection = MCPSelection()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "MCP Servers"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 760, height: 460)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: MCPManagerView(manager: manager, selection: selection))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        manager.stop()
        MCPManagerWindowController.shared = nil
    }
}

@MainActor
@Observable
final class MCPSelection {
    var name: String?
}

struct MCPManagerView: View {
    @Bindable var manager: MCPManager
    @Bindable var selection: MCPSelection
    @State private var filter = ""
    @State private var showingAdd = false

    var body: some View {
        let p = ClaudePalette.current
        VStack(spacing: 0) {
            toolbar(p)
            p.border.frame(height: 1)
            HStack(spacing: 0) {
                sidebar(p).frame(width: 300)
                p.border.frame(width: 1)
                detail(p).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(p.background)
        .foregroundStyle(p.foreground)
        .sheet(isPresented: $showingAdd) {
            MCPAddServerSheet(manager: manager, hasRepository: manager.repository != nil) { name in
                selection.name = name
            }
        }
        .onChange(of: manager.servers) { _, servers in
            if selection.name == nil || !servers.contains(where: { $0.name == selection.name }) {
                selection.name = manager.grouped.first?.1.first?.name
            }
        }
    }

    // MARK: Toolbar

    private func toolbar(_ p: ClaudePalette) -> some View {
        HStack(spacing: 10) {
            Spacer().frame(width: 64) // traffic lights
            Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(p.cyan)
            Text("MCP Servers").font(.system(size: 13, weight: .semibold))
            contextChip(p)
            Spacer()
            if manager.needsAuthCount > 0 {
                Label("\(manager.needsAuthCount) need sign-in", systemImage: "person.badge.key")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(p.yellow)
            }
            if manager.isLoading { ProgressView().controlSize(.small) }
            Button { manager.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh status")
            Button { showingAdd = true } label: { Label("Add Server", systemImage: "plus") }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(p.surface)
        .background(WindowDragArea())
    }

    private func contextChip(_ p: ClaudePalette) -> some View {
        HStack(spacing: 4) {
            if let repo = manager.repository {
                Image(systemName: "shippingbox").foregroundStyle(p.cyan)
                Text(repo.github?.slug ?? repo.name)
                Image(systemName: "arrow.triangle.branch").foregroundStyle(p.magenta)
                Text(repo.branchLabel).lineLimit(1).truncationMode(.middle)
            } else {
                Image(systemName: "folder").foregroundStyle(p.blue)
                Text(ClaudeToolFormat.shortPath(manager.directory)).lineLimit(1).truncationMode(.head)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(p.raised))
        .help("Project servers come from \(manager.repository?.root.path ?? manager.directory)")
    }

    // MARK: Sidebar

    private func sidebar(_ p: ClaudePalette) -> some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(p.dim)
                TextField("Filter servers", text: $filter).textFieldStyle(.plain)
            }
            .font(.system(size: 12))
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 7).fill(p.raised))
            .padding(10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                    if manager.servers.isEmpty {
                        emptyState(p)
                    }
                    ForEach(manager.grouped, id: \.0) { group, servers in
                        let shown = servers.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
                        if !shown.isEmpty {
                            Text(group.title.uppercased())
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(p.dim)
                                .padding(.horizontal, 12)
                                .padding(.top, 10)
                                .padding(.bottom, 2)
                            ForEach(shown) { s in
                                MCPServerRow(server: s, selected: selection.name == s.name, busy: manager.busy.contains(s.name),
                                             waiting: manager.signingIn[s.name] != nil, palette: p) {
                                    selection.name = s.name
                                    manager.signIn(s.name)
                                }
                                .onTapGesture { selection.name = s.name }
                            }
                        }
                    }
                }
                .padding(.bottom, 10)
            }
        }
        .background(p.surface)
    }

    @ViewBuilder
    private func emptyState(_ p: ClaudePalette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if manager.isLoading {
                Text("Asking Claude Code for its MCP servers…").foregroundStyle(p.dim)
            } else if let err = manager.lastError {
                Text(err).foregroundStyle(p.red)
            } else {
                Text("No MCP servers configured.").foregroundStyle(p.dim)
            }
        }
        .font(.system(size: 12))
        .padding(12)
    }

    // MARK: Detail

    @ViewBuilder
    private func detail(_ p: ClaudePalette) -> some View {
        if let name = selection.name, let server = manager.server(name) {
            MCPServerDetail(manager: manager, server: server, palette: p)
                .id(server.name)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension").font(.system(size: 30)).foregroundStyle(p.dim)
                Text(manager.isLoading ? "Loading…" : "Select a server").foregroundStyle(p.dim)
                if let err = manager.lastError, !manager.servers.isEmpty {
                    Text(err).font(.system(size: 11)).foregroundStyle(p.red).multilineTextAlignment(.center).padding(.horizontal, 30)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Row

struct MCPServerRow: View {
    let server: MCPServerEntry
    let selected: Bool
    let busy: Bool
    let waiting: Bool
    let palette: ClaudePalette
    var onSignIn: () -> Void

    var body: some View {
        let p = palette
        HStack(spacing: 9) {
            MCPServerIcon(server: server, palette: p, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.displayName).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                HStack(spacing: 4) {
                    Circle().fill(MCPServerDetail.statusColor(server.status, p)).frame(width: 6, height: 6)
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(p.dim).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if busy || waiting {
                ProgressView().controlSize(.mini)
            } else if server.status == .needsAuth && server.canSignIn {
                Button("Sign in", action: onSignIn)
                    .buttonStyle(.borderedProminent)
                    .tint(p.claude)
                    .controlSize(.mini)
            } else if !server.tools.isEmpty {
                Text("\(server.tools.count)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(p.dim)
                    .help("\(server.tools.count) tools")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? p.claude.opacity(0.16) : .clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts = [server.status.title]
        if let plugin = server.pluginName { parts.append(plugin) }
        if server.status == .connected, !server.tools.isEmpty { parts.append("\(server.tools.count) tools") }
        return parts.joined(separator: " · ")
    }
}

/// The server's own icon when it publishes one, else a transport symbol.
struct MCPServerIcon: View {
    let server: MCPServerEntry
    let palette: ClaudePalette
    let size: CGFloat

    var body: some View {
        Group {
            if let image = dataImage {
                Image(nsImage: image).resizable().interpolation(.high)
            } else if let url = server.iconURL, url.scheme == "https", !url.pathExtension.lowercased().hasSuffix("svg") {
                AsyncImage(url: url) { img in img.resizable() } placeholder: { fallback }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
    }

    private var dataImage: NSImage? {
        guard let url = server.iconURL, url.scheme == "data", let comma = url.absoluteString.firstIndex(of: ","),
              let data = Data(base64Encoded: String(url.absoluteString[url.absoluteString.index(after: comma)...])) else { return nil }
        return NSImage(data: data)
    }

    private var fallback: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22).fill(palette.raised)
            Image(systemName: symbol).font(.system(size: size * 0.5)).foregroundStyle(palette.dim)
        }
    }

    private var symbol: String {
        switch server.group {
        case .claudeai: "cloud"
        case .plugin: "puzzlepiece.extension"
        default: server.transport == "stdio" ? "terminal" : "network"
        }
    }
}

// MARK: - Detail

struct MCPServerDetail: View {
    let manager: MCPManager
    let server: MCPServerEntry
    let palette: ClaudePalette
    @State private var toolFilter = ""
    @State private var confirmRemove = false
    @State private var removeError: String?

    /// Claude Code's tool-name normalization: anything but letters, digits, _ and - becomes _.
    static func normalized(_ s: String) -> String {
        String(s.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_" })
    }

    static func statusColor(_ s: MCPServerEntry.Status, _ p: ClaudePalette) -> Color {
        switch s {
        case .connected: p.green
        case .needsAuth: p.yellow
        case .failed: p.red
        case .pending: p.blue
        case .disabled: p.dim
        case .untrusted: p.yellow
        }
    }

    var body: some View {
        let p = palette
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(p)
                if let err = server.error ?? (server.status == .failed ? "Couldn't connect" : nil) {
                    callout(icon: "exclamationmark.triangle.fill", text: err, color: p.red, p)
                }
                if let url = manager.signingIn[server.name] {
                    signInWaiting(url, p)
                }
                if let err = manager.lastError, err.contains(server.name) {
                    callout(icon: "exclamationmark.circle", text: err, color: p.red, p)
                }
                actions(p)
                configuration(p)
                tools(p)
            }
            .padding(22)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .confirmationDialog("Remove \(server.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                Task { removeError = await manager.remove(server) }
            }
        } message: {
            Text("Runs `claude mcp remove --scope \(server.group.cliScope ?? "")`." + (server.group == .project ? " This edits .mcp.json in the repository." : ""))
        }
    }

    private func header(_ p: ClaudePalette) -> some View {
        HStack(alignment: .top, spacing: 14) {
            MCPServerIcon(server: server, palette: p, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(server.displayName).font(.system(size: 18, weight: .semibold))
                    Text(server.status.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Self.statusColor(server.status, p))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Self.statusColor(server.status, p).opacity(0.15)))
                }
                HStack(spacing: 6) {
                    Text(server.group.title)
                    if let plugin = server.pluginName { Text("· plugin \(plugin)") }
                    if let title = server.serverTitle {
                        Text("· \(title)\(server.serverVersion.map { " \($0)" } ?? "")")
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(p.dim)
                if let d = server.serverDescription, !d.isEmpty {
                    Text(d).font(.system(size: 12)).foregroundStyle(p.foreground.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                }
                if let site = server.websiteURL {
                    Link(site.host() ?? site.absoluteString, destination: site).font(.system(size: 11.5))
                }
            }
        }
    }

    private func signInWaiting(_ url: URL, _ p: ClaudePalette) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Finish signing in in your browser").font(.system(size: 12, weight: .semibold))
                Text(server.group == .claudeai
                     ? "Connect it on claude.ai; Shell reconnects when it's done."
                     : "Claude Code receives the callback and connects automatically.")
                    .font(.system(size: 11)).foregroundStyle(p.dim)
            }
            Spacer()
            Button("Open Again") { NSWorkspace.shared.open(url) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            Button("Cancel") { manager.cancelSignIn(server.name) }
        }
        .controlSize(.small)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9).fill(p.yellow.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(p.yellow.opacity(0.4)))
    }

    private func actions(_ p: ClaudePalette) -> some View {
        let busy = manager.busy.contains(server.name)
        return HStack(spacing: 8) {
            if server.canSignIn && (server.status == .needsAuth || server.status == .failed) {
                Button { manager.signIn(server.name) } label: {
                    Label(server.group == .claudeai ? "Connect on claude.ai" : "Sign In", systemImage: "person.badge.key")
                }
                .buttonStyle(.borderedProminent).tint(p.claude)
            }
            if server.status != .disabled && server.status != .untrusted {
                Button { manager.reconnect(server.name) } label: { Label("Reconnect", systemImage: "arrow.triangle.2.circlepath") }
            }
            if server.canSignIn, server.group != .claudeai, server.status == .connected {
                Button { manager.signOut(server.name) } label: { Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") }
                    .help("Clears the OAuth tokens Claude Code stored for this server")
            }
            if server.status == .untrusted {
                EmptyView()
            } else if server.status == .disabled {
                Button { manager.setEnabled(server.name, true) } label: { Label("Enable", systemImage: "power") }
            } else {
                Button { manager.setEnabled(server.name, false) } label: { Label("Disable", systemImage: "power") }
                    .help("Disables this server for this project")
            }
            if server.group == .claudeai {
                Link(destination: URL(string: "https://claude.ai/settings/connectors")!) {
                    Label("Manage on claude.ai", systemImage: "arrow.up.right.square")
                }
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            if server.isEditable {
                Button(role: .destructive) { confirmRemove = true } label: { Label("Remove", systemImage: "trash") }
            }
        }
        .controlSize(.regular)
        .disabled(busy)
        .overlay(alignment: .bottomLeading) {
            if let removeError { Text(removeError).font(.system(size: 11)).foregroundStyle(p.red).offset(y: 18) }
        }
    }

    private func configuration(_ p: ClaudePalette) -> some View {
        section("Configuration", p) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                row("Scope", server.group.title, p)
                row("Transport", server.transport == "claudeai-proxy" ? "claude.ai connector" : server.transport.uppercased(), p)
                if let url = server.url, !url.isEmpty { row("URL", url, p, mono: true) }
                if let cmd = server.command { row("Command", ([cmd] + server.args).joined(separator: " "), p, mono: true) }
                if !server.envKeys.isEmpty { row("Environment", server.envKeys.map { "\($0)=•••" }.joined(separator: "  "), p, mono: true) }
                if !server.headerKeys.isEmpty { row("Headers", server.headerKeys.map { "\($0): •••" }.joined(separator: "  "), p, mono: true) }
                if let file = configFile {
                    GridRow {
                        Text("Defined in").foregroundStyle(p.dim)
                        HStack(spacing: 6) {
                            Text(ClaudeToolFormat.shortPath(file)).font(.system(size: 11.5, design: .monospaced))
                            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }
                                .buttonStyle(.link).font(.system(size: 11.5))
                        }
                    }
                }
            }
            .font(.system(size: 12))
        }
    }

    private var configFile: String? {
        switch server.group {
        case .project: (manager.repository?.root.path ?? manager.directory) + "/.mcp.json"
        case .local, .user: NSHomeDirectory() + "/.claude.json"
        default: nil
        }
    }

    // MARK: Tools

    private func tools(_ p: ClaudePalette) -> some View {
        let details = manager.toolDetails[server.name]
        let byName = Dictionary((details ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        // Prefer the server's own list (it has descriptions), else Claude Code's names.
        let names: [String] = details?.map(\.name) ?? server.tools.map(\.name)
        let shown = names.filter { toolFilter.isEmpty || $0.localizedCaseInsensitiveContains(toolFilter)
            || (byName[$0]?.description.localizedCaseInsensitiveContains(toolFilter) ?? false) }
        return section("Tools", p, trailing: {
            HStack(spacing: 8) {
                if !names.isEmpty {
                    TextField("Filter tools", text: $toolFilter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .controlSize(.small)
                }
                toolDetailsButton(p, loaded: details != nil)
            }
        }) {
            VStack(alignment: .leading, spacing: 8) {
                if let err = manager.toolErrors[server.name] {
                    Text(err).font(.system(size: 11.5)).foregroundStyle(p.red)
                }
                if names.isEmpty {
                    Text(server.status == .connected ? "This server exposes no tools." : "Tools appear once the server is connected.")
                        .font(.system(size: 12)).foregroundStyle(p.dim)
                } else {
                    Text("\(names.count) tools" + (details == nil ? " · names from Claude Code" : " · from the server"))
                        .font(.system(size: 11)).foregroundStyle(p.dim)
                    ForEach(shown, id: \.self) { name in
                        let annotation = server.tools.first { $0.name == name }
                        MCPToolRow(name: name, info: byName[name], readOnly: byName[name]?.readOnly ?? annotation?.readOnly ?? false,
                                   destructive: byName[name]?.destructive ?? annotation?.destructive ?? false,
                                   qualified: "mcp__\(Self.normalized(server.name))__\(Self.normalized(name))", palette: p)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func toolDetailsButton(_ p: ClaudePalette, loaded: Bool) -> some View {
        if manager.loadingTools.contains(server.name) {
            ProgressView().controlSize(.small)
        } else if manager.canInspect(server) {
            Button(loaded ? "Reload Descriptions" : "Load Descriptions") { manager.loadToolDetails(server) }
                .controlSize(.small)
                .help(server.transport == "stdio"
                      ? "Starts \(server.command ?? "the server") briefly to ask for its tool list"
                      : "Connects to the server to ask for its tool list")
        } else if !server.tools.isEmpty {
            Text(server.group == .claudeai || server.hasOAuth || server.status == .needsAuth
                 ? "Descriptions need Claude Code's sign-in" : "Descriptions unavailable for \(server.transport.uppercased())")
                .font(.system(size: 10.5)).foregroundStyle(p.dim)
                .help("Claude Code keeps OAuth tokens to itself and only reports tool names. Shell can read descriptions from stdio and unauthenticated HTTP servers.")
        }
    }

    // MARK: Helpers

    private func section<Content: View, Trailing: View>(_ title: String, _ p: ClaudePalette, @ViewBuilder trailing: () -> Trailing = { EmptyView() },
                                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                trailing()
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(p.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(p.border, lineWidth: 0.5))
    }

    private func row(_ label: String, _ value: String, _ p: ClaudePalette, mono: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(p.dim)
            Text(value)
                .font(.system(size: 11.5, design: mono ? .monospaced : .default))
                .textSelection(.enabled)
                .lineLimit(3)
        }
    }

    private func callout(icon: String, text: String, color: Color, _ p: ClaudePalette) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.1)))
    }
}

struct MCPToolRow: View {
    let name: String
    let info: MCPToolInfo?
    let readOnly: Bool
    let destructive: Bool
    let qualified: String
    let palette: ClaudePalette
    @State private var expanded = false

    var body: some View {
        let p = palette
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(name).font(.system(size: 12, weight: .semibold, design: .monospaced))
                if let title = info?.title, title != name {
                    Text(title).font(.system(size: 11)).foregroundStyle(p.dim)
                }
                if readOnly { badge("read-only", p.green, p) }
                if destructive { badge("destructive", p.red, p) }
                Spacer()
                if let info, !info.parameters.isEmpty {
                    Button { expanded.toggle() } label: {
                        Text("\(info.parameters.count) param\(info.parameters.count == 1 ? "" : "s")")
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(p.dim)
                }
            }
            if let d = info?.description, !d.isEmpty {
                Text(d)
                    .font(.system(size: 11.5))
                    .foregroundStyle(p.foreground.opacity(0.8))
                    .lineLimit(expanded ? nil : 3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if expanded, let info {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(info.parameters, id: \.self) { param in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(param.name + (param.required ? "" : "?"))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(param.required ? p.claude : p.foreground)
                            Text(param.type).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(p.cyan)
                            Text(param.description).font(.system(size: 11)).foregroundStyle(p.dim).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(qualified).font(.system(size: 10, design: .monospaced)).foregroundStyle(p.dim).textSelection(.enabled).padding(.top, 2)
                }
                .padding(.leading, 10)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { p.border.opacity(0.6).frame(height: 0.5) }
    }

    private func badge(_ text: String, _ color: Color, _ p: ClaudePalette) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

// MARK: - Add server

struct MCPAddServerSheet: View {
    let manager: MCPManager
    let hasRepository: Bool
    var onAdded: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var scope = "local"
    @State private var transport = "http"
    @State private var url = ""
    @State private var command = ""
    @State private var pairs = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add MCP Server").font(.system(size: 15, weight: .semibold))
            Form {
                TextField("Name", text: $name, prompt: Text("e.g. linear"))
                Picker("Available in", selection: $scope) {
                    Text("This project, only you").tag("local")
                    if hasRepository { Text("This project, everyone (.mcp.json)").tag("project") }
                    Text("All your projects").tag("user")
                }
                Picker("Transport", selection: $transport) {
                    Text("HTTP").tag("http")
                    Text("SSE").tag("sse")
                    Text("stdio (local command)").tag("stdio")
                }
                .pickerStyle(.segmented)
                if transport == "stdio" {
                    TextField("Command", text: $command, prompt: Text("npx -y @modelcontextprotocol/server-github"))
                        .font(.system(.body, design: .monospaced))
                } else {
                    TextField("URL", text: $url, prompt: Text("https://mcp.example.com/mcp"))
                        .font(.system(.body, design: .monospaced))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(transport == "stdio" ? "Environment (KEY=value per line)" : "Headers (Name: value per line)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    TextEditor(text: $pairs)
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(height: 70)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.3)))
                    Text(transport == "stdio" ? "Use ${VAR} to read from your shell's environment instead of pasting secrets."
                         : "OAuth servers don't need headers: add them, then use Sign In.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            if let error {
                Text(error).font(.system(size: 11.5)).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Text(scope == "project" ? "Writes .mcp.json in the repository (commit it to share)." : "Runs `claude mcp add-json`.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || (transport == "stdio" ? command.isEmpty : url.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private func save() {
        var config: [String: Any] = ["type": transport]
        let lines = pairs.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if transport == "stdio" {
            let parts = MCPAddServerSheet.splitCommand(command)
            guard let first = parts.first else { return }
            config["command"] = first
            config["args"] = Array(parts.dropFirst())
            var env: [String: String] = [:]
            for l in lines { if let eq = l.firstIndex(of: "=") { env[String(l[..<eq])] = String(l[l.index(after: eq)...]) } }
            if !env.isEmpty { config["env"] = env }
        } else {
            config["url"] = url.trimmingCharacters(in: .whitespaces)
            var headers: [String: String] = [:]
            for l in lines {
                if let c = l.firstIndex(of: ":") {
                    headers[String(l[..<c]).trimmingCharacters(in: .whitespaces)] = String(l[l.index(after: c)...]).trimmingCharacters(in: .whitespaces)
                }
            }
            if !headers.isEmpty { config["headers"] = headers }
        }
        saving = true
        let serverName = name.trimmingCharacters(in: .whitespaces)
        Task {
            error = await manager.add(name: serverName, scope: scope, config: config)
            saving = false
            if error == nil {
                onAdded(serverName)
                dismiss()
            }
        }
    }

    /// Splits a command line on spaces, honoring simple quotes.
    static func splitCommand(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?
        for c in s {
            if let q = quote {
                if c == q { quote = nil } else { cur.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == " " {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else {
                cur.append(c)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}
