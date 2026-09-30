import AppKit
import Observation
import SwiftUI

/// State for the completion / history-search menu shown next to the editor.
@MainActor
@Observable
final class CompletionModel {
    enum Mode { case completions, history }

    var mode: Mode = .completions
    var items: [CompletionItem] = []
    var selectedIndex = 0
    /// True once the user has moved the selection (so Enter accepts instead of running).
    var userNavigated = false
    var isVisible = false
    var query = ""
    var workingDirectory: String?
    var showPreview = true

    var selected: CompletionItem? { items.indices.contains(selectedIndex) ? items[selectedIndex] : nil }

    func show(_ items: [CompletionItem], mode: Mode) {
        self.items = items
        self.mode = mode
        selectedIndex = 0
        userNavigated = false
        isVisible = !items.isEmpty
    }

    func hide() {
        isVisible = false
        userNavigated = false
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + items.count) % items.count
        userNavigated = true
    }
}

struct EditorPalette {
    var background: Color
    var surface: Color
    var foreground: Color
    var dim: Color
    var accent: Color
    var border: Color
    var selection: Color

    @MainActor
    static var current: EditorPalette {
        let t = ConfigController.shared.theme
        let bg = t.background
        let raise = bg.mixed(with: t.foreground, t.isDark ? 0.07 : 0.04)
        return EditorPalette(
            background: Color(nsColor: bg.nsColor),
            surface: Color(nsColor: raise.nsColor),
            foreground: Color(nsColor: t.foreground.nsColor),
            dim: Color(nsColor: bg.mixed(with: t.foreground, 0.55).nsColor),
            accent: Color(nsColor: t.accent.nsColor),
            border: Color(nsColor: bg.mixed(with: t.foreground, 0.16).nsColor),
            selection: Color(nsColor: t.accent.nsColor).opacity(t.isDark ? 0.28 : 0.18))
    }
}

struct CompletionPopupView: View {
    @Bindable var model: CompletionModel
    var onAccept: (CompletionItem) -> Void
    var fontName: String?
    var fontSize: CGFloat

