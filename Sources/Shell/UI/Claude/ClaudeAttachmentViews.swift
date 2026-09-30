import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A row of attachment previews: above the composer (removable) or on a sent message.
struct ClaudeAttachmentStrip: View {
    let attachments: [ClaudeAttachment]
    let palette: ClaudePalette
    var onRemove: ((ClaudeAttachment) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(attachments) { a in
                    ClaudeAttachmentChip(attachment: a, palette: palette, onRemove: onRemove.map { remove in { remove(a) } })
                }
            }
            .padding(.top, onRemove == nil ? 0 : 6) // room for the remove buttons
            .padding(.trailing, 6)
        }
    }
}

struct ClaudeAttachmentChip: View {
    let attachment: ClaudeAttachment
    let palette: ClaudePalette
    var onRemove: (() -> Void)?
    @State private var preview: NSImage?
    @State private var hovering = false

    private let height: CGFloat = 64

    var body: some View {
        content
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.border))
            .overlay(alignment: .topTrailing) {
                if let onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, Color.black.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                    .opacity(hovering ? 1 : 0.85)
                    .help("Remove")
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { QuickLookController.shared.toggle([attachment.url]) }
            .contextMenu {
                Button("Quick Look") { QuickLookController.shared.toggle([attachment.url]) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([attachment.url]) }
                if let onRemove {
                    Divider()
                    Button("Remove", action: onRemove)
                }
            }
            .help(helpText)
    }

    @ViewBuilder private var content: some View {
        if let thumb = attachment.thumbnail {
            Image(nsImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: min(max(height * aspect(thumb), height * 0.75), height * 2), height: height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            HStack(spacing: 8) {
                Image(nsImage: preview ?? NSWorkspace.shared.icon(forFile: attachment.url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.foreground)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(palette.dim)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 190, height: height, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.raised))
            .task(id: attachment.id) {
                preview = await QuickLookThumbnail.thumbnail(for: attachment.url.path, size: CGSize(width: 72, height: 72))
            }
        }
    }

    private func aspect(_ image: NSImage) -> CGFloat {
        image.size.height > 0 ? image.size.width / image.size.height : 1
    }

    private var detail: String {
        let type = UTType(filenameExtension: attachment.url.pathExtension)?.localizedDescription
            ?? (attachment.url.hasDirectoryPath ? "Folder" : "File")
        guard let bytes = attachment.byteCount, !attachment.url.hasDirectoryPath else { return type }
        return type + " · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var helpText: String {
        var parts = [attachment.url.path]
        if attachment.isImage, let bytes = attachment.byteCount {
            parts.append("Sent as an image (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))")
        } else {
            parts.append("Sent as a file reference Claude reads")
        }
        return parts.joined(separator: "\n")
    }
}

/// Opens a file picker and returns the chosen files as attachments.
@MainActor
enum ClaudeAttachmentPicker {
    static func choose(in window: NSWindow?, directory: String, completion: @escaping ([ClaudeAttachment]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = "Attach"
        panel.message = "Images are sent to Claude directly; other files are referenced by path."
        panel.directoryURL = URL(fileURLWithPath: directory)
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            completion(panel.urls.compactMap(ClaudeAttachment.load))
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }
}
