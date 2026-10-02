import AppKit

/// Pure row bookkeeping for command block decorations (unit-tested).
///
/// Rows are *screen* rows: 0 is the top of the scrollback, the same unit as
/// libghostty's scrollbar `offset` (the viewport's top row). Text read from
/// libghostty joins soft-wrapped rows into one logical line, so row counts
/// are recomputed from each line's cell width.
enum CommandBlockLayout {
    /// One logical line of terminal text and the rows it covers.
    struct Line: Equatable {
        /// Trailing whitespace trimmed.
        var text: String
        /// Screen row of its first cell.
        var row: Int
        var rows: Int
    }

    /// A block's decoration: header row and last row (inclusive), in screen rows.
    struct Segment: Equatable {
        var id: UUID
        var headerRow: Int
        var endRow: Int
        /// The header line was checked against the text on screen.
        var headerVerified: Bool
    }

    /// Rows a logical line takes at `columns` (wide characters take two cells).
    static func rowCount(_ line: Substring, columns: Int) -> Int {
        guard columns > 0 else { return 1 }
        // Every cell is at least one UTF-8 byte, so short lines never wrap.
        if line.utf8.count <= columns { return 1 }
        var rows = 1, col = 0
        for ch in line {
            let w = LinkDetector.cellWidth(ch)
            if col + w > columns { rows += 1; col = 0 }
            col += w
        }
        return rows
    }

    /// Splits terminal text into logical lines starting at `startRow`.
    static func lines(_ text: String, columns: Int, startRow: Int = 0) -> [Line] {
        var out: [Line] = []
        var row = startRow
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let rows = rowCount(raw, columns: columns)
            var end = raw.endIndex
            while end > raw.startIndex, raw[raw.index(before: end)].isWhitespace { end = raw.index(before: end) }
            out.append(Line(text: String(raw[..<end]), row: row, rows: rows))
            row += rows
        }
        return out
    }

    /// Whether `line` shows `block`'s header, by the same rules as
    /// `TerminalSession.headerIndex`.
    static func isHeader(_ line: String, of block: TerminalSession.CommandBlock) -> Bool {
        guard let first = firstLine(of: block) else { return false }
        if line == compactHeader(block, first: first) || line.hasSuffix("❯ " + first) { return true }
        return line.hasSuffix(" " + first) && line.count > first.count + 1
    }

    private static func firstLine(of block: TerminalSession.CommandBlock) -> String? {
        var first = Substring(block.command.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        while let last = first.last, last.isWhitespace { first = first.dropLast() }
        return first.isEmpty ? nil : String(first)
    }

    private static func compactHeader(_ block: TerminalSession.CommandBlock, first: String) -> String {
        "\(block.directory)\(block.branch.map { " " + $0 } ?? "") ❯ \(first)"
    }

    /// Finds every block's header in the whole screen, newest first, each
    /// above the next newer one's. Returns the header's screen row per block.
    @MainActor
    static func anchors(blocks: [TerminalSession.CommandBlock], lines: [Line]) -> [UUID: Int] {
        let texts = lines.map(\.text)
        var result: [UUID: Int] = [:]
        var bound = texts.count
        for block in blocks.reversed() {
            guard let i = TerminalSession.headerIndex(of: block, in: texts, before: bound) else { continue }
            result[block.id] = lines[i].row
            bound = i
        }
        return result
    }

    /// Finds `pending` blocks' headers in the viewport's lines (newest
    /// first), keeping anchors in block order: each one below every older
    /// anchored block and above every newer one.
    @MainActor
    static func anchorInViewport(blocks: [TerminalSession.CommandBlock], anchors: inout [UUID: Int],
                                 pending: Set<UUID>, lines: [Line]) {
        guard !pending.isEmpty, let firstRow = lines.first?.row else { return }
        let texts = lines.map(\.text)
        var bound = lines.count
        for (i, block) in blocks.enumerated().reversed() {
            if let a = anchors[block.id] {
                if a < firstRow { break } // everything older is above the viewport
                if let idx = lines.firstIndex(where: { $0.row >= a }) { bound = min(bound, idx) }
                continue
            }
            guard pending.contains(block.id),
                  let idx = TerminalSession.headerIndex(of: block, in: texts, before: bound) else { continue }
            let older = blocks[..<i].compactMap { anchors[$0.id] }.max()
            if let older, lines[idx].row <= older { continue }
            anchors[block.id] = lines[idx].row
            bound = idx
        }
    }

    /// Decorations for finished blocks that intersect `viewport` (screen
    /// rows). A block runs from its header to the row before the next newer
    /// anchored header (or `screenEnd`), minus trailing blank rows on screen.
    static func segments(blocks: [TerminalSession.CommandBlock], anchors: [UUID: Int], verified: Set<UUID>,
                         viewportLines: [Line], viewport: Range<Int>, screenEnd: Int) -> [Segment] {
        guard !viewport.isEmpty else { return [] }
        // Which viewport rows are blank, for trimming a block's tail.
        var blank = [Bool](repeating: true, count: viewport.count)
        for line in viewportLines where !line.text.isEmpty {
            for r in line.row..<(line.row + line.rows) where viewport.contains(r) { blank[r - viewport.lowerBound] = false }
        }
        var out: [Segment] = []
        for (i, block) in blocks.enumerated() where block.isFinished {
            guard let header = anchors[block.id] else { continue }
            let next = blocks[(i + 1)...].lazy.compactMap { anchors[$0.id] }.first { $0 > header }
            var end = (next ?? screenEnd) - 1
            while end > header, viewport.contains(end), blank[end - viewport.lowerBound] { end -= 1 }
            guard header < viewport.upperBound, end >= viewport.lowerBound, end >= header else { continue }
            out.append(Segment(id: block.id, headerRow: header, endRow: end, headerVerified: verified.contains(block.id)))
        }
        return out
    }

    /// "3.2s · 13:52" for a finished block.
    @MainActor static func statusText(duration: TimeInterval?, startedAt: Date) -> String {
        let time = startedAt.formatted(date: .omitted, time: .shortened)
        guard let duration else { return time }
        return TerminalSession.format(duration: duration) + " · " + time
    }
}

