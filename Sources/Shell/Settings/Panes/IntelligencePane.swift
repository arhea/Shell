import AppKit
import SwiftUI

/// Settings › Apple Intelligence: optional features backed by the on-device
/// model. Each is off by default and hidden behind availability.
struct IntelligenceSettingsPane: View {
    @State private var status = Intelligence.status

    var body: some View {
        let available = status == .available
        Form {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: available ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(available ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(status.message)
                        if status == .notEnabled {
                            Button("Open Apple Intelligence Settings…") { Self.openSystemSettings() }
                        }
                    }
                }
                Text("Everything runs on this Mac. Nothing you type or see in Shell is sent to Apple or anyone else, and suggestions never run by themselves.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Features") {
                ForEach(IntelligenceFeature.allCases) { feature in
                    Toggle(isOn: setting(feature.keyPath)) {
                        Text(feature.title)
                        Text(feature.detail)
                    }
                    .disabled(!available)
                }
            }
        }
        .formStyle(.grouped)
        // Apple Intelligence can be turned on, or finish downloading, while this is open.
        .task {
            while !Task.isCancelled {
                status = Intelligence.status
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    static func openSystemSettings() {
        let urls = ["x-apple.systempreferences:com.apple.Siri-Settings.extension", "x-apple.systempreferences:"]
        for s in urls {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }
}
