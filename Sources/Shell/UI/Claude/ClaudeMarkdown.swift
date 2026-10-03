import AppKit
import ImageIO
import SwiftUI

/// Colors for the native Claude view, derived from the terminal theme.
struct ClaudePalette: Equatable {
    var background: Color
    var surface: Color
    var raised: Color
    /// Below the background: the bodies of code blocks, diffs and command output.
    var sunken: Color
    var foreground: Color
    var dim: Color
    var border: Color
    var accent: Color
    var red: Color
    var green: Color
    var yellow: Color
    var blue: Color
    var magenta: Color
    var cyan: Color
    var claude: Color
    var isDark: Bool

    @MainActor private static var cache: (theme: TerminalTheme, palette: ClaudePalette)?

    /// Cached per theme, so equal themes yield an identical palette and
    /// equatable views can skip re-rendering.
    @MainActor
    static var current: ClaudePalette {
        let t = ConfigController.shared.theme
        if let cache, cache.theme == t { return cache.palette }
        let palette = make(t)
        cache = (t, palette)
        return palette
    }

    @MainActor
    private static func make(_ t: TerminalTheme) -> ClaudePalette {
        let bg = t.background, fg = t.foreground
        func c(_ rgb: RGB) -> Color { Color(nsColor: rgb.nsColor) }
        return ClaudePalette(
            background: c(bg),
            surface: c(bg.mixed(with: fg, t.isDark ? 0.05 : 0.035)),
            raised: c(bg.mixed(with: fg, t.isDark ? 0.09 : 0.07)),
            sunken: c(t.isDark ? bg.mixed(with: RGB(r: 0, g: 0, b: 0), 0.2) : bg.mixed(with: fg, 0.025)),
            foreground: c(fg),
            dim: c(bg.mixed(with: fg, t.isDark ? 0.64 : 0.6)),
            border: c(bg.mixed(with: fg, 0.14)),
            accent: c(t.accent),
            red: c(t.palette[1]), green: c(t.palette[2]), yellow: c(t.palette[3]),
            blue: c(t.palette[4]), magenta: c(t.palette[5]), cyan: c(t.palette[6]),
            // Claude's brand orange, softened for light themes.
            claude: t.isDark ? Color(red: 0.85, green: 0.47, blue: 0.34) : Color(red: 0.76, green: 0.38, blue: 0.25),
            isDark: t.isDark)
    }

    func nsColor(_ color: Color) -> NSColor { NSColor(color) }
}

// MARK: - Views

struct MarkdownView: View {
    let text: String
    let palette: ClaudePalette
    var mentions: InlineMarkdown.MentionStyle?
    var fontSize: CGFloat = 13
    /// Resolves relative file links and code spans naming files.
    var directory: String?
    /// Takes the whole width offered; false hugs the text (a message bubble).
    var fills = true

    var body: some View {
        let t = ChatTypography.current.scaled(to: fontSize)
        MarkdownBlocksView(blocks: MarkdownParseCache.shared.blocks(for: text), palette: palette, mentions: mentions, fontSize: fontSize, directory: directory,
                           typography: t, spacing: t.blockSpacing, fills: fills)
            .environment(\.openURL, OpenURLAction { url in ClaudeLinks.open(url, directory: directory) })
    }
}

struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    let palette: ClaudePalette
    let mentions: InlineMarkdown.MentionStyle?
    let fontSize: CGFloat
    let directory: String?
    var typography: ChatTypography
    var spacing: CGFloat = 8
    var fills = true

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            // Each block is equatable, so while a reply streams in only the
            // last (still growing) block re-renders, not every earlier
            // paragraph and highlighted code block.
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, palette: palette, mentions: mentions, fontSize: fontSize, directory: directory,
                                  typography: typography)
                    .equatable()
            }
        }
        .frame(maxWidth: fills ? .infinity : nil, alignment: .leading)
    }
}

private struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    let palette: ClaudePalette
    let mentions: InlineMarkdown.MentionStyle?
    let fontSize: CGFloat
    let directory: String?
    let typography: ChatTypography
    private var lineSpacing: CGFloat { typography.lineSpacing }

    var body: some View { blockView(block) }

    /// Nested blocks (quotes, alerts, list items) render through AnyView to
    /// break the recursive view type.
    private func nested(_ blocks: [MarkdownBlock], spacing: CGFloat? = nil) -> AnyView {
        let spacing = spacing ?? max(4, typography.blockSpacing * 0.6)
        return AnyView(MarkdownBlocksView(blocks: blocks, palette: palette, mentions: mentions, fontSize: fontSize, directory: directory,
                                   typography: typography, spacing: spacing))
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let s):
            inline(s)
        case .heading(let level, let s):
            VStack(alignment: .leading, spacing: 4) {
                inline(s)
                    .font(typography.font(size: fontSize + CGFloat(max(0, 5 - level)) * 1.5, weight: .semibold))
                if level <= 2 { Rectangle().fill(palette.border).frame(height: level == 1 ? 1 : 0.5) }
            }
            .padding(.top, level <= 2 ? 4 : 0)
        case .code(let lang, let code, let closed):
            CodeBlockView(language: lang, code: code, palette: palette, fontSize: typography.codeSize, lineSpacing: (lineSpacing * 0.5).rounded(),
                          font: typography.codeFont(), isComplete: closed, directory: directory)
        case .list(let items):
            VStack(alignment: .leading, spacing: max(3, lineSpacing)) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .foregroundStyle(item.marker == "☑" ? palette.green : palette.dim)
                            .frame(minWidth: 14, alignment: .trailing)
                        itemContent(item)
                    }
                    .padding(.leading, CGFloat(item.indent) * 16)
                }
            }
        case .quote(let blocks):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(palette.border).frame(width: 3)
                nested(blocks).foregroundStyle(palette.dim)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .alert(let kind, let blocks):
            AlertBlockView(kind: kind, palette: palette, fontSize: fontSize) { nested(blocks) }
        case .details(let summary, let blocks):
            DetailsBlockView(summary: InlineMarkdown.attributed(summary, palette: palette, directory: directory),
                             palette: palette, fontSize: fontSize) { nested(blocks) }
        case .table(let header, let alignments, let rows):
            TableBlockView(header: header, alignments: alignments, rows: rows, palette: palette, fontSize: fontSize, directory: directory)
        case .image(let alt, let source):
            MarkdownImageView(alt: alt, source: source, directory: directory, palette: palette, fontSize: fontSize)
        case .footnotes(let notes):
            VStack(alignment: .leading, spacing: 3) {
                Rectangle().fill(palette.border).frame(width: 80, height: 0.5).padding(.bottom, 2)
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(note.label).font(.system(size: fontSize - 3, weight: .semibold)).foregroundStyle(palette.blue)
                        inline(note.text).font(typography.font(size: fontSize - 1.5))
                    }
                }
            }
        case .rule:
            Rectangle().fill(palette.border).frame(height: 1)
        }
    }

    @ViewBuilder
    private func itemContent(_ item: MarkdownBlock.ListItem) -> some View {
        if !item.text.contains("\n") {
            inline(item.text)
        } else {
            let blocks = MarkdownBlock.parse(item.text)
            if blocks.count == 1, case .paragraph(let s) = blocks[0] {
                inline(s)
            } else {
                nested(blocks)
            }
        }
    }

    private func inline(_ s: String) -> some View {
        Text(InlineMarkdown.attributed(s, palette: palette, mentions: mentions, directory: directory, codeFont: typography.codeFont()))
            .font(typography.font())
            .tracking(typography.letterSpacing)
            .foregroundStyle(palette.foreground)
            .tint(palette.blue)
            .lineSpacing(lineSpacing)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// GitHub's `> [!NOTE]` callouts.
struct AlertBlockView<Content: View>: View {
    let kind: MarkdownBlock.AlertKind
    let palette: ClaudePalette
    let fontSize: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        let color = color
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 5) {
                Label(title, systemImage: symbol)
                    .font(.system(size: fontSize - 0.5, weight: .semibold))
                    .foregroundStyle(color)
                content()
            }
        }
        .padding(.vertical, 2)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var title: String { kind.rawValue.capitalized }

    private var symbol: String {
        switch kind {
        case .note: "info.circle"
        case .tip: "lightbulb"
        case .important: "exclamationmark.bubble"
        case .warning: "exclamationmark.triangle"
        case .caution: "exclamationmark.octagon"
        }
    }

    private var color: Color {
        switch kind {
        case .note: palette.blue
        case .tip: palette.green
        case .important: palette.magenta
        case .warning: palette.yellow
        case .caution: palette.red
        }
    }
}