/// Draws command blocks over the terminal: a status ("✓ 3.2s · 13:52", or a
/// red "Exit 65" pill) at each header line, and for failed blocks a red tint
/// and border with Copy output / Rerun buttons.
///
/// libghostty owns the grid, so blocks are located by their header lines:
/// anchored once to a screen row, then verified against the viewport text
/// (O(visible)) as it scrolls. The whole screen is only read to re-anchor
/// after a resize, a clear or scrollback trimming. Clicks pass through to the
/// terminal except on the buttons, which never take focus.
@MainActor
final class CommandBlockOverlayView: NSView {
    weak var session: TerminalSession?
    var onCopyOutput: ((TerminalSession.CommandBlock) -> Void)?
    var onRerun: ((TerminalSession.CommandBlock) -> Void)?

    private var scrollbar: (total: Int, offset: Int, length: Int)?
    private var geometry: LinkDetector.Geometry?
    private var anchors: [UUID: Int] = [:]
    /// Searched for in the whole screen and not found (cleared, trimmed).
    private var lost: Set<UUID> = []
    private var segments: [CommandBlockLayout.Segment] = []
    private var refreshWork: DispatchWorkItem?
    private var lastFullAnchor = Date.distantPast
    private var lastColumns = 0
    private var buttons: [BlockChipButton] = []

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        for b in buttons where !b.isHidden && b.frame.contains(p) { return b }
        return nil
    }

    var isEnabled: Bool {
        SettingsStore.shared.settings.showCommandBlocks
    }

    // MARK: Inputs

    func scrollbarChanged(total: UInt64, offset: UInt64, length: UInt64) {
        let new = (Int(clamping: total), Int(clamping: offset), Int(clamping: length))
        guard scrollbar.map({ $0 != new }) ?? true else { return }
        let moved = scrollbar?.offset != new.1
        scrollbar = new
        // Move what's drawn right away; the text check follows, coalesced.
        if moved, !segments.isEmpty {
            needsDisplay = true
            layoutButtons()
        }
        scheduleRefresh()
    }

    /// The block list changed: a command started or finished.
    func blocksChanged() {
        if let session {
            // A finished block gets one more search, even if it was missed while running.
            for b in session.blocks.suffix(2) where b.isFinished { lost.remove(b.id) }
            let live = Set(session.blocks.map(\.id))
            anchors = anchors.filter { live.contains($0.key) }
            lost.formIntersection(live)
        }
        scheduleRefresh()
    }

    /// Size, font or settings changed.
    func invalidate() {
        scheduleRefresh()
    }

    // Re-anchoring waits for a live resize to end.
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        scheduleRefresh()
    }

    /// Coalesces refreshes (a throttle, so streaming output still refreshes).
    func scheduleRefresh(after delay: TimeInterval = 0.15) {
        guard refreshWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.refreshWork = nil
            self?.refresh()
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func clear() {
        guard !segments.isEmpty else { return }
        segments = []
        needsDisplay = true
        layoutButtons()
    }

    // MARK: Refresh

    func refresh() {
        guard isEnabled, let session, !session.blocks.isEmpty, !isHiddenOrHasHiddenAncestor,
              window?.isVisible == true, window?.occlusionState.contains(.visible) == true,
              let sb = scrollbar, let g = LinkDetector.geometry(for: session.surfaceView) else { return clear() }
        geometry = g
        if g.columns != lastColumns {
            // Rewrapping moves every row: start over.
            if lastColumns != 0 { anchors = [:]; lost = [] }
            lastColumns = g.columns
        }
        let blocks = session.blocks
        let running = session.state == .running
        let viewport = sb.offset..<(sb.offset + g.rows)
        let lines = CommandBlockLayout.lines(session.surfaceView.readText(), columns: g.columns, startRow: sb.offset)

        // Verify anchors that should be on screen.
        var verified = Set<UUID>()
        for block in blocks {
            guard let a = anchors[block.id], viewport.contains(a) else { continue }
            if let line = lines.first(where: { $0.row == a }), CommandBlockLayout.isHeader(line.text, of: block) {
                verified.insert(block.id)
            } else if !running {
                // Moved (trimmed scrollback) or gone (cleared). While a command
                // runs it may just be the alternate screen (vim, less): keep it.
                anchors[block.id] = nil
            }
        }

        var pending = Set(blocks.filter { anchors[$0.id] == nil && !lost.contains($0.id) }.map(\.id))
        let atBottom = sb.offset + sb.length >= sb.total
        if !pending.isEmpty, atBottom {
            CommandBlockLayout.anchorInViewport(blocks: blocks, anchors: &anchors, pending: pending, lines: lines)
            for id in pending where anchors[id] != nil { verified.insert(id) }
            pending = pending.filter { anchors[$0] == nil }
        }
        // Blocks still unaccounted for: search the whole screen, rarely.
        let unfinished = blocks.last.flatMap { $0.isFinished ? nil : $0.id }
        if !running, window?.inLiveResize != true, pending.contains(where: { $0 != unfinished }) {
            let wait = 1 - Date().timeIntervalSince(lastFullAnchor)
            if wait <= 0 {
                lastFullAnchor = Date()
                let screen = CommandBlockLayout.lines(session.surfaceView.readText(screen: true), columns: g.columns)
                let found = CommandBlockLayout.anchors(blocks: blocks, lines: screen)
                for id in pending {
                    if let row = found[id] { anchors[id] = row } else if id != unfinished { lost.insert(id) }
                }
                for (id, row) in found where viewport.contains(row) && pending.contains(id) { verified.insert(id) }
            } else {
                scheduleRefresh(after: wait)
            }
        }

        let next = CommandBlockLayout.segments(blocks: blocks, anchors: anchors, verified: verified,
                                               viewportLines: lines, viewport: viewport, screenEnd: sb.total)
            // A header that should be on screen but isn't (vim's alternate screen): draw nothing for it.
            .filter { !viewport.contains($0.headerRow) || $0.headerVerified }
        if next != segments {
            segments = next
            needsDisplay = true
            layoutButtons()
        }
    }

    // MARK: Drawing

    private func rowTop(_ viewportRow: Int, _ g: LinkDetector.Geometry) -> CGFloat {
        g.baseline0 + CGFloat(viewportRow) * g.cellHeight - g.cellHeight * 0.8
    }

    private var theme: TerminalTheme { ConfigController.shared.theme }

    /// Height of the strip above a block's header that holds its status and
    /// buttons, so they never cover the command line itself.
    private static let actionRow: CGFloat = 22

    /// Vertical center of a block's status/buttons: in the strip above the
    /// header, or on the header line when the header is the first visible row.
    private func actionMid(headerViewportRow row: Int, _ g: LinkDetector.Geometry) -> CGFloat {
        let y = rowTop(row, g)
        return row >= 1 ? y - Self.actionRow / 2 - 1 : y + g.cellHeight / 2
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let g = geometry, let sb = scrollbar, let session else { return }
        let t = theme
        let red = NSColor.systemRed
        let dim = t.background.mixed(with: t.foreground, 0.5).nsColor
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        for seg in segments {
            guard let block = session.block(id: seg.id) else { continue }
            let first = max(seg.headerRow - sb.offset, 0), last = min(seg.endRow - sb.offset, g.rows - 1)
            guard first <= last else { continue }
            if block.failed {
                let headerRow = seg.headerRow - sb.offset
                let top = headerRow >= 1 ? rowTop(first, g) - Self.actionRow - 4 : headerRow >= 0 ? rowTop(first, g) - 5 : -8
                let bottom = seg.endRow - sb.offset <= g.rows - 1 ? rowTop(last + 1, g) + 5 : bounds.maxY + 8
                let rect = NSRect(x: max(2, g.originX - 8), y: top, width: bounds.width - max(2, g.originX - 8) - 6, height: bottom - top)
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
                red.withAlphaComponent(t.isDark ? 0.07 : 0.05).setFill()
                path.fill()
                red.withAlphaComponent(0.4).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
            guard seg.headerVerified, seg.headerRow >= sb.offset, seg.headerRow < sb.offset + g.rows else { continue }
            let mid = actionMid(headerViewportRow: seg.headerRow - sb.offset, g)
            var x = bounds.maxX - 14
            let status = CommandBlockLayout.statusText(duration: block.duration, startedAt: block.startedAt)
            if block.failed {
                let durText = block.duration.map { TerminalSession.format(duration: $0) } ?? ""
                let dur = NSAttributedString(string: durText, attributes: [.font: font, .foregroundColor: dim])
                x -= dur.size().width
                dur.draw(at: NSPoint(x: x, y: mid - dur.size().height / 2))
                let pill = NSAttributedString(string: "Exit \(block.exitCode ?? 1)",
                                              attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: red])
                let ps = pill.size()
                x -= ps.width + 8 + 10
                let pr = NSRect(x: x, y: mid - 9, width: ps.width + 10, height: 18)
                t.background.nsColor.setFill()
                NSBezierPath(roundedRect: pr, xRadius: 5, yRadius: 5).fill()
                red.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: pr, xRadius: 5, yRadius: 5).fill()
                pill.draw(at: NSPoint(x: x + 5, y: mid - ps.height / 2))
            } else {
                let s = NSAttributedString(string: "✓ " + status, attributes: [.font: font, .foregroundColor: dim])
                let size = s.size()
                x -= size.width
                // A backing so a long header line stays readable underneath.
                t.background.nsColor.withAlphaComponent(0.85).setFill()
                NSRect(x: x - 6, y: mid - size.height / 2, width: size.width + 6, height: size.height).fill()
                s.draw(at: NSPoint(x: x, y: mid - size.height / 2))
            }
        }
    }

    // MARK: Buttons

    /// Copy output / Rerun for each failed block whose header is on screen.
    private func layoutButtons() {
        var used = 0
        if let g = geometry, let sb = scrollbar, let session {
            let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            for seg in segments where seg.headerVerified && seg.headerRow >= sb.offset && seg.headerRow < sb.offset + g.rows {
                guard let block = session.block(id: seg.id), block.failed else { continue }
                // Right of the buttons: the pill and duration drawn in `draw`.
                let durW = block.duration.map { NSAttributedString(string: TerminalSession.format(duration: $0), attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).size().width } ?? 0
                let pillW = NSAttributedString(string: "Exit \(block.exitCode ?? 1)", attributes: [.font: font]).size().width + 10
                var x = bounds.maxX - 14 - durW - 8 - pillW - 6
                let mid = actionMid(headerViewportRow: seg.headerRow - sb.offset, g)
                for (title, action) in [("Rerun", onRerun), ("Copy output", onCopyOutput)] {
                    let b = button(at: used)
                    used += 1
                    b.label = title
                    b.handler = { [weak self] in
                        guard let block = self?.session?.block(id: seg.id) else { return }
                        action?(block)
                    }
                    let w = b.intrinsicContentSize.width
                    x -= w
                    b.frame = NSRect(x: x, y: mid - 9, width: w, height: 18)
                    b.isHidden = false
                    x -= 6
                }
            }
        }
        for b in buttons.dropFirst(used) { b.isHidden = true }
    }

    private func button(at index: Int) -> BlockChipButton {
        if index < buttons.count { return buttons[index] }
        let b = BlockChipButton()
        addSubview(b)
        buttons.append(b)
        return b
    }

    // For tests and `shellctl debug`.
    var debugSegments: [CommandBlockLayout.Segment] { segments }
    var debugButtonTitles: [String] { buttons.filter { !$0.isHidden }.map(\.label) }
}

/// A small capsule button drawn over the terminal that never takes focus,
/// so clicking it leaves keyboard focus and the selection where they were.
@MainActor
final class BlockChipButton: NSButton {
    var handler: (() -> Void)?

    var label = "" {
        didSet { updateTitle() }
    }

    init() {
        super.init(frame: .zero)
        isBordered = false
        refusesFirstResponder = true
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 5
        target = self
        action = #selector(clicked)
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func updateTitle() {
        let t = ConfigController.shared.theme
        attributedTitle = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: t.foreground.nsColor.withAlphaComponent(0.85),
        ])
        layer?.backgroundColor = t.background.mixed(with: t.foreground, t.isDark ? 0.16 : 0.1).nsColor.cgColor
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(attributedTitle.size().width) + 14, height: 18)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    @objc private func clicked() { handler?() }
}
