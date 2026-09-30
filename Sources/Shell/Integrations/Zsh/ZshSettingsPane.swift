import AppKit
import SwiftUI

struct ZshSettingsPane: View {
    /// App-wide model (observed through property access; not state this view owns).
    private let zsh = ZshService.shared
    @State private var pluginFilter = ""
    @State private var changed = false

    static let recommended = ["git", "brew", "macos", "z", "fzf", "docker", "kubectl", "npm", "golang", "python",
                              "gcloud", "aws", "terraform", "sudo", "extract", "colored-man-pages", "copypath", "history"]

    var body: some View {
        Form {
            Section("Zsh") {
                LabeledContent("Version", value: zsh.zshVersion ?? "…")
                LabeledContent("Login shell") {
                    HStack {
                        Text(zsh.loginShell)
                        if !zsh.isZshDefault {
                            Button("Make zsh My Default Shell") { zsh.makeZshDefault() }
                        } else {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
                LabeledContent("Config") {
                    HStack {
                        Text(zsh.zshrcURL.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Button("Open") {
                            if !FileManager.default.fileExists(atPath: zsh.zshrcURL.path) {
                                FileManager.default.createFile(atPath: zsh.zshrcURL.path, contents: Data())
                            }
                            NSWorkspace.shared.open(zsh.zshrcURL)
                        }
                    }
                }
            }

            if zsh.isOhMyZshInstalled {
                ohMyZsh
            } else {
                Section("Oh My Zsh") {
                    Text("Oh My Zsh adds 300+ plugins and 140+ themes. The official installer runs in a new tab; it backs up your existing .zshrc to .zshrc.pre-oh-my-zsh.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text(ZshService.ohMyZshInstall).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Install Oh My Zsh") { zsh.installOhMyZsh() }.buttonStyle(.borderedProminent)
                }
            }

            if let err = zsh.lastError {
                Section { Text(err).foregroundStyle(.red).font(.caption) }
            }
        }
        .formStyle(.grouped)
        .task { await zsh.refresh() }
        .toolbar {
            ToolbarItem {
                Button { Task { await zsh.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
            }
        }
    }

    @ViewBuilder private var ohMyZsh: some View {
        Section("Oh My Zsh") {
            LabeledContent("Installed at", value: zsh.omzPath ?? "")
            HStack {
                Button("Update Oh My Zsh") { zsh.updateOhMyZsh() }
                Spacer()
                if changed {
                    Button("Apply to Open Tabs") {
                        zsh.reloadOpenShells()
                        changed = false
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Restarts idle shells so .zshrc changes take effect")
                }
            }
            Text("Changes are written to .zshrc (a backup is kept at .zshrc.shell-backup). New tabs pick them up automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section("Theme") {
            Picker("Oh My Zsh theme", selection: Binding(
                get: { zsh.theme ?? "" },
                set: { zsh.setTheme($0); changed = true })) {
                if !(zsh.availableThemes.contains(zsh.theme ?? "")) {
                    Text(zsh.theme ?? "(none)").tag(zsh.theme ?? "")
                }
                ForEach(zsh.availableThemes, id: \.self) { Text($0).tag($0) }
            }
            Text("Your theme is used as the command header when Prompt & Completions › Command header is “My zsh prompt”, and as the live prompt when the input editor is off.")
                .font(.caption).foregroundStyle(.secondary)
            if !zsh.availableThemes.contains("powerlevel10k/powerlevel10k") {
                Button("Install Powerlevel10k") { zsh.installPowerlevel10k(); changed = true }
            }
        }

        Section("Popular plugins") {
            ForEach(ZshService.externalPlugins) { p in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).font(.system(size: 13, weight: .medium))
                        Text(p.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if zsh.isPluginInstalled(p.name) {
                        Toggle("", isOn: pluginBinding(p.name)).labelsHidden().toggleStyle(.switch)
                    } else {
                        Button("Install") { zsh.installExternal(p); changed = true }
                    }
                }
            }
        }

        Section("Plugins (\(zsh.enabledPlugins.count) enabled)") {
            TextField("Filter plugins", text: $pluginFilter).textFieldStyle(.roundedBorder)
            let names = zsh.availablePlugins.filter {
                pluginFilter.isEmpty ? (Self.recommended.contains($0) || zsh.enabledPlugins.contains($0)) : $0.localizedCaseInsensitiveContains(pluginFilter)
            }
            ForEach(names, id: \.self) { name in
                Toggle(name, isOn: pluginBinding(name))
            }
            if pluginFilter.isEmpty {
                Text("Showing enabled and commonly used plugins. Filter to browse all \(zsh.availablePlugins.count).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func pluginBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { zsh.enabledPlugins.contains(name) },
            set: { zsh.setPlugin(name, enabled: $0); changed = true })
    }
}