/// `<details><summary>`: collapsed until clicked.
struct DetailsBlockView<Content: View>: View {
    let summary: AttributedString
    let palette: ClaudePalette
    let fontSize: CGFloat
    @ViewBuilder var content: () -> Content
    @State var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(palette.dim)
                        .frame(width: 10)
                    Text(summary).font(.system(size: fontSize, weight: .medium)).foregroundStyle(palette.foreground)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                content().padding(.leading, 15)
            }
        }
    }
}

/// A standalone `![alt](src)`: remote images load async; local paths
/// resolve against the session directory.
struct MarkdownImageView: View {
    let alt: String
    let source: String
    let directory: String?
    let palette: ClaudePalette
    let fontSize: CGFloat
    @State private var localImage: NSImage?

    var body: some View {
        Group {
            if let url = URL(string: source), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().aspectRatio(contentMode: .fit)
                    case .failure: placeholder
                    default: ProgressView().controlSize(.small).frame(height: 40)
                    }
                }
            } else if let image = localImage {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: image.size.width)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: 560, maxHeight: 360, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help(alt)
        .task(id: localPath) {
            guard let path = localPath else { return }
            localImage = await Task.detached(priority: .utility) { Self.loadThumbnail(path) }.value
        }
    }

    private var localPath: String? {
        if let scheme = URL(string: source)?.scheme?.lowercased(), scheme == "http" || scheme == "https" { return nil }
        let path = source.hasPrefix("file://") ? (URL(string: source)?.path ?? source) : (source as NSString).expandingTildeInPath
        return path.hasPrefix("/") ? path : ((directory ?? "") as NSString).appendingPathComponent(path)
    }

    /// Off the main thread, regular files only (the path comes from model
    /// output: `/dev/zero` must not hang the app), size-capped, and decoded
    /// as a thumbnail rather than at full resolution.
    private nonisolated static func loadThumbnail(_ path: String) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? .max) <= 50_000_000,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1400,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Size in points from the file's pixels and DPI (a Retina screenshot is
        // 144 dpi), as NSImage(contentsOfFile:) would, not the thumbnail's pixels.
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let pixelWidth = props[kCGImagePropertyPixelWidth] as? CGFloat ?? CGFloat(cg.width)
        let pixelHeight = props[kCGImagePropertyPixelHeight] as? CGFloat ?? CGFloat(cg.height)
        let dpi = max(props[kCGImagePropertyDPIWidth] as? CGFloat ?? 72, 1)
        return NSImage(cgImage: cg, size: NSSize(width: pixelWidth * 72 / dpi, height: pixelHeight * 72 / dpi))
    }

    private var placeholder: some View {
        Label(alt.isEmpty ? source : alt, systemImage: "photo")
            .font(.system(size: fontSize - 1))
            .foregroundStyle(palette.dim)
    }
}

/// A fenced code block: language and file name, Copy / Save… / Run in new
/// tab (shell snippets), and a line-number gutter.
struct CodeBlockView: View {
    /// The fence's language, with a file name as "lang:name" when it had one.
    let language: String
    let code: String
    let palette: ClaudePalette
    var fontSize: CGFloat = 12
    var lineSpacing: CGFloat = 2
    /// Overrides the system monospaced font (Settings › Chat Text › Code font).
    var font: Font?
    /// False while the fence is still open (the block is streaming in).
    var isComplete = true
    /// The session's directory: where "Run in new tab" runs and Save… starts.
    var directory: String?
    @State private var copied = false

    /// A large block that's still streaming grows on every token batch;
    /// highlighting each partial copy would redo all of it every time.
    private var highlights: Bool { isComplete || code.utf8.count < 4_000 }

    /// "bash:repro.sh" → ("bash", "repro.sh").
    static func split(_ language: String) -> (language: String, file: String?) {
        guard let colon = language.firstIndex(of: ":") else { return (language, nil) }
        let file = String(language[language.index(after: colon)...])
        return (String(language[..<colon]), file.isEmpty ? nil : file)
    }

