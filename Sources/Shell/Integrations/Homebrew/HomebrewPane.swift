import AppKit
import SwiftUI

struct HomebrewPane: View {
    /// App-wide model (observed through property access; not state this view owns).
    private let brew: BrewService
    @State private var scope: Scope
    @State private var query: String
    @State private var showDependencies: Bool

    /// The parameters let unit tests render each state.
    init(brew: BrewService = .shared, scope: Scope = .installed, query: String = "", showDependencies: Bool = false) {
        self.brew = brew
        _scope = State(initialValue: scope)
        _query = State(initialValue: query)
        _showDependencies = State(initialValue: showDependencies)
    }

    enum Scope: String, CaseIterable, Identifiable {
        case installed = "Installed", updates = "Updates", search = "Search"
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if brew.isInstalled {
                manager
            } else {
                notInstalled
            }
        }
        .task { await brew.refresh() }
    }

    private var notInstalled: some View {
        VStack(spacing: 14) {
            Image(systemName: "mug").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Homebrew isn't installed").font(.title2.weight(.semibold))
            Text("Homebrew is the package manager for macOS. The official installer runs in a new Shell tab so you can review it and enter your password.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
            Text(BrewService.installCommand)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            HStack {
                Button("Install Homebrew") { brew.installHomebrew() }.buttonStyle(.borderedProminent)
                Button("Check Again") { Task { await brew.refresh() } }
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var manager: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $scope) {
                    ForEach(Scope.allCases) { s in
                        if s == .updates && !brew.outdated.isEmpty {
                            Text("Updates (\(brew.outdated.count))").tag(s)
                        } else {
                            Text(s.rawValue).tag(s)
                        }
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
                TextField(scope == .search ? "Search formulae and casks" : "Filter", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: query) { _, q in if scope == .search { brew.search(q) } }
                    .onSubmit { if scope == .search { brew.search(query) } }
                if brew.isLoading || brew.isSearching { ProgressView().controlSize(.small) }
                Menu {
                    Button("Update & Upgrade All") { brew.upgradeAll() }
                    Button("Clean Up Old Versions") { brew.cleanup() }
                    Button("Run brew doctor") { brew.doctor() }
                    Divider()
                    Button("Refresh") { Task { await brew.refresh() } }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(12)
            Divider()
            AutoUpdateBar(maintenance: .homebrew, schedule: \.brewAutoUpdate)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            list
            Divider()
            HStack {
                Text(brew.version ?? "Homebrew").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if scope == .installed {
                    Toggle("Show dependencies", isOn: $showDependencies).toggleStyle(.checkbox).font(.caption)
                }
                Text("\(brew.installed.filter { $0.kind == .formula }.count) formulae · \(brew.installed.filter { $0.kind == .cask }.count) casks")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .onChange(of: scope) { _, s in if s == .search { brew.search(query) } }
    }

    private var items: [BrewPackage] {
        switch scope {
        case .installed:
            return brew.installed.filter {
                (showDependencies || $0.installedOnRequest || $0.kind == .cask) &&
                    (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query))
            }
        case .updates:
            return brew.outdated
        case .search:
            return brew.searchResults.map { r in
                brew.installed.first { $0.id == r.id } ?? r
            }
        }
    }

    @ViewBuilder private var list: some View {
        let rows = items
        if rows.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: scope == .updates ? "checkmark.seal" : "shippingbox").font(.title).foregroundStyle(.secondary)
                Text(scope == .updates ? "Everything is up to date" : scope == .search ? (query.count < 2 ? "Type to search" : "No results") : "No packages")
                    .foregroundStyle(.secondary)
                if scope == .updates {
                    Button("Check for Updates") { AppDelegate.shared.runInTerminal("brew update && brew outdated", title: "brew update") }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(rows) { p in BrewRow(package: p, brew: brew) }
                .listStyle(.inset)
        }
    }
}

struct BrewRow: View {
    let package: BrewPackage
    let brew: BrewService

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: package.kind == .cask ? "macwindow" : "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(package.displayName).font(.system(size: 13, weight: .medium))
                    if package.displayName != package.name {
                        Text(package.name).font(.caption).foregroundStyle(.secondary)
                    }
                    if package.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                }
                if !package.description.isEmpty {
                    Text(package.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let v = package.installedVersion {
                    Text(v).font(.caption.monospacedDigit())
                    if package.outdated {
                        Text("→ \(package.version)").font(.caption.monospacedDigit()).foregroundStyle(.orange)
                    }
                } else {
                    Text(package.version).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if package.isInstalled {
                if package.outdated {
                    Button("Upgrade") { brew.upgrade(package) }
                }
                Menu {
                    Button("Uninstall", role: .destructive) { brew.uninstall(package) }
                    if let hp = package.homepage, let url = URL(string: hp) {
                        Button("Open Homepage") { NSWorkspace.shared.open(url) }
                    }
                    Button("Show Info in Terminal") {
                        AppDelegate.shared.runInTerminal("brew info \(package.kind == .cask ? "--cask " : "")\(package.name)", title: package.name)
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                Button("Install") { brew.install(package) }.buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }
}
