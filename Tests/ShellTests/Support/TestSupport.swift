import AppKit
import SwiftUI
import XCTest
@testable import Shell

/// Lays out a SwiftUI view in an offscreen hosting view so its `body` (and the
/// bodies of its children) are evaluated. Returns the host so tests can inspect
/// its fitting size or subviews.
@MainActor
@discardableResult
func render<V: View>(_ view: V, size: CGSize = CGSize(width: 800, height: 900)) -> NSHostingView<V> {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    host.display()
    return host
}

/// Lays out an AppKit view at `size`, forcing layout and a draw pass.
@MainActor
func render(_ view: NSView, size: CGSize = CGSize(width: 800, height: 600)) {
    view.frame = NSRect(origin: .zero, size: size)
    view.layoutSubtreeIfNeeded()
    view.display()
}

/// Runs `body` with modified settings and restores the originals afterwards,
/// so tests never leak settings into each other.
@MainActor
func withSettings<T>(_ change: (inout AppSettings) -> Void, _ body: () throws -> T) rethrows -> T {
    let original = SettingsStore.shared.settings
    defer { SettingsStore.shared.settings = original }
    change(&SettingsStore.shared.settings)
    return try body()
}

/// Writes `script` (starting with its `#!` line) as an executable fake tool at
/// `url` and returns its path.
///
/// macOS scans every new executable the first time it runs, about 170 ms
/// each, and the suite creates hundreds of fakes. So `url` is a hard link to
/// one launcher shared by the whole test process (scanned once), and the
/// script itself sits beside it in a hidden, non-executable `.<name>.body`
/// file that the launcher hands to the interpreter on its `#!` line. A hard
/// link rather than a symlink, so code that resolves symlinks (to tell a
/// Homebrew install from an npm one, say) still sees the fake's own path. The
/// process keeps its PID through both `exec`s; `$0` inside the script is the
/// body's path, so `${0:A:h}` is still the fake's folder.
@discardableResult
func writeExecutable(_ script: String, to url: URL) throws -> String {
    let fm = FileManager.default
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try script.write(to: fakeToolBody(for: url), atomically: true, encoding: .utf8)
    try? fm.removeItem(at: url)
    try fm.linkItem(at: FakeToolLauncher.url, to: url)
    return url.path
}

/// Where `writeExecutable` keeps the script for the fake at `url`.
func fakeToolBody(for url: URL) -> URL {
    url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).body")
}

private enum FakeToolLauncher {
    /// Follows symlinks from `$0` until one has a `.body` beside it, so a
    /// symlink to a fake (say, a Homebrew-style `bin/n -> ../Cellar/n/bin/n`)
    /// runs that fake. Lives in this process's throwaway support folder, on
    /// the same volume as the fixtures so they can hard-link to it.
    static let url: URL = {
        let url = SettingsStore.supportDirectory.appendingPathComponent("fake-tool-launcher")
        let script = #"""
        #!/bin/sh
        p=$0
        while [ ! -f "${p%/*}/.${p##*/}.body" ]; do
          t=$(/usr/bin/readlink "$p") || { echo "fake tool: no script for $0" >&2; exit 127; }
          case $t in /*) p=$t ;; *) p=${p%/*}/$t ;; esac
        done
        b="${p%/*}/.${p##*/}.body"
        IFS= read -r first < "$b" || true
        case $first in
          '#!'*) exec ${first#??} "$b" "$@" ;;
          *) exec /bin/sh "$b" "$@" ;;
        esac
        """#
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            fatalError("couldn't write the fake tool launcher: \(error)")
        }
        return url
    }()
}

/// A fresh, empty temporary directory removed when the test finishes. Not
/// named `ShellTests-*`: launch cleans those up (`removeStaleTestFolders`).
extension XCTestCase {
    func makeTemporaryDirectory(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellTestFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Spins the main run loop until `condition` holds or `timeout` passes.
    @MainActor
    func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return true
    }
}
