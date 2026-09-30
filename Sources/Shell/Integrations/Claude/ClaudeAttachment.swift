import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// A file or image attached to a message in the native Claude view.
///
/// Images are sent inline as base64 image blocks. Other files (and folders)
/// are sent as `@path` references that Claude Code reads with its own tools.
struct ClaudeAttachment: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Encoded bytes ready for the API (PNG, JPEG, GIF or WebP).
        case image(data: Data, mediaType: String)
        case file
    }

    let id = UUID()
    var name: String
    var kind: Kind
    /// The file on disk: the original, or a temporary copy for pasted images
    /// (so Quick Look and "Reveal in Finder" work).
    var url: URL
    /// A small preview for images (files get theirs from Quick Look).
    var thumbnail: NSImage?

    var isImage: Bool { if case .image = kind { true } else { false } }

    /// This attachment after sending: the image bytes aren't needed any more.
    func withoutImageData() -> ClaudeAttachment {
        guard case .image(_, let mediaType) = kind else { return self }
        var copy = self
        copy.kind = .image(data: Data(), mediaType: mediaType)
        return copy
    }

    var byteCount: Int64? {
        if case .image(let data, _) = kind, !data.isEmpty { return Int64(data.count) }
        return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }

    // MARK: Loading

    /// Media types the Messages API accepts inline.
    static let inlineImageTypes: [UTType: String] = [.png: "image/png", .jpeg: "image/jpeg", .gif: "image/gif", .webP: "image/webp"]
    /// Stay under the API's 5 MB per-image limit and its useful resolution.
    static let maxImageBytes = 3_750_000
    static let maxImageEdge: CGFloat = 1568

    /// A file from disk: an image (inlined) or anything else (referenced).
    static func load(_ url: URL) -> ClaudeAttachment? {
        let url = url.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        let name = url.lastPathComponent
        if !isDir.boolValue, let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
           let data = try? Data(contentsOf: url), let image = encodeForAPI(data, type: type) {
            return ClaudeAttachment(name: name, kind: .image(data: image.data, mediaType: image.mediaType), url: url,
                                    thumbnail: thumbnail(image.data))
        }
        return ClaudeAttachment(name: name, kind: .file, url: url)
    }

    /// Image bytes with no file behind them (a pasted screenshot).
    static func pastedImage(_ data: Data, type: UTType, index: Int) -> ClaudeAttachment? {
        guard let image = encodeForAPI(data, type: type) else { return nil }
        let ext = UTType(mimeType: image.mediaType)?.preferredFilenameExtension ?? "png"
        let name = "Pasted image\(index > 1 ? " \(index)" : "").\(ext)"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ShellAttachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try? image.data.write(to: url)
        return ClaudeAttachment(name: name, kind: .image(data: image.data, mediaType: image.mediaType), url: url,
                                thumbnail: thumbnail(image.data))
    }

    /// An image from a resumed transcript. It was already sent, so only a
    /// thumbnail is kept in memory; the file (for Quick Look) is written once
    /// per distinct image, not again on every resume. Safe off the main thread.
    static func historyImage(_ data: Data, type: UTType) -> ClaudeAttachment? {
        let ext = type.preferredFilenameExtension ?? "png"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ShellAttachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
        let url = dir.appendingPathComponent("history-\(digest).\(ext)")
        if !FileManager.default.fileExists(atPath: url.path) { try? data.write(to: url) }
        let mediaType = type.preferredMIMEType ?? "image/png"
        return ClaudeAttachment(name: "Image", kind: .image(data: Data(), mediaType: mediaType), url: url, thumbnail: thumbnail(data))
    }

    /// Clears pasted images from earlier runs (the folder is only a scratch area).
    static func removeStaleFiles(olderThan age: TimeInterval = 7 * 86400) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ShellAttachments", isDirectory: true)
        let cutoff = Date().addingTimeInterval(-age)
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? [] {
            if let date = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate, date < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// A ~160px preview, so the composer and transcript don't decode full images.
    static func thumbnail(_ data: Data, maxPixels: Int = 160) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
    }

    /// Files, or else image data, on a pasteboard (paste or drop). Empty when
    /// it only holds text.
    static func from(pasteboard pb: NSPasteboard, pastedSoFar: Int = 0) -> [ClaudeAttachment] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.compactMap(load)
        }
        // Spreadsheets and some editors put a picture of copied text next to the
        // text itself; paste the text then.
        guard pb.string(forType: .string) == nil else { return [] }
        for (pbType, utType) in [(NSPasteboard.PasteboardType.png, UTType.png), (.tiff, .tiff),
                                 (NSPasteboard.PasteboardType("public.jpeg"), .jpeg)] {
            if let data = pb.data(forType: pbType), let a = pastedImage(data, type: utType, index: pastedSoFar + 1) { return [a] }
        }
        return []
    }

    /// Attachments from a SwiftUI drop: file URLs, else image data (e.g. an
    /// image dragged out of a browser). Calls `completion` on the main thread
    /// once per attachment.
    static func load(providers: [NSItemProvider], completion: @escaping @MainActor (ClaudeAttachment) -> Void) {
        for (i, provider) in providers.enumerated() {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { if let a = load(url) { completion(a) } } }
                }
            } else if let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .image) }) {
                _ = provider.loadDataRepresentation(for: type) { data, _ in
                    guard let data else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { if let a = pastedImage(data, type: type, index: i + 1) { completion(a) } }
                    }
                }
            }
        }
    }

    /// Re-encodes when the type isn't accepted inline or the image is too large:
    /// scales the long edge to `maxImageEdge`, PNG when it has transparency, else JPEG.
    static func encodeForAPI(_ data: Data, type: UTType) -> (data: Data, mediaType: String)? {
        if let mediaType = inlineImageTypes.first(where: { type.conforms(to: $0.key) })?.value, data.count <= maxImageBytes,
           let rep = NSBitmapImageRep(data: data), CGFloat(max(rep.pixelsWide, rep.pixelsHigh)) <= maxImageEdge * 1.3 {
            return (data, mediaType)
        }
        guard let source = NSBitmapImageRep(data: data), let cg = source.cgImage else { return nil }
        let long = CGFloat(max(cg.width, cg.height))
        let scale = min(1, maxImageEdge / long)
        let width = max(1, Int(CGFloat(cg.width) * scale)), height = max(1, Int(CGFloat(cg.height) * scale))
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(cg.alphaInfo)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: scaled)
        if hasAlpha, let png = rep.representation(using: .png, properties: [:]), png.count <= maxImageBytes {
            return (png, "image/png")
        }
        for quality in [0.85, 0.7, 0.5] {
            if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]), jpeg.count <= maxImageBytes {
                return (jpeg, "image/jpeg")
            }
        }
        return nil
    }

    // MARK: Sending

    /// The user message content: image blocks, then the text with `@path`
    /// references for the other files. A plain string when nothing is attached.
    static func content(text: String, attachments: [ClaudeAttachment], directory: String) -> Any {
        guard !attachments.isEmpty else { return text }
        var blocks: [[String: Any]] = []
        for a in attachments {
            if case .image(let data, let mediaType) = a.kind {
                blocks.append(["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": data.base64EncodedString()]])
            }
        }
        let files = attachments.filter { !$0.isImage }.map { reference(for: $0.url.path, directory: directory) }
        var body = text
        if !files.isEmpty {
            body += (body.isEmpty ? "" : "\n\n") + "Attached: " + files.joined(separator: " ")
        }
        if !body.isEmpty { blocks.append(["type": "text", "text": body]) }
        return blocks
    }

    /// `@relative/path` inside the session's directory, else `@/absolute/path`;
    /// quoted when it has spaces.
    static func reference(for path: String, directory: String) -> String {
        let dir = directory.hasSuffix("/") ? directory : directory + "/"
        let shown = path.hasPrefix(dir) ? String(path.dropFirst(dir.count)) : path
        return shown.contains(" ") ? "@\"\(shown)\"" : "@" + shown
    }
}
