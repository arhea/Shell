import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Shell

final class ClaudeAttachmentTests: XCTestCase {
    private func png(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 3,
                                   hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    func testSmallPNGIsSentAsIs() {
        let data = png(width: 40, height: 20)
        let out = ClaudeAttachment.encodeForAPI(data, type: .png)
        XCTAssertEqual(out?.mediaType, "image/png")
        XCTAssertEqual(out?.data, data)
    }

    func testLargeOrUnsupportedImagesAreReencoded() throws {
        let big = try XCTUnwrap(ClaudeAttachment.encodeForAPI(png(width: 4000, height: 1000), type: .png))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: big.data))
        XCTAssertEqual(max(rep.pixelsWide, rep.pixelsHigh), 1568)
        XCTAssertLessThanOrEqual(big.data.count, ClaudeAttachment.maxImageBytes)

        let tiff = NSBitmapImageRep(data: png(width: 10, height: 10))!.tiffRepresentation!
        let converted = try XCTUnwrap(ClaudeAttachment.encodeForAPI(tiff, type: .tiff))
        XCTAssertTrue(["image/png", "image/jpeg"].contains(converted.mediaType))
    }

    func testContentBlocks() throws {
        XCTAssertEqual(ClaudeAttachment.content(text: "hi", attachments: [], directory: "/r") as? String, "hi")

        let image = ClaudeAttachment(name: "a.png", kind: .image(data: Data([1, 2, 3]), mediaType: "image/png"), url: URL(fileURLWithPath: "/r/a.png"))
        let file = ClaudeAttachment(name: "b.swift", kind: .file, url: URL(fileURLWithPath: "/r/src/b.swift"))
        let other = ClaudeAttachment(name: "My Notes.md", kind: .file, url: URL(fileURLWithPath: "/tmp/My Notes.md"))
        let blocks = try XCTUnwrap(ClaudeAttachment.content(text: "look", attachments: [image, file, other], directory: "/r") as? [[String: Any]])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0]["type"] as? String, "image")
        XCTAssertEqual((blocks[0]["source"] as? [String: Any])?["data"] as? String, Data([1, 2, 3]).base64EncodedString())
        XCTAssertEqual(blocks[1]["text"] as? String, "look\n\nAttached: @src/b.swift @\"/tmp/My Notes.md\"")

        let imageOnly = try XCTUnwrap(ClaudeAttachment.content(text: "", attachments: [image], directory: "/r") as? [[String: Any]])
        XCTAssertEqual(imageOnly.map { $0["type"] as? String }, ["image"])
    }

    @MainActor
    func testPasteboardPrefersFilesThenImagesButKeepsText() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("ClaudeAttachmentTests-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }

        pb.clearContents()
        pb.setData(png(width: 8, height: 8), forType: .png)
        let pasted = ClaudeAttachment.from(pasteboard: pb)
        XCTAssertEqual(pasted.map(\.name), ["Pasted image.png"])
        XCTAssertNotNil(pasted.first?.thumbnail)

        // A spreadsheet copy: text plus a picture of it → paste the text.
        pb.clearContents()
        pb.setString("a\tb", forType: .string)
        pb.setData(png(width: 8, height: 8), forType: .png)
        XCTAssertTrue(ClaudeAttachment.from(pasteboard: pb).isEmpty)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("attach-\(UUID().uuidString).txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        pb.clearContents()
        pb.writeObjects([file as NSURL])
        let files = ClaudeAttachment.from(pasteboard: pb)
        XCTAssertEqual(files.map(\.kind), [.file])
        XCTAssertEqual(files.first?.url.path, file.standardizedFileURL.path)
    }

    /// Paste validation relies on this: an image-only clipboard must count as
    /// attachable, or a plain-text composer disables Paste (#21).
    @MainActor
    func testCanAttachMatchesWhatPasteReads() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("ClaudeAttachmentTests-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let image = try XCTUnwrap(NSBitmapImageRep(data: png(width: 8, height: 8)))

        pb.clearContents()
        XCTAssertFalse(ClaudeAttachment.canAttach(from: pb))

        for (type, data) in [(NSPasteboard.PasteboardType.png, png(width: 8, height: 8)),
                             (.tiff, try XCTUnwrap(image.tiffRepresentation)),
                             (NSPasteboard.PasteboardType(UTType.jpeg.identifier),
                              try XCTUnwrap(image.representation(using: .jpeg, properties: [:])))] {
            pb.clearContents()
            pb.setData(data, forType: type)
            XCTAssertTrue(ClaudeAttachment.canAttach(from: pb), type.rawValue)
            XCTAssertEqual(ClaudeAttachment.from(pasteboard: pb).count, 1, type.rawValue)
        }

        pb.clearContents()
        pb.setString("hello", forType: .string)
        XCTAssertFalse(ClaudeAttachment.canAttach(from: pb))

        pb.clearContents()
        pb.setString("a\tb", forType: .string)
        pb.setData(png(width: 8, height: 8), forType: .png)
        XCTAssertFalse(ClaudeAttachment.canAttach(from: pb))

        // A Finder copy carries the file name as text too; the file wins.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("attach-\(UUID().uuidString).txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        pb.clearContents()
        pb.writeObjects([file as NSURL, file.lastPathComponent as NSString])
        XCTAssertTrue(ClaudeAttachment.canAttach(from: pb))
    }

    @MainActor
    func testDropProvidersBecomeAttachments() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString).txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let fileProvider = try XCTUnwrap(NSItemProvider(contentsOf: file))
        let imageProvider = NSItemProvider(item: png(width: 8, height: 8) as NSData, typeIdentifier: UTType.png.identifier)

        let done = expectation(description: "two attachments")
        done.expectedFulfillmentCount = 2
        var got: [ClaudeAttachment] = []
        ClaudeAttachment.load(providers: [fileProvider, imageProvider]) { a in
            got.append(a)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(Set(got.map(\.isImage)), [true, false])
        XCTAssertEqual(got.first { !$0.isImage }?.url.lastPathComponent, file.lastPathComponent)
    }

    @MainActor
    func testComposerAcceptsFileDrags() {
        XCTAssertTrue(ComposerTextView().acceptableDragTypes.contains(.fileURL))
    }
}
