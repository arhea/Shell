import AppKit
import SwiftUI

/// Tells the user, once, that Apple Intelligence features exist: only when
/// the model is ready on this Mac and they haven't turned any feature on.
@MainActor
enum IntelligenceAnnouncement {
    static func showIfNeeded(in controller: TerminalWindowController) {
        let settings = SettingsStore.shared.settings
        guard !AppEnvironment.isRunningTests, !settings.intelligenceAnnouncementShown,
              !Intelligence.anyFeatureOn, Intelligence.isAvailable else { return }
        // Once shown it never comes back, whatever the user does with it.
        SettingsStore.shared.settings.intelligenceAnnouncementShown = true
        controller.showBanner(IntelligenceBanner(
            onChoose: { [weak controller] in
                controller?.hideBanner()
                SettingsWindowController.shared.show(pane: .intelligence)
            },
            onDismiss: { [weak controller] in controller?.hideBanner() }))
    }
}

struct IntelligenceBanner: View {
    let onChoose: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        let palette = ChromePalette.current
        HStack(spacing: 10) {
            Image(systemName: NSImage(systemSymbolName: "apple.intelligence", accessibilityDescription: nil) != nil ? "apple.intelligence" : "sparkles")
                .foregroundStyle(palette.accent)
            Text("Shell can use Apple Intelligence on this Mac to suggest branch names, tab names and fixes for failed commands. Each feature is off until you turn it on.")
                .font(.system(size: 12))
                .foregroundStyle(palette.foreground.opacity(0.85))
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Choose Features…", action: onChoose)
            Button("Not Now", action: onDismiss)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.border).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Apple Intelligence features are available")
    }
}
