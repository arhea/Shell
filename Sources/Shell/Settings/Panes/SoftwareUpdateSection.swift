import AppKit
import SwiftUI

/// Settings › General › Software Update.
struct SoftwareUpdateSection: View {
    /// App-wide model (observed through property access; not state this view owns).
    private let updater = SoftwareUpdater.shared

    var body: some View {
        let s = SettingsStore.shared.settings
        let blocker = updater.installBlocker
        Section("Software Update") {
            Toggle("Check for updates automatically", isOn: setting(\.checkForUpdates))
            Toggle("Download updates in the background and install them when Shell quits", isOn: setting(\.installUpdatesAutomatically))
                .disabled(!s.checkForUpdates || blocker != nil)
            LabeledContent("Shell \(updater.currentVersion)") { status }
            if case .downloading = updater.phase, let fraction = updater.downloadFraction, fraction < 1 {
                ProgressView(value: fraction)
            }
            if let blocker {
                Text(blocker).font(.caption).foregroundStyle(.secondary)
            } else if case .available = updater.phase, let error = updater.downloadError {
                Text("The download failed: \(error)").font(.caption).foregroundStyle(.red)
            }
            Text("Shell asks GitHub for the latest release of \(UpdateInstaller.repository) every six hours. Updates are installed only when they're signed by Shell's developer and notarized by Apple. No identifiers or usage data are sent.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 8) {
            switch updater.phase {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            case .downloading(let r):
                ProgressView().controlSize(.small)
                if let f = updater.downloadFraction, f >= 1 {
                    Text("Verifying \(r.version)…").foregroundStyle(.secondary)
                } else {
                    Text("Downloading \(r.version)…").foregroundStyle(.secondary)
                }
            case .available(let r):
                Text("\(r.version) is available")
                Button("Release Notes") { NSWorkspace.shared.open(r.notesURL) }
                if updater.installBlocker == nil {
                    Button(updater.downloadError == nil ? "Install and Restart" : "Try Again") { updater.installAndRelaunch() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Download") { NSWorkspace.shared.open(r.notesURL) }
                }
            case .ready(let r):
                Text("\(r.version) installs when you quit")
                Button("Release Notes") { NSWorkspace.shared.open(r.notesURL) }
                Button("Restart Now") { updater.installAndRelaunch() }.buttonStyle(.borderedProminent)
            case .failed(let message):
                Text(message).foregroundStyle(.secondary).lineLimit(2).help(message)
                checkNow
            case .idle, .upToDate:
                if let last = updater.lastCheck {
                    Text("Up to date · checked \(last.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary)
                }
                checkNow
            }
        }
    }

    private var checkNow: some View {
        Button("Check Now") { Task { await updater.check(userInitiated: true) } }
    }
}
