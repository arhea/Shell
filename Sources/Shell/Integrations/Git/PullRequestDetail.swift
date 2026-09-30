import Foundation

/// What the GitHub tab's detail pane shows for one PR, from `gh pr view`,
/// the review comments API and `gh pr diff`.
struct PullRequestDetail: Equatable {
    struct Check: Identifiable, Equatable {
        enum State: Equatable { case passing, failing, pending, skipped }
        var name: String
        var workflow: String?
        var state: State
        var url: URL?
        var id: String { (workflow ?? "") + "/" + name }
    }

    /// One entry in the conversation: a comment, a review, or an inline review comment.
    struct Event: Identifiable, Equatable {
        enum Kind: Equatable {
            case comment
            case review(state: String)
            case reviewComment(path: String, line: Int?)
        }
        var id: String
        var kind: Kind
        var author: String
        var body: String
        var date: Date?
        var url: URL?
    }

    struct Reviewer: Identifiable, Equatable {
        /// APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED, or REQUESTED (not yet reviewed).
        var login: String
        var state: String
        var id: String { login }
    }

    var body: String
    var mergeable: String
    var mergeStateStatus: String
    var checks: [Check]
    var reviewers: [Reviewer]
    var events: [Event]

    static let viewFields = "body,comments,reviews,latestReviews,reviewRequests,statusCheckRollup,mergeable,mergeStateStatus"

    /// Parses `gh pr view --json <viewFields>` plus the `pulls/<n>/comments` array.
    static func parse(view: Data, reviewComments: Data?) -> PullRequestDetail? {
        guard let o = try? JSONSerialization.jsonObject(with: view) as? [String: Any] else { return nil }
        let iso = ISO8601DateFormatter()
        func date(_ v: Any?) -> Date? { (v as? String).flatMap { iso.date(from: $0) } }
        func login(_ v: Any?) -> String { (v as? [String: Any])?["login"] as? String ?? "ghost" }

        var events: [Event] = []
        for (i, c) in (o["comments"] as? [[String: Any]] ?? []).enumerated() {
            events.append(Event(id: c["id"] as? String ?? "comment-\(i)", kind: .comment, author: login(c["author"]),
                                body: c["body"] as? String ?? "", date: date(c["createdAt"]),
                                url: (c["url"] as? String).flatMap(URL.init(string:))))
        }
        for (i, r) in (o["reviews"] as? [[String: Any]] ?? []).enumerated() {
            let state = r["state"] as? String ?? "COMMENTED"
            let body = r["body"] as? String ?? ""
            // A bare "commented" review is just the wrapper for inline comments, listed below.
            if state == "COMMENTED" && body.isEmpty { continue }
            events.append(Event(id: r["id"] as? String ?? "review-\(i)", kind: .review(state: state), author: login(r["author"]),
                                body: body, date: date(r["submittedAt"]), url: nil))
        }
        if let data = reviewComments, let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for c in list {
                let id = (c["id"] as? Int).map(String.init) ?? UUID().uuidString
                events.append(Event(id: "rc-" + id,
                                    kind: .reviewComment(path: c["path"] as? String ?? "", line: c["line"] as? Int ?? c["original_line"] as? Int),
                                    author: login(c["user"]), body: c["body"] as? String ?? "", date: date(c["created_at"]),
                                    url: (c["html_url"] as? String).flatMap(URL.init(string:))))
            }
        }
        events.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }

        var reviewers: [Reviewer] = (o["latestReviews"] as? [[String: Any]] ?? []).map {
            Reviewer(login: login($0["author"]), state: $0["state"] as? String ?? "COMMENTED")
        }
        for r in o["reviewRequests"] as? [[String: Any]] ?? [] {
            let name = r["login"] as? String ?? (r["slug"] as? String).map { "team:" + $0 } ?? r["name"] as? String ?? ""
            if !name.isEmpty, !reviewers.contains(where: { $0.login == name }) { reviewers.append(Reviewer(login: name, state: "REQUESTED")) }
        }

        return PullRequestDetail(
            body: o["body"] as? String ?? "",
            mergeable: o["mergeable"] as? String ?? "UNKNOWN",
            mergeStateStatus: o["mergeStateStatus"] as? String ?? "UNKNOWN",
            checks: (o["statusCheckRollup"] as? [[String: Any]] ?? []).map(parseCheck),
            reviewers: reviewers,
            events: events)
    }

    static func parseCheck(_ c: [String: Any]) -> Check {
        let status = (c["status"] as? String ?? "").uppercased()
        let conclusion = (c["conclusion"] as? String ?? "").uppercased()
        let state = (c["state"] as? String ?? "").uppercased()
        let s: Check.State
        if ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains(conclusion) || ["FAILURE", "ERROR"].contains(state) {
            s = .failing
        } else if (!status.isEmpty && status != "COMPLETED") || ["PENDING", "EXPECTED"].contains(state) {
            s = .pending
        } else if ["SKIPPED", "NEUTRAL"].contains(conclusion) {
            s = .skipped
        } else {
            s = .passing
        }
        let url = (c["detailsUrl"] as? String ?? c["targetUrl"] as? String).flatMap(URL.init(string:))
        return Check(name: c["name"] as? String ?? c["context"] as? String ?? "check",
                     workflow: (c["workflowName"] as? String).flatMap { $0.isEmpty ? nil : $0 }, state: s, url: url)
    }
}