    private var palette: EditorPalette { .current }
    private var font: Font {
        if let fontName { return .custom(fontName, size: fontSize) }
        return .system(size: fontSize, design: .monospaced)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            list
                .frame(width: 380)
            if model.showPreview, model.mode == .completions, let item = model.selected {
                Divider().overlay(palette.border)
                CompletionPreview(item: item, cwd: model.workingDirectory, palette: palette, font: font)
                    .frame(width: 300)
            }
        }
        .frame(maxHeight: 260)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
    }

    private var list: some View {
        VStack(spacing: 0) {
            if model.mode == .history {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text(model.query.isEmpty ? "Search history…" : model.query)
                        .lineLimit(1)
                    Spacer()
                    Text("⏎ run · ⇥ edit").foregroundStyle(palette.dim)
                }
                .font(.system(size: 11))
                .foregroundStyle(palette.foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Divider().overlay(palette.border)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(model.items) { item in
                            row(item)
                                .id(item.id)
                                .onTapGesture(count: 2) { onAccept(item) }
                                .onTapGesture { model.selectedIndex = item.id; model.userNavigated = true }
                        }
                    }
                    .padding(4)
                }
                .onChange(of: model.selectedIndex) { _, new in
                    proxy.scrollTo(new, anchor: nil)
                }
            }
        }
    }

    private func row(_ item: CompletionItem) -> some View {
        let selected = item.id == model.selectedIndex
        return HStack(spacing: 8) {
            Image(systemName: item.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(iconColor(item))
                .frame(width: 16)
            Text(item.display)
                .font(font)
                .foregroundStyle(palette.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if !item.description.isEmpty {
                Text(item.description)
                    .font(.system(size: max(fontSize - 2, 10)))
                    .foregroundStyle(palette.dim)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 190, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? palette.selection : .clear))
        .contentShape(Rectangle())
    }

    private func iconColor(_ item: CompletionItem) -> Color {
        let t = ConfigController.shared.theme
        let idx: Int
        switch item.kind {
        case .command: idx = 2
        case .directory: idx = 4
        case .file: idx = 7
        case .option: idx = 6
        case .branch: idx = 5
        case .variable: idx = 5
        case .history: idx = 3
        default: idx = 8
        }
        return Color(nsColor: t.palette[idx].nsColor)
    }
}

/// Details for the highlighted completion: directory listings, file heads,
/// command paths, and zsh-provided descriptions.
struct CompletionPreview: View {
    let item: CompletionItem
    let cwd: String?
    let palette: EditorPalette
    let font: Font

    @State private var content: PreviewContent?

    struct PreviewContent: Equatable {
        var title: String
        var subtitle: String?
        var lines: [String]
        /// A non-text file to show as a Quick Look thumbnail.
        var thumbnailPath: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let c = content {
                Text(c.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)
                if let s = c.subtitle {
                    Text(s)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.dim)
                        .lineLimit(3)
                }
                if let path = c.thumbnailPath {
                    QuickLookThumbnail(path: path)
                }
                if !c.lines.isEmpty {
                    Divider().overlay(palette.border)
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(c.lines.enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .font(font)
                                .foregroundStyle(palette.foreground.opacity(0.85))
                                .lineLimit(1)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: item.insertion) { content = await Self.load(item, cwd: cwd) }
    }

    static func load(_ item: CompletionItem, cwd: String?) async -> PreviewContent {
        let desc = item.description.isEmpty ? nil : item.description
        switch item.kind {
        case .directory, .file:
            let raw = (item.display as NSString).expandingTildeInPath
            var path = raw.hasPrefix("/") ? raw : ((cwd ?? NSHomeDirectory()) as NSString).appendingPathComponent(raw)
            if !FileManager.default.fileExists(atPath: path) {
                let unq = (item.insertion.replacingOccurrences(of: "\\", with: "") as NSString).expandingTildeInPath
                path = unq.hasPrefix("/") ? unq : ((cwd ?? NSHomeDirectory()) as NSString).appendingPathComponent(unq)
            }
            return await Task.detached(priority: .userInitiated) { () -> PreviewContent in
                let fm = FileManager.default
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
                    return PreviewContent(title: item.display, subtitle: desc, lines: [])
                }
                if isDir.boolValue {
                    let items = (try? fm.contentsOfDirectory(atPath: path))?.filter { !$0.hasPrefix(".") }.sorted() ?? []
                    let lines = items.prefix(14).map { name -> String in
                        var d: ObjCBool = false
                        fm.fileExists(atPath: (path as NSString).appendingPathComponent(name), isDirectory: &d)
                        return d.boolValue ? "\(name)/" : name
                    }
                    let more = items.count > 14 ? ["… \(items.count - 14) more"] : []
                    return PreviewContent(title: (path as NSString).lastPathComponent + "/",
                                          subtitle: "\(items.count) item\(items.count == 1 ? "" : "s")", lines: lines + more)
                }
                let attrs = try? fm.attributesOfItem(atPath: path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                let modified = (attrs?[.modificationDate] as? Date).map {
                    RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date())
                } ?? ""
                let subtitle = "\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) · modified \(modified)"
                var lines: [String] = []
                var thumbnail: String?
                if size < 2_000_000, let h = FileHandle(forReadingAtPath: path) {
                    let data = h.readData(ofLength: 4096)
                    try? h.close()
                    if !data.contains(0), let s = String(data: data, encoding: .utf8) {
                        lines = s.components(separatedBy: "\n").prefix(14).map { String($0.prefix(80)) }
                    } else {
                        thumbnail = path
                    }
                } else {
                    thumbnail = path
                }
                return PreviewContent(title: (path as NSString).lastPathComponent, subtitle: subtitle, lines: lines,
                                      thumbnailPath: thumbnail)
            }.value
        case .command:
            let path = CommandIndex.shared.path(for: item.display)
            return PreviewContent(title: item.display, subtitle: desc ?? path ?? item.tag.replacingOccurrences(of: "-", with: " "),
                                  lines: desc != nil && path != nil ? [path!] : [])
        default:
            return PreviewContent(title: item.display, subtitle: desc ?? item.tag.replacingOccurrences(of: "-", with: " "), lines: [])
        }
    }
}
