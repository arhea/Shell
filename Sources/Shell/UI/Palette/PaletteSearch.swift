import Foundation

/// The command palette's result groups, in display order.
enum PaletteSection: Int, CaseIterable, Comparable {
    /// The command Apple Intelligence matched to a plain-English request.
    case suggested
    case tabs, worktrees, folders, actions, themes, history

    var title: String {
        switch self {
        case .suggested: "Suggested"
        case .tabs: "Tabs"
        case .worktrees: "Worktrees"
        case .folders: "Folders"
        case .actions: "Actions"
        case .themes: "Themes"
        case .history: "History"
        }
    }

    /// Most rows a section shows, so one long section can't bury the rest.
    var limit: Int {
        switch self {
        case .suggested: 1
        case .tabs: 9
        case .worktrees: 6
        case .folders: 6
        case .actions: 12
        case .themes: 6
        case .history: 8
        }
    }

    static func < (a: PaletteSection, b: PaletteSection) -> Bool { a.rawValue < b.rawValue }
}

/// What the user typed, split into a scope prefix and the search text:
/// `>` searches actions only, `@` folders and worktrees only.
struct PaletteQuery: Equatable {
    enum Scope: Equatable { case all, actions, places }

    var scope: Scope
    var text: String

    static func parse(_ raw: String) -> PaletteQuery {
        let trimmed = raw.drop { $0 == " " }
        if trimmed.hasPrefix(">") {
            return PaletteQuery(scope: .actions, text: trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
        }
        if trimmed.hasPrefix("@") {
            return PaletteQuery(scope: .places, text: trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
        }
        return PaletteQuery(scope: .all, text: raw.trimmingCharacters(in: .whitespaces))
    }

    /// Whether results from `section` can show for this query.
    func includes(_ section: PaletteSection) -> Bool {
        switch scope {
        case .all:
            // Themes and history are long lists: only when searching.
            return !text.isEmpty || ![.themes, .history].contains(section)
        case .actions:
            return section == .actions || section == .suggested
        case .places:
            return section == .worktrees || section == .folders
        }
    }
}

/// Filtering, ranking and grouping for the palette. Pure, so the rules are
/// unit-tested without a window.
enum PaletteSearch {
    struct Group<Item> {
        var section: PaletteSection
        var items: [Item]
    }

    /// Groups `items` into sections in display order, keeping only those that
    /// match the query (best match first within a section) and at most each
    /// section's limit. With no search text, sections keep their given order.
    static func group<Item>(_ items: [Item], query: PaletteQuery, section: (Item) -> PaletteSection,
                            title: (Item) -> String) -> [Group<Item>] {
        var buckets: [PaletteSection: [(item: Item, score: Int, order: Int)]] = [:]
        let needle = query.text.lowercased()
        for (order, item) in items.enumerated() {
            let s = section(item)
            guard query.includes(s) else { continue }
            let score: Int
            if needle.isEmpty || s == .suggested {
                score = 0
            } else {
                guard let found = FuzzyMatch.score(needle, in: title(item).lowercased()) else { continue }
                score = found
            }
            buckets[s, default: []].append((item, score, order))
        }
        // An unscoped, empty query only previews actions; `>` lists them all.
        let unlimitedActions = query.scope == .actions
        return PaletteSection.allCases.compactMap { s in
            guard let bucket = buckets[s], !bucket.isEmpty else { return nil }
            let sorted = bucket.sorted { $0.score != $1.score ? $0.score < $1.score : $0.order < $1.order }
            let limit = s == .actions && unlimitedActions ? Int.max : s.limit
            return Group(section: s, items: sorted.prefix(limit).map(\.item))
        }
    }

    /// Character offsets in `haystack` to show in bold for `needle`: the first
    /// contiguous match when there is one, else the subsequence FuzzyMatch
    /// scored. Nil when it doesn't match. Case-insensitive.
    static func matchIndices(_ needle: String, in haystack: String) -> [Int]? {
        let n = Array(needle.lowercased()), h = Array(haystack.lowercased())
        guard !n.isEmpty else { return [] }
        guard h.count == haystack.count else { return [] }  // lowercasing changed the length; skip highlighting
        if n.count <= h.count {
            for start in 0...(h.count - n.count) where Array(h[start..<(start + n.count)]) == n {
                return Array(start..<(start + n.count))
            }
        }
        var result: [Int] = []
        var i = 0
        for ch in n {
            while i < h.count, h[i] != ch { i += 1 }
            guard i < h.count else { return nil }
            result.append(i)
            i += 1
        }
        return result
    }
}