/// A unified diff (`gh pr diff`) split into files of `ClaudeDiff.Line`s, so
/// the detail pane can draw them with the Claude view's `DiffView`.
enum PullRequestDiff {
    struct File: Identifiable, Equatable {
        var path: String
        /// The old path, for a rename.
        var oldPath: String?
        var lines: [ClaudeDiff.Line]
        var additions: Int
        var deletions: Int
        var isBinary = false
        var id: String { path }
    }

    static func parse(_ patch: String) -> [File] {
        var files: [File] = []
        var current: File?
        var oldLine = 0, newLine = 0
        // Header lines (---, +++, rename) only count before a file's first hunk:
        // inside one, "+++x" is an added line that starts with "++".
        var inHunk = false
        func flush() { if let c = current { files.append(c) } }

        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                flush()
                // "diff --git a/x b/y": prefer the b/ side; the ---/+++ lines refine it.
                let path = line.components(separatedBy: " b/").last ?? ""
                current = File(path: path, lines: [], additions: 0, deletions: 0)
                inHunk = false
                continue
            }
            guard current != nil else { continue }
            if line.hasPrefix("@@") {
                inHunk = true
                // @@ -12,7 +12,9 @@ context
                let parts = line.split(separator: " ")
                if parts.count >= 3 {
                    oldLine = Int(parts[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    newLine = Int(parts[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                let header = line.components(separatedBy: "@@").dropFirst(2).joined(separator: "@@").trimmingCharacters(in: .whitespaces)
                current?.lines.append(ClaudeDiff.Line(kind: .gap, text: header.isEmpty ? "Line \(newLine)" : header))
            } else if !inHunk {
                if line.hasPrefix("rename from ") {
                    current?.oldPath = String(line.dropFirst("rename from ".count))
                } else if line.hasPrefix("rename to ") {
                    current?.path = String(line.dropFirst("rename to ".count))
                } else if line.hasPrefix("Binary files ") {
                    current?.isBinary = true
                } else if line.hasPrefix("+++ ") {
                    let p = String(line.dropFirst(4))
                    if p != "/dev/null" { current?.path = p.hasPrefix("b/") ? String(p.dropFirst(2)) : p }
                }
            } else if line.hasPrefix("+") {
                current?.lines.append(ClaudeDiff.Line(kind: .added, text: String(line.dropFirst()), newNumber: newLine))
                current?.additions += 1
                newLine += 1
            } else if line.hasPrefix("-") {
                current?.lines.append(ClaudeDiff.Line(kind: .removed, text: String(line.dropFirst()), oldNumber: oldLine))
                current?.deletions += 1
                oldLine += 1
            } else if line.hasPrefix(" ") {
                current?.lines.append(ClaudeDiff.Line(kind: .context, text: String(line.dropFirst()), oldNumber: oldLine, newNumber: newLine))
                oldLine += 1
                newLine += 1
            }
            // "\ No newline at end of file", index/mode lines: skipped.
        }
        flush()
        return files
    }
}
