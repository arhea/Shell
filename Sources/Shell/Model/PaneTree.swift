import Foundation

enum SplitDirection: String, Codable {
    /// Panes side by side, divided by a vertical line (iTerm "split vertically").
    case horizontal
    /// Panes stacked, divided by a horizontal line.
    case vertical
}

enum FocusDirection {
    case left, right, up, down
}

/// Immutable binary split tree of panes. Leaves hold session IDs.
indirect enum PaneTree: Equatable {
    case leaf(UUID)
    case split(id: UUID, direction: SplitDirection, ratio: Double, first: PaneTree, second: PaneTree)

    var leaves: [UUID] {
        switch self {
        case .leaf(let id): [id]
        case .split(_, _, _, let a, let b): a.leaves + b.leaves
        }
    }

    func contains(_ id: UUID) -> Bool { leaves.contains(id) }

    /// Replaces the leaf `target` with a split containing it and `new`.
    func inserting(_ new: UUID, nextTo target: UUID, direction: SplitDirection, before: Bool = false) -> PaneTree {
        switch self {
        case .leaf(let id) where id == target:
            let a: PaneTree = before ? .leaf(new) : .leaf(id)
            let b: PaneTree = before ? .leaf(id) : .leaf(new)
            return .split(id: UUID(), direction: direction, ratio: 0.5, first: a, second: b)
        case .leaf:
            return self
        case .split(let sid, let dir, let ratio, let a, let b):
            return .split(id: sid, direction: dir, ratio: ratio,
                          first: a.inserting(new, nextTo: target, direction: direction, before: before),
                          second: b.inserting(new, nextTo: target, direction: direction, before: before))
        }
    }

    /// Removes a leaf; its sibling takes the parent's place. Returns nil if the tree becomes empty.
    func removing(_ target: UUID) -> PaneTree? {
        switch self {
        case .leaf(let id):
            return id == target ? nil : self
        case .split(let sid, let dir, let ratio, let a, let b):
            let na = a.removing(target)
            let nb = b.removing(target)
            switch (na, nb) {
            case (nil, nil): return nil
            case (let x?, nil): return x
            case (nil, let y?): return y
            case (let x?, let y?): return .split(id: sid, direction: dir, ratio: ratio, first: x, second: y)
            }
        }
    }

    func settingRatio(_ newRatio: Double, forSplit splitID: UUID) -> PaneTree {
        switch self {
        case .leaf: return self
        case .split(let sid, let dir, let ratio, let a, let b):
            if sid == splitID {
                return .split(id: sid, direction: dir, ratio: min(max(newRatio, 0.05), 0.95), first: a, second: b)
            }
            return .split(id: sid, direction: dir, ratio: ratio,
                          first: a.settingRatio(newRatio, forSplit: splitID),
                          second: b.settingRatio(newRatio, forSplit: splitID))
        }
    }

    /// Resets every split so panes share space evenly along each axis.
    func equalized() -> PaneTree {
        switch self {
        case .leaf: return self
        case .split(let sid, let dir, _, let a, let b):
            let na = a.equalized(), nb = b.equalized()
            let wa = Double(na.count(along: dir)), wb = Double(nb.count(along: dir))
            return .split(id: sid, direction: dir, ratio: wa / (wa + wb), first: na, second: nb)
        }
    }

    private func count(along dir: SplitDirection) -> Int {
        switch self {
        case .leaf: return 1
        case .split(_, let d, _, let a, let b):
            return d == dir ? a.count(along: dir) + b.count(along: dir) : max(a.count(along: dir), b.count(along: dir))
        }
    }

    /// Frames of each leaf in a unit square (origin top-left).
    func layout(in rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [UUID: CGRect] {
        switch self {
        case .leaf(let id): return [id: rect]
        case .split(_, let dir, let ratio, let a, let b):
            let (ra, rb) = Self.divide(rect, dir, ratio)
            return a.layout(in: ra).merging(b.layout(in: rb)) { x, _ in x }
        }
    }

    static func divide(_ rect: CGRect, _ dir: SplitDirection, _ ratio: Double) -> (CGRect, CGRect) {
        switch dir {
        case .horizontal:
            let w = rect.width * ratio
            return (CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height),
                    CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height))
        case .vertical:
            let h = rect.height * ratio
            return (CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h),
                    CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h))
        }
    }

    /// The nearest pane in `direction` from `id`, using geometric layout.
    func neighbor(of id: UUID, _ direction: FocusDirection) -> UUID? {
        let frames = layout()
        guard let from = frames[id] else { return nil }
        let eps = 0.0001
        let candidates = frames.filter { key, r in
            guard key != id else { return false }
            switch direction {
            case .left: return r.maxX <= from.minX + eps && r.maxY > from.minY + eps && r.minY < from.maxY - eps
            case .right: return r.minX >= from.maxX - eps && r.maxY > from.minY + eps && r.minY < from.maxY - eps
            case .up: return r.maxY <= from.minY + eps && r.maxX > from.minX + eps && r.minX < from.maxX - eps
            case .down: return r.minY >= from.maxY - eps && r.maxX > from.minX + eps && r.minX < from.maxX - eps
            }
        }
        return candidates.min { a, b in
            func dist(_ r: CGRect) -> Double {
                switch direction {
                case .left: return from.minX - r.maxX + abs(r.midY - from.midY) * 0.01
                case .right: return r.minX - from.maxX + abs(r.midY - from.midY) * 0.01
                case .up: return from.minY - r.maxY + abs(r.midX - from.midX) * 0.01
                case .down: return r.minY - from.maxY + abs(r.midX - from.midX) * 0.01
                }
            }
            let da = dist(a.value), db = dist(b.value)
            if abs(da - db) > 0.000001 { return da < db }
            // Ties (e.g. two stacked panes): prefer the top, then the left one.
            return (a.value.minY, a.value.minX) < (b.value.minY, b.value.minX)
        }?.key
    }
}

// MARK: - Codable snapshot for session restore

struct PaneTreeSnapshot: Codable {
    var leafDirectory: String?
    /// The pane's session ID, reused on restore so references to it (App
    /// Intents, notifications, widget links) survive a relaunch.
    var leafSessionID: UUID?
    var direction: SplitDirection?
    var ratio: Double?
    var children: [PaneTreeSnapshot]?
}