    var body: some View {
        let (lang, file) = Self.split(language)
        let lineCount = max(1, ClaudeOutput.lineCount(code))
        let codeFont = font ?? .system(size: fontSize, design: .monospaced)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(lang.isEmpty ? "code" : lang)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.dim)
                if let file {
                    Text(file).font(.system(size: 12, design: .monospaced)).foregroundStyle(palette.foreground).lineLimit(1)
                }
                Spacer(minLength: 6)
                headerButton(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
                .help("Copy the code")
                headerButton("Save…") { save(lang: lang, file: file) }
                    .help("Save the code to a file")
                if isComplete, let directory, ClaudeTerminalLauncher.isShell(lang) {
                    Button { ClaudeTerminalLauncher.run(code, language: lang, directory: directory) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill").font(.system(size: 8)).foregroundStyle(palette.green)
                            Text("Run in new tab")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(palette.foreground)
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(palette.foreground.opacity(0.09), in: RoundedRectangle(cornerRadius: DS.Radius.control))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open a terminal tab in \(ClaudeToolFormat.shortPath(directory)) and run this")
                }
            }
            .padding(.leading, 12).padding(.trailing, 8)
            .frame(minHeight: 36)
            .background(palette.surface)
            palette.border.opacity(0.6).frame(height: 0.5)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    // One Text per column keeps a long block cheap; the same font
                    // and spacing keep the numbers on their lines (code doesn't wrap).
                    Text((1...lineCount).map(String.init).joined(separator: "\n"))
                        .font(codeFont)
                        .lineSpacing(lineSpacing)
                        .foregroundStyle(palette.dim.opacity(0.55))
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: 22, alignment: .trailing)
                        .accessibilityHidden(true)
                    Text(highlights ? CodeHighlighter.attributed(code, language: lang, palette: palette) : AttributedString(code))
                        .font(codeFont)
                        .lineSpacing(lineSpacing)
                        .foregroundStyle(palette.foreground)
                        .textSelection(.enabled)
                }
                .fixedSize()
                .padding(.vertical, 8)
                .padding(.leading, 6).padding(.trailing, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.sunken)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(palette.border.opacity(0.8), lineWidth: 0.5))
    }

    private func headerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(palette.foreground.opacity(0.85))
                .padding(.horizontal, 9).frame(height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func save(lang: String, file: String?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.map { ($0 as NSString).lastPathComponent } ?? "snippet." + Self.fileExtension(lang)
        if let directory { panel.directoryURL = URL(fileURLWithPath: directory) }
        let code = code
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data((code.hasSuffix("\n") ? code : code + "\n").utf8).write(to: url)
            } catch {
                MainActor.assumeIsolated { _ = NSAlert(error: error).runModal() }
            }
        }
    }

    static func fileExtension(_ language: String) -> String {
        switch language.lowercased() {
        case "", "text", "plain", "plaintext": "txt"
        case "bash", "shell", "zsh", "sh": "sh"
        case "python", "py": "py"
        case "javascript", "js": "js"
        case "typescript", "ts": "ts"
        case "markdown", "md": "md"
        case "ruby", "rb": "rb"
        case "rust", "rs": "rs"
        case "kotlin", "kt": "kt"
        case "yaml", "yml": "yml"
        default: language.lowercased()
        }
    }
}

struct TableBlockView: View {
    let header: [String]
    var alignments: [MarkdownBlock.TableAlignment] = []
    let rows: [[String]]
    let palette: ClaudePalette
    var fontSize: CGFloat
    var directory: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { i, h in
                        cell(h, column: i).fontWeight(.semibold)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { i, value in
                            cell(value, column: i).textSelection(.enabled)
                        }
                    }
                }
            }
            .font(.system(size: fontSize - 0.5))
            .foregroundStyle(palette.foreground)
            .tint(palette.blue)
            .padding(10)
        }
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(palette.border, lineWidth: 0.5))
    }

    private func cell(_ text: String, column: Int) -> some View {
        let alignment = column < alignments.count ? alignments[column] : .leading
        return Text(InlineMarkdown.attributed(text, palette: palette, directory: directory))
            .multilineTextAlignment(alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
            .gridColumnAlignment(alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
    }
}
