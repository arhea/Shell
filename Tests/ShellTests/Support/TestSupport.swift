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

/// A fresh, empty temporary directory removed when the test finishes.
extension XCTestCase {
    func makeTemporaryDirectory(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellTests-\(UUID().uuidString)", isDirectory: true)
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
