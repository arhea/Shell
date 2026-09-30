import AppKit

/// Lays out a tab's panes from its `PaneTree`. All pane views are direct
/// subviews (a flat layout), so terminal surfaces are never re-parented when
/// splits change — that keeps Metal layers stable and avoids flicker.
@MainActor
final class SplitContainerView: NSView {
    private(set) var tree: PaneTree = .leaf(UUID())
    private var panes: [UUID: PaneView] = [:]
    private var zoomed: UUID?
    /// Keyed by split ID and reused across layouts: rebuilding them each pass
    /// would detach the divider being dragged and end the drag after one step.
    private var dividers: [UUID: DividerView] = [:]
    var onRatioChange: ((UUID, Double) -> Void)?
    var dividerColor: NSColor = .separatorColor {
        didSet { dividers.values.forEach { $0.lineColor = dividerColor } }
    }

    static let dividerThickness: CGFloat = 1
    static let dividerHitSlop: CGFloat = 4

    override var isFlipped: Bool { true }

    func update(tree: PaneTree, panes: [UUID: PaneView], zoomed: UUID?) {
        self.tree = tree
        self.zoomed = zoomed
        // Remove panes no longer present.
        for (id, view) in self.panes where panes[id] == nil && view.superview === self {
            view.removeFromSuperview()
        }
        self.panes = panes
        for id in tree.leaves {
            guard let view = panes[id] else { continue }
            if view.superview !== self { addSubview(view, positioned: .below, relativeTo: nil) }
        }
        let multiple = tree.leaves.count > 1 && zoomed == nil
        for view in panes.values { view.showsDimming = multiple }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var placed = Set<UUID>()
        defer {
            for (id, divider) in dividers where !placed.contains(id) {
                divider.removeFromSuperview()
                dividers[id] = nil
            }
        }
        if let zoomed, let view = panes[zoomed] {
            for (id, v) in panes {
                v.isHidden = id != zoomed
            }
            view.frame = bounds
            return
        }
        for v in panes.values { v.isHidden = false }
        place(tree, in: bounds, placed: &placed)
    }

    private func place(_ node: PaneTree, in rect: NSRect, placed: inout Set<UUID>) {
        switch node {
        case .leaf(let id):
            panes[id]?.frame = rect.integral
        case .split(let sid, let dir, let ratio, let a, let b):
            let t = Self.dividerThickness
            let ra: NSRect, rb: NSRect, rd: NSRect
            switch dir {
            case .horizontal:
                let w = floor((rect.width - t) * ratio)
                ra = NSRect(x: rect.minX, y: rect.minY, width: w, height: rect.height)
                rd = NSRect(x: rect.minX + w, y: rect.minY, width: t, height: rect.height)
                rb = NSRect(x: rd.maxX, y: rect.minY, width: rect.maxX - rd.maxX, height: rect.height)
            case .vertical:
                let h = floor((rect.height - t) * ratio)
                ra = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: h)
                rd = NSRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: t)
                rb = NSRect(x: rect.minX, y: rd.maxY, width: rect.width, height: rect.maxY - rd.maxY)
            }
            place(a, in: ra, placed: &placed)
            place(b, in: rb, placed: &placed)
            let divider: DividerView
            if let existing = dividers[sid], existing.direction == dir {
                divider = existing
            } else {
                dividers[sid]?.removeFromSuperview()
                divider = DividerView(splitID: sid, direction: dir)
                divider.lineColor = dividerColor
                divider.onDrag = { [weak self] ratio in self?.onRatioChange?(sid, ratio) }
                dividers[sid] = divider
            }
            divider.parentRect = rect
            let slop = Self.dividerHitSlop
            let frame = dir == .horizontal ? rd.insetBy(dx: -slop, dy: 0) : rd.insetBy(dx: 0, dy: -slop)
            if divider.frame != frame {
                divider.frame = frame
                window?.invalidateCursorRects(for: divider)
            }
            // Above the panes, which are added below everything.
            if divider.superview !== self { addSubview(divider) }
            placed.insert(sid)
        }
    }
}

/// A draggable split divider with a wider invisible hit area.
@MainActor
final class DividerView: NSView {
    let splitID: UUID
    let direction: SplitDirection
    var parentRect: NSRect = .zero
    var onDrag: ((Double) -> Void)?
    var lineColor: NSColor = .separatorColor { didSet { needsDisplay = true } }

    init(splitID: UUID, direction: SplitDirection) {
        self.splitID = splitID
        self.direction = direction
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        lineColor.setFill()
        let t = SplitContainerView.dividerThickness
        if direction == .horizontal {
            NSRect(x: (bounds.width - t) / 2, y: 0, width: t, height: bounds.height).fill()
        } else {
            NSRect(x: 0, y: (bounds.height - t) / 2, width: bounds.width, height: t).fill()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: direction == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        let p = superview.convert(event.locationInWindow, from: nil)
        let ratio: Double
        if direction == .horizontal {
            ratio = (p.x - parentRect.minX) / max(parentRect.width, 1)
        } else {
            ratio = (p.y - parentRect.minY) / max(parentRect.height, 1)
        }
        onDrag?(min(max(ratio, 0.08), 0.92))
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 { onDrag?(0.5) }
    }
}
