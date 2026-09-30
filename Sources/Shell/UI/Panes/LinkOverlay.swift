import AppKit

/// Draws link underlines above the terminal and a "⌘-click to open" hint on hover.
@MainActor
final class LinkOverlayView: NSView {
    private(set) var links: [DetectedLink] = []
    private(set) var hovered: DetectedLink?
    private var commandDown = false
    private let hint = HintBubble()
    private var hintState: (link: DetectedLink, commandDown: Bool, size: NSSize)?
    var color: NSColor = .linkColor { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        hint.isHidden = true
        addSubview(hint)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(links: [DetectedLink]) {
        guard links != self.links else { return }
        self.links = links
        if let h = hovered, !links.contains(h) { setHovered(nil, at: nil) }
        needsDisplay = true
    }

    func link(at point: CGPoint) -> DetectedLink? { links.first { $0.contains(point) } }

    /// `point` is in the overlay's (== surface's) flipped coordinates.
    func mouseMoved(to point: CGPoint?, modifiers: NSEvent.ModifierFlags) {
        commandDown = modifiers.contains(.command)
        let link = point.flatMap { p in links.first { $0.contains(p) } }
        setHovered(link, at: point)
    }

    private func setHovered(_ link: DetectedLink?, at point: CGPoint?) {
        let changed = link != hovered
        hovered = link
        if changed { needsDisplay = true }
        guard let link, let first = link.rects.first else {
            hint.isHidden = true
            hintState = nil
            return
        }
        // Rebuild and measure the bubble only when its content changes, not on every mouse move.
        if hintState?.link != link || hintState?.commandDown != commandDown {
            hint.set(link: link, commandDown: commandDown)
            hintState = (link, commandDown, hint.fittingSize)
        }
        let size = hintState?.size ?? .zero
        var x = min(max(8, (point?.x ?? first.minX) - size.width / 2), bounds.width - size.width - 8)
        x = max(8, x)
        var y = first.minY - size.height - 4
        if y < 4 { y = (link.rects.last?.maxY ?? first.maxY) + 4 }
        hint.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        hint.isHidden = false
    }

    override func draw(_ dirtyRect: NSRect) {
        for link in links {
            let isHovered = link == hovered
            for r in link.rects {
                if isHovered {
                    color.withAlphaComponent(0.14).setFill()
                    NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: 1), xRadius: 3, yRadius: 3).fill()
                }
                color.withAlphaComponent(isHovered ? 1 : 0.7).setFill()
                let y = r.maxY - (isHovered ? 3 : 2.5), h: CGFloat = isHovered ? 1.5 : 1
                if link.isFile && !isHovered {
                    // Dotted underline tells files apart from web links.
                    var x = r.minX
                    while x < r.maxX {
                        NSRect(x: x, y: y, width: min(2, r.maxX - x), height: h).fill()
                        x += 4
                    }
                } else {
                    NSRect(x: r.minX, y: y, width: r.width, height: h).fill()
                }
            }
        }
    }
}

/// Small rounded tooltip: "⌘-click to open  github.com/…".
@MainActor
final class HintBubble: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 0.5
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(link: DetectedLink, commandDown: Bool) {
        let t = ConfigController.shared.theme
        layer?.backgroundColor = t.background.mixed(with: t.foreground, t.isDark ? 0.14 : 0.06).nsColor.cgColor
        layer?.borderColor = t.background.mixed(with: t.foreground, 0.25).nsColor.cgColor
        let action: String
        let detail: String
        switch link.kind {
        case .url:
            action = commandDown ? "Click to open" : "⌘-click to open"
            detail = link.target.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        case .file(let isDirectory):
            action = commandDown ? "Click to show in Finder" : "⌘-click to show in Finder"
            let home = NSHomeDirectory()
            let p = link.target.hasPrefix(home) ? "~" + link.target.dropFirst(home.count) : link.target
            detail = p + (isDirectory ? "/" : "")
        }
        let s = NSMutableAttributedString(
            string: action,
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: t.foreground.nsColor])
        s.append(NSAttributedString(string: "  " + (detail.count > 60 ? "…" + String(detail.suffix(57)) : detail),
                                    attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                 .foregroundColor: t.background.mixed(with: t.foreground, 0.6).nsColor]))
        label.attributedStringValue = s
        needsLayout = true
    }

    override var fittingSize: NSSize {
        let s = label.fittingSize
        return NSSize(width: min(s.width + 16, 460), height: s.height + 8)
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 8, dy: 4)
    }
}
