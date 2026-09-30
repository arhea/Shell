import AppKit
import SwiftUI

/// Settings › Go: toolchain info, cache sizes and clearing, and the size warning.
struct GoSettingsPane: View {
    /// App-wide model (observed through property access; not state this view owns).
    private let go = GoService.shared
    /// App-wide model (observed through property access; not state this view owns).
    private let store = SettingsStore.shared
    @State private var confirm: GoService.Cache?

    var body: some View {
        Form {
            Section {
                if go.isInstalled {
                    LabeledContent("Version", value: go.version ?? "…")
                    if let root = go.env["GOROOT"] { LabeledContent("GOROOT", value: ClaudeToolFormat.shortPath(root)) }
                    if let path = go.env["GOPATH"] { LabeledContent("GOPATH", value: ClaudeToolFormat.shortPath(path)) }
                } else {
                    Text("Go isn't installed. Install it with `brew install go`.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Toolchain")
            }

            if go.isInstalled {
                Section {
                    if go.isBuildCacheOverLimit {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Go's build cache is \(WorktreeService.formatBytes(go.buildCacheBytes)) — over your \(store.settings.goCacheWarningGB) GB limit on its own.")
                                    .font(.system(size: 12.5, weight: .semibold))
                                Text("It's safe to clear: the next builds and tests recompile, and nothing needs downloading.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Clear Build Cache") { Task { await go.clear(.build) } }
                                .disabled(go.busy.contains(.build))
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.red.opacity(0.1)))
                    } else if go.isOverLimit {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Go's caches are \(WorktreeService.formatBytes(go.total)) — over your \(store.settings.goCacheWarningGB) GB limit.")
                                    .font(.system(size: 12.5, weight: .semibold))
                                Text("Clearing the build cache is usually enough; the module cache is only worth clearing if old dependency versions have piled up.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.12)))
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(go.lastMeasured == nil ? "Measuring…" : WorktreeService.formatBytes(go.total))
                            .font(.system(size: 24, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(go.isOverLimit ? .orange : .primary)
                        Text("of \(store.settings.goCacheWarningGB) GB limit").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if go.isMeasuring { ProgressView().controlSize(.small) }
                        Button("Recalculate") { Task { await go.measure() } }.disabled(go.isMeasuring)
                    }
                    if go.lastMeasured != nil {
                        ProgressView(value: min(1, Double(go.total) / Double(go.limitBytes)))
                            .tint(go.isOverLimit ? .orange : .accentColor)
                    }
                    ForEach(go.caches) { cache in row(cache) }
                    if let msg = go.message {
                        Text(msg).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Caches")
                }

                Section {
                    Toggle("Warn when Go's caches, or the build cache alone, pass a size", isOn: setting(\.goCacheWarning))
                    Stepper(value: setting(\.goCacheWarningGB), in: 5...1000, step: 5) {
                        HStack {
                            Text("Limit")
                            Text("\(store.settings.goCacheWarningGB) GB").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!store.settings.goCacheWarning)
                    Toggle("Clear the build cache automatically when over the limit", isOn: setting(\.goAutoCleanBuildCache))
                        .disabled(!store.settings.goCacheWarning)
                    Text("Shell checks after launch and every 6 hours while it's open, and notifies you at most once a day. The limit applies twice: to the build cache on its own, and to the build, module, gopls, golangci-lint and goimports caches together.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("Size warning")
                }
            }
        }
        .formStyle(.grouped)
        .task { if go.lastMeasured == nil { await go.refresh() } }
        .confirmationDialog("Clear \(confirm?.title ?? "")?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { c in
            Button("Clear \(c.bytes.map(WorktreeService.formatBytes) ?? "")", role: .destructive) { Task { await go.clear(c.id) } }
        } message: { c in
            Text([command(for: c), c.caution].compactMap { $0 }.joined(separator: "\n\n"))
        }
    }

    private func command(for c: GoService.Cache) -> String {
        switch c.id {
        case .build: "Runs `go clean -cache`."
        case .modules: "Runs `go clean -modcache`."
        case .fuzz: "Runs `go clean -fuzzcache`."
        case .golangci: "Runs `golangci-lint cache clean`."
        case .gopls, .goimports: "Removes the contents of \(ClaudeToolFormat.shortPath(c.path))."
        }
    }

    private func row(_ c: GoService.Cache) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(.system(size: 12.5, weight: .medium))
                Text(c.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(ClaudeToolFormat.shortPath(c.path)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                let size = Text(c.bytes.map(WorktreeService.formatBytes) ?? "…").font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                    .foregroundColor(c.id == .build && go.isBuildCacheOverLimit ? .red : .primary)
                let note = Text(c.id == .fuzz ? " (in build)" : "").font(.caption).foregroundColor(.secondary)
                Text("\(size)\(note)")
                HStack(spacing: 4) {
                    if go.busy.contains(c.id) { ProgressView().controlSize(.mini) }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: c.path)]) } label: { Image(systemName: "folder") }
                        .help("Reveal in Finder")
                        .disabled(!FileManager.default.fileExists(atPath: c.path))
                    if c.id == .build {
                        Button("Test Results") { Task { await go.clearTestResults() } }
                            .help("go clean -testcache — only forget cached test results")
                    }
                    Button("Clear") { confirm = c }
                        .disabled(go.busy.contains(c.id) || (c.bytes ?? 0) < 16_384)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}
