import AppKit
import SwiftUI

/// The "About Shell" window, laid out like macOS's own About This Mac: icon,
/// name, version, a GitHub button, and quiet acknowledgements at the bottom.
/// Replaces the standard About panel, whose credits render in a bordered,
/// scrolling text box.
@MainActor
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: AboutWindowController?

    static let repositoryURL = URL(string: "https://github.com/arhea/Shell")!

    static func show(ghosttyVersion: String) {
        let controller = shared ?? AboutWindowController(ghosttyVersion: ghosttyVersion)
        shared = controller
        if controller.window?.isVisible == false { controller.window?.center() }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(ghosttyVersion: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "About Shell"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: window)
        window.delegate = self
        let host = NSHostingView(rootView: AboutView(ghosttyVersion: ghosttyVersion))
        window.contentView = host
        window.setContentSize(host.fittingSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        AboutWindowController.shared = nil
    }
}

private struct AboutView: View {
    let ghosttyVersion: String

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    /// "1.3.2-HEAD+d67ab32" → "1.3.2 (d67ab32)", so it fits on one line.
    private var engineVersion: String {
        let release = ghosttyVersion.prefix { $0 != "-" && $0 != "+" }
        guard let plus = ghosttyVersion.lastIndex(of: "+") else { return String(release) }
        return "\(release) (\(ghosttyVersion[ghosttyVersion.index(after: plus)...]))"
    }

    private var year: String {
        String(Calendar.current.component(.year, from: Date()))
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .padding(.top, 36)

            Text("Shell")
                .font(.system(size: 28, weight: .bold))
                .padding(.top, 12)
            Text(version)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 2)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("Terminal engine").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text("libghostty \(engineVersion)").textSelection(.enabled)
                }
                GridRow {
                    Text("License").foregroundStyle(.secondary)
                    Text("MIT")
                }
            }
            .font(.system(size: 12))
            .padding(.top, 20)

            Link(destination: AboutWindowController.repositoryURL) {
                Text("View on GitHub").frame(minWidth: 120)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.top, 20)

            VStack(spacing: 2) {
                Text(acknowledgements)
                Text("© \(year) Alex Rhea")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .tint(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 24)
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 28)
        .frame(width: 320)
    }

    /// Credits for the open-source projects whose code ships in the app.
    private var acknowledgements: AttributedString {
        let markdown = "Built with [Ghostty](https://github.com/ghostty-org/ghostty) (MIT), "
            + "[Kitty](https://github.com/kovidgoyal/kitty) shell integration (GPLv3) and "
            + "[iTerm2 Color Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes) (MIT)."
        return (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
    }
}
