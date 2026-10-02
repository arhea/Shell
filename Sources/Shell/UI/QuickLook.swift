import AppKit
import Quartz
import QuickLookThumbnailing
import SwiftUI

/// The system Quick Look panel for files Shell shows (file explorer, completions).
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private var urls: [URL] = []

    /// Shows `urls` in the Quick Look panel, or closes it if it's already
    /// showing them (Space toggles, as in Finder).
    func toggle(_ urls: [URL]) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, urls == self.urls {
            panel.orderOut(nil)
            return
        }
        self.urls = urls
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }
}

/// A Quick Look thumbnail (images, PDFs, video, documents) rendered off the main thread.
struct QuickLookThumbnail: View {
    let path: String
    var maxSize = CGSize(width: 220, height: 150)

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: maxSize.width, maxHeight: maxSize.height, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .task(id: path) { image = await Self.thumbnail(for: path, size: maxSize) }
    }

    static func thumbnail(for path: String, size: CGSize) async -> NSImage? {
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: size, scale: scale,
                                                   representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
