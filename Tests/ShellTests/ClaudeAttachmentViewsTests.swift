import AppKit
import SwiftUI
import XCTest
@testable import Shell

@MainActor
final class ClaudeAttachmentViewsTests: XCTestCase {
    private let p = ClaudeViewFixtures.palette

    /// An image, a text file, a folder and a file with an unknown extension.
    private func attachments() throws -> [ClaudeAttachment] {
        let dir = try makeTemporaryDirectory()
        let png = dir.appendingPathComponent("screenshot.png")
        try ClaudeViewFixtures.writePNG(to: png, width: 120, height: 40)
        let tall = dir.appendingPathComponent("tall.png")
        try ClaudeViewFixtures.writePNG(to: tall, width: 10, height: 200)
        let text = dir.appendingPathComponent("a very long file name that will need truncating in the chip.txt")
        try Data(repeating: 65, count: 2048).write(to: text)
        let folder = dir.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let unknown = dir.appendingPathComponent("blob.zzzunknown")
        try Data([1, 2, 3]).write(to: unknown)
        return try [png, tall, text, folder, unknown].map { try XCTUnwrap(ClaudeAttachment.load($0)) }
    }

    func testAttachmentsLoadAsImagesOrFiles() throws {
        let all = try attachments()
        XCTAssertEqual(all.map(\.isImage), [true, true, false, false, false])
        XCTAssertNotNil(all[0].thumbnail)
        XCTAssertNil(all[2].thumbnail)
    }

    func testRemovableStripRendersEveryKindAndRemoves() throws {
        let all = try attachments()
        var removed: [String] = []
        let w = claudeWindow(ClaudeAttachmentStrip(attachments: all, palette: p) { removed.append($0.name) }, width: 1200)
        XCTAssertGreaterThan(w.size.height, 60)
        // Each chip has a remove button.
        XCTAssertEqual(w.controls().count, all.count)
        w.press(0)
        XCTAssertEqual(removed.count, 1)
        XCTAssertTrue(all.map(\.name).contains(removed[0]))
    }

    func testSentStripHasNoRemoveButtons() throws {
        let all = try attachments()
        let w = claudeWindow(ClaudeAttachmentStrip(attachments: all, palette: p), width: 1200)
        XCTAssertTrue(w.controls().isEmpty)
    }

    func testFileChipLoadsAQuickLookPreview() throws {
        let all = try attachments()
        let w = claudeWindow(ClaudeAttachmentChip(attachment: all[2], palette: p), width: 300)
        // The preview arrives asynchronously; give the task a moment.
        w.layout(settle: 0.3)
        XCTAssertGreaterThan(w.host.fittingSize.width, 100)
        w.hover(x: 20, y: 20)
        w.hover(x: 290, y: 5)
    }

    func testImageWithoutBytesStillShowsItsThumbnail() throws {
        let image = try attachments()[0].withoutImageData()
        XCTAssertTrue(image.isImage)
        render(ClaudeAttachmentChip(attachment: image, palette: p, onRemove: {}), size: CGSize(width: 200, height: 80))
        var zero = image
        zero.thumbnail = NSImage(size: NSSize(width: 10, height: 0))
        render(ClaudeAttachmentChip(attachment: zero, palette: p), size: CGSize(width: 200, height: 80))
    }
}
