import AppKit
import SwiftUI

/// Settings › General › Software Update.
struct SoftwareUpdateSection: View {
    /// App-wide model (observed through property access; not state this view owns).
    private let updater = SoftwareUpdater.shared
    /// A fixed state for unit tests; nil reads the live updater.
    private let injected: Status?

    /// What the section shows.
    struct Status {
        var phase: SoftwareUpdater.Phase
        var currentVersion: String
        var installBlocker: String?
        var downloadFraction: Double?
        var downloadError: String?
        var lastCheck: Date?
    }

    init(status: Status? = nil) { injected = status }

    private var current: Status {
        injected ?? Status(phase: updater.phase, currentVersion: updater.currentVersion, installBlocker: updater.installBlocker,
                           downloadFraction: updater.downloadFraction, downloadError: updater.downloadError, lastCheck: updater.lastCheck)
    }

    var body: some View {
        let s = SettingsStore.shared.settings
        let u = current
        let blocker = u.installBlocker
        Section("Software Update") {
            Toggle("Check for updates automatically", isOn: setting(\.checkForUpdates))
            Toggle("Download updates in the background and install them when Shell quits", isOn: setting(\.installUpdatesAutomatically))
                .disabled(!s.checkForUpdates || blocker != nil)
            LabeledContent("Shell \(u.currentVersion)") { status(u) }
            if case .downloading = u.phase, let fraction = u.downloadFraction, fraction < 1 {
                ProgressView(value: fraction)
            }
            if let blocker {
                Text(blocker).font(.caption).foregroundStyle(.secondary)
            } else if case .available = u.phase, let error = u.downloadError {
                Text("The download failed: \(error)").font(.caption).foregroundStyle(.red)
            }
            Text("Shell asks GitHub for the latest release of \(UpdateInstaller.repository) every six hours. Updates are installed only when they're signed by Shell's developer and notarized by Apple. No identifiers or usage data are sent.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func status(_ u: Status) -> some View {
        HStack(spacing: 8) {
            switch u.phase {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            case .downloading(let r):
                ProgressView().controlSize(.small)
                if let f = u.downloadFraction, f >= 1 {
                    Text("Verifying \(r.version)…").foregroundStyle(.secondary)
                } else {
                    Text("Downloading \(r.version)…").foregroundStyle(.secondary)
                }
            case .available(let r):
                Text("\(r.version) is available")
                Button("Release Notes") { NSWorkspace.shared.open(r.notesURL) }
                if u.installBlocker == nil {
                    Button(u.downloadError == nil ? "Install and Restart" : "Try Again") { updater.installAndRelaunch() }
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
                if let last = u.lastCheck {
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
