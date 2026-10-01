import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Shell

// MARK: - Command line

final class ClaudeArgumentEdgeCaseTests: XCTestCase {
    private let sessionID = "7bcc953c-5abd-4120-82da-148001c196cb"

    func testDoubleDashEndsFlags() {
        XCTAssertEqual(ClaudeArguments.parse(["--", "-p is a prompt here"])?.prompt, "-p is a prompt here")
        XCTAssertNil(ClaudeArguments.parse(["--", "one", "two"]), "claude takes a single prompt")
        XCTAssertNil(ClaudeArguments.parse(["one", "two"]))
        XCTAssertNil(ClaudeArguments.parse([""])?.prompt, "an empty prompt is no prompt")
    }

    func testDebugTakesAnOptionalFilter() {
        XCTAssertEqual(ClaudeArguments.parse(["-d", "api,hooks"])?.passthrough, ["-d", "api,hooks"])
        XCTAssertEqual(ClaudeArguments.parse(["--debug", "!statsig"])?.passthrough, ["--debug", "!statsig"])
        let withPrompt = ClaudeArguments.parse(["--debug", "fix it"])
        XCTAssertEqual(withPrompt?.passthrough, ["--debug"])
        XCTAssertEqual(withPrompt?.prompt, "fix it", "a value without , or ! is the prompt")
        XCTAssertEqual(ClaudeArguments.parse(["--debug=api"])?.passthrough, ["--debug=api"])
        XCTAssertEqual(ClaudeArguments.parse(["-d", "--verbose"])?.passthrough, ["-d", "--verbose"])
    }

    func testValuesInlineAndMissing() {
        XCTAssertEqual(ClaudeArguments.parse(["--add-dir=../a"])?.passthrough, ["--add-dir", "../a"])
        XCTAssertEqual(ClaudeArguments.parse(["--allowed-tools", "Bash", "Read", "--verbose"])?.passthrough,
                       ["--allowed-tools", "Bash", "Read", "--verbose"])
        XCTAssertNil(ClaudeArguments.parse(["--add-dir"]), "a list flag needs a value")
        XCTAssertNil(ClaudeArguments.parse(["--add-dir", "--verbose"]))
        XCTAssertNil(ClaudeArguments.parse(["--agent"]))
        XCTAssertEqual(ClaudeArguments.parse(["--agent=reviewer"])?.passthrough, ["--agent", "reviewer"])
        XCTAssertNil(ClaudeArguments.parse(["--model"]))
        XCTAssertNil(ClaudeArguments.parse(["--effort"]))
        XCTAssertNil(ClaudeArguments.parse(["--permission-mode"]))
        XCTAssertEqual(ClaudeArguments.parse(["--permission-mode=acceptEdits"])?.permissionMode, "acceptEdits")
        XCTAssertNil(ClaudeArguments.parse(["--print=yes"]))
        XCTAssertNil(ClaudeArguments.parse(["mcp", "list"]))
        XCTAssertEqual(ClaudeArguments.parse(["-"])?.prompt, "-", "a lone dash is a positional")
    }

    func testResumeAndSessionSelection() {
        let inline = ClaudeArguments.parse(["--resume=\(sessionID)"])
        XCTAssertEqual(inline?.passthrough, ["--resume", sessionID])
        XCTAssertEqual(inline?.resumeID, sessionID)
        XCTAssertNil(ClaudeArguments.parse(["-r"]))
        XCTAssertNil(ClaudeArguments.parse(["--resume=nope"]))
        XCTAssertNil(ClaudeArguments(passthrough: ["--resume"]).resumeID, "a dangling --resume has no ID")
        XCTAssertTrue(ClaudeArguments(passthrough: ["--continue"]).continuesSession)
        XCTAssertFalse(ClaudeArguments().continuesSession)
        XCTAssertTrue(ClaudeArguments(passthrough: ["--allow-dangerously-skip-permissions"]).allowsBypass)
        XCTAssertFalse(ClaudeArguments().allowsBypass)
    }
}

// MARK: - Launching from a prompt

@MainActor
final class ClaudeLauncherTests: XCTestCase {
    private var terminal: TerminalSession!
    private var folder: URL!

    override func setUp() async throws {
        folder = try makeTemporaryDirectory()
        // Nothing is trusted, so a native view never starts a process.
        let config = folder.appendingPathComponent("claude.json")
        try Data("{}".utf8).write(to: config)
        ClaudeTrust.configURLOverride = config
        try FileManager.default.createDirectory(at: ShellIntegration.runtimeDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        terminal = TerminalSession(workingDirectory: folder.path)
    }

    override func tearDown() async throws {
        terminal.endNativeClaude()
        terminal.close() // removes the session's runtime files
        terminal = nil
        ClaudeTrust.configURLOverride = nil
        ClaudeLauncher.alertResponder = nil
    }

    private var answer: String {
        (try? String(contentsOf: ShellIntegration.runtimeDirectory.appendingPathComponent("\(terminal.id.uuidString).claude"),
                     encoding: .utf8)) ?? ""
    }

    func testTerminalModeAnswersTerminal() {
        withSettings({ $0.claudeLaunchMode = .terminal; $0.claudeRemoteControl = false }) {
            ClaudeLauncher.handle(session: terminal, directory: folder.path, binary: "/usr/bin/false", arguments: ["fix it"])
            XCTAssertEqual(answer, "terminal")
            XCTAssertNil(terminal.nativeClaude)
        }
        withSettings({ $0.claudeLaunchMode = .terminal; $0.claudeRemoteControl = true }) {
            ClaudeLauncher.handle(session: terminal, directory: folder.path, binary: "/usr/bin/false", arguments: [])
            XCTAssertEqual(answer, "terminal-rc")
        }
    }

    func testCommandsTheNativeViewCantRunGoToTheTerminal() {
        withSettings({ $0.claudeLaunchMode = .native }) {
            ClaudeLauncher.handle(session: terminal, directory: folder.path, binary: "/usr/bin/false", arguments: ["-p", "hi"])
            XCTAssertEqual(answer, "terminal")
            XCTAssertNil(terminal.nativeClaude)
        }
    }

    func testAskModeFollowsTheChoiceAndCanRememberIt() {
        var focused = 0
        terminal.onRequestFocus = { focused += 1 }
        withSettings({ $0.claudeLaunchMode = .ask; $0.claudeRemoteControl = false }) {
            var shown: [String] = []
            ClaudeLauncher.alertResponder = { alert in
                shown.append(alert.messageText)
                return .alertThirdButtonReturn
            }
            ClaudeLauncher.handle(session: terminal, directory: folder.path, binary: "/usr/bin/false", arguments: [])
            XCTAssertEqual(answer, "cancel")
            XCTAssertEqual(shown, ["Open Claude Code in Shell's native view?"])

            ClaudeLauncher.alertResponder = { _ in .alertSecondButtonReturn }
            ClaudeLauncher.handle(session: terminal, directory: folder.path, binary: "/usr/bin/false", arguments: [])
            XCTAssertEqual(answer, "terminal")
            XCTAssertEqual(SettingsStore.shared.settings.claudeLaunchMode, .ask, "not remembered unless asked to")

            ClaudeLauncher.alertResponder = { alert in
                alert.suppressionButton?.state = .on
                return .alertFirstButtonReturn
            }
            ClaudeLauncher.handle(session: terminal, directory: folder.path, binary: "/usr/bin/false", arguments: [])
            XCTAssertEqual(answer, "native")
            XCTAssertNotNil(terminal.nativeClaude)
            XCTAssertEqual(SettingsStore.shared.settings.claudeLaunchMode, .native, "the choice is remembered")
        }
        XCTAssertEqual(focused, 3, "the pane comes forward before asking")
    }

    func testNativeModeOpensTheNativeViewWithTheShellsEnvironment() throws {
        let env = "FAKE_VAR=1\u{0}PATH=/usr/bin:/bin\u{0}junk\u{0}"
        try Data(env.utf8).write(to: ShellIntegration.runtimeDirectory.appendingPathComponent("\(terminal.id.uuidString).env"))
        withSettings({ $0.claudeLaunchMode = .native }) {
            ClaudeLauncher.handle(session: terminal, directory: "", binary: "/usr/bin/false", arguments: ["--model", "opus"])
            XCTAssertEqual(answer, "native")
            let claude = terminal.nativeClaude
            XCTAssertNotNil(claude)
            XCTAssertEqual(claude?.request.environment["FAKE_VAR"], "1")
            XCTAssertEqual(claude?.request.arguments.model, "opus")
            XCTAssertEqual(claude?.directory, terminal.workingDirectory, "an empty directory means the pane's folder")
            XCTAssertEqual(claude?.needsTrust, true, "an untrusted folder waits for the user")
            XCTAssertEqual(ClaudeLauncher.lastEnvironment?["FAKE_VAR"], "1")
            XCTAssertEqual(terminal.displayTitle, "Claude")

            // A second `claude` while the view is open runs in the terminal.
            ClaudeLauncher.handle(session: terminal, directory: folder.path, binary: "/usr/bin/false", arguments: [])
            XCTAssertEqual(answer, "terminal")
            XCTAssertTrue(terminal.nativeClaude === claude)
        }
    }
}

// MARK: - Usage

@MainActor
final class ClaudeUsageRefreshTests: XCTestCase {
    private func line(id: String, at date: Date, model: String = "claude-opus-5", session: String = "s1", output: Int = 5) -> String {
        let stamp = ISO8601DateFormatter().string(from: date)
        return #"{"type":"assistant","sessionId":"\#(session)","requestId":"r","timestamp":"\#(stamp)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":1,"output_tokens":\#(output)}}}"#
    }

    private func defaults() -> UserDefaults {
        let name = "ShellTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    func testRefreshScansTranscriptsOncePerMinute() throws {
        let root = try makeTemporaryDirectory()
        let dir = root.appendingPathComponent("-Users-me-repo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try [line(id: "m1", at: Date()), line(id: "m2", at: Date(), model: "claude-haiku-4-5", session: "s2", output: 50)]
            .joined(separator: "\n").appending("\n").write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)

        let usage = ClaudeUsage(defaults: defaults(), scanner: TranscriptScanner(root: root))
        XCTAssertNil(usage.tokens)
        usage.refreshIfNeeded()
        XCTAssertTrue(usage.isScanning)
        usage.refreshIfNeeded() // already scanning
        XCTAssertTrue(waitUntil { usage.tokens != nil })
        XCTAssertFalse(usage.isScanning)
        XCTAssertEqual(usage.tokens?.sessionsToday, 2)
        XCTAssertEqual(usage.tokens?.modelsToday.first?.0, "claude-haiku-4-5", "the busiest model comes first")
        XCTAssertEqual(usage.tokens?.today.total, 57)

        // Within a minute nothing rescans, even after new usage.
        try line(id: "m3", at: Date()).appending("\n").write(to: dir.appendingPathComponent("b.jsonl"), atomically: true, encoding: .utf8)
        usage.refreshIfNeeded()
        XCTAssertFalse(usage.isScanning)
        XCTAssertEqual(usage.tokens?.today.total, 57)
    }

    func testLimitsPersistAndExpire() {
        let store = defaults()
        let usage = ClaudeUsage(defaults: store)
        let now = Date()
        usage.record(rateLimitInfo: ["unifiedWindows": [
            "five_hour": ["utilization": 0.5, "resets_at": now.addingTimeInterval(600).timeIntervalSince1970],
            "seven_day": ["utilization": NSNumber(value: 1), "resetsAt": Int(now.addingTimeInterval(86400).timeIntervalSince1970)],
        ]], at: now)
        let reloaded = ClaudeUsage(defaults: store).limits
        XCTAssertEqual(reloaded?.fiveHour?.utilization, 0.5, "limits are kept across launches")
        XCTAssertEqual(reloaded?.sevenDay?.resetsAt?.timeIntervalSince1970 ?? 0,
                       usage.limits?.sevenDay?.resetsAt?.timeIntervalSince1970 ?? 1, accuracy: 0.01)
        XCTAssertEqual(usage.limits?.sevenDay?.utilization, 1)

        // Windows past their reset time are dropped; unknown types and bad values change nothing.
        usage.record(rateLimitInfo: ["rateLimitType": "overage", "utilization": 0.9], at: now.addingTimeInterval(700))
        XCTAssertNil(usage.limits?.fiveHour)
        XCTAssertNotNil(usage.limits?.sevenDay)
        usage.record(rateLimitInfo: ["rateLimitType": "seven_day", "utilization": "high"], at: now.addingTimeInterval(800))
        XCTAssertEqual(usage.limits?.sevenDay?.utilization, 1)
        usage.record(rateLimitInfo: ["rateLimitType": "seven_day", "utilization": 0.2], at: now.addingTimeInterval(900))
        XCTAssertEqual(usage.limits?.sevenDay?.utilization, 0.2)
        XCTAssertNil(usage.limits?.sevenDay?.resetsAt)
    }

    func testScannerRecountsRewrittenFilesAndForgetsOldOrDeletedOnes() throws {
        let root = try makeTemporaryDirectory()
        let file = root.appendingPathComponent("p/a.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let now = Date()
        try [line(id: "old", at: now.addingTimeInterval(-3 * 86400)), line(id: "new", at: now), line(id: "synthetic", at: now, model: "<synthetic>"),
             #"{"type":"assistant","usage":1,"timestamp":"not a date","message":{"usage":{}}}"#]
            .joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
        let scanner = TranscriptScanner(root: root, window: 86400 * 7)
        XCTAssertEqual(scanner.scan(now: now).map(\.key).sorted(), ["new:r", "old:r"])

        // Records fall out of the window as time passes.
        XCTAssertEqual(scanner.scan(now: now.addingTimeInterval(5 * 86400)).map(\.key), ["new:r"])

        // A rewritten (shorter) file is read again from the start.
        try line(id: "new", at: now).appending("\n").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(scanner.scan(now: now).map(\.key), ["new:r"])

        // A deleted file's records go, and their keys can be counted again later.
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(scanner.scan(now: now).isEmpty)
        try line(id: "new", at: now).appending("\n").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(scanner.scan(now: now).count, 1)

        // Files not modified within the window are skipped entirely.
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30 * 86400)], ofItemAtPath: file.path)
        XCTAssertTrue(scanner.scan(now: now).isEmpty)
    }

    func testTokenStatsEquality() {
        var a = ClaudeUsage.TokenStats()
        var b = ClaudeUsage.TokenStats()
        XCTAssertEqual(a, b)
        a.modelsToday = [("opus", 1)]
        XCTAssertNotEqual(a, b)
        b.modelsToday = [("opus", 2)]
        XCTAssertNotEqual(a, b)
        b.modelsToday = [("opus", 1)]
        XCTAssertEqual(a, b)
        XCTAssertEqual(ClaudeUsage.DayTotal(day: Date(timeIntervalSince1970: 0), tokens: 1).id, Date(timeIntervalSince1970: 0))
    }
}

// MARK: - Past sessions

@MainActor
final class ClaudeHistoryRefreshTests: XCTestCase {
    private let id = "0f6c8d3e-1b2a-4c5d-8e9f-0a1b2c3d4e5f"

    private func user(_ text: Any, cwd: String = "/Users/me/code/repo") -> String {
        let obj: [String: Any] = ["type": "user", "cwd": cwd, "gitBranch": "main", "message": ["content": text]]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    func testRefreshLoadsSessionsInTheBackground() throws {
        let root = try makeTemporaryDirectory()
        let project = root.appendingPathComponent("-Users-me-code-repo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try (user([["type": "image"], ["type": "text", "text": "<system-reminder>x</system-reminder>"], ["type": "text", "text": "fix the login"]]) + "\n")
            .write(to: project.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)

        let history = ClaudeHistory(index: ClaudeTranscriptIndex(root: root))
        history.refresh()
        XCTAssertTrue(history.isLoading)
        history.refresh(force: true) // already loading
        XCTAssertTrue(waitUntil { !history.isLoading })
        XCTAssertEqual(history.sessions.map(\.title), ["fix the login"])
        XCTAssertEqual(history.sessions.first?.branch, "main")

        // A recent scan isn't repeated unless forced.
        try FileManager.default.removeItem(at: project.appendingPathComponent("\(id).jsonl"))
        history.refresh()
        XCTAssertFalse(history.isLoading)
        XCTAssertEqual(history.sessions.count, 1)
        history.refresh(force: true)
        XCTAssertTrue(waitUntil { !history.isLoading })
        XCTAssertTrue(history.sessions.isEmpty)
        _ = ClaudeHistory.isClaudeAvailable
    }

    func testLargeTranscriptsAreReadFromBothEnds() throws {
        let root = try makeTemporaryDirectory()
        let file = root.appendingPathComponent("\(id).jsonl")
        let filler = #"{"type":"progress","data":""# + String(repeating: "x", count: 1000) + #""}"#
        var lines = [user("first prompt")]
        lines += Array(repeating: filler, count: 200) // well over two 64 KB chunks
        lines.append(#"{"type":"custom-title","customTitle":"Renamed at the end"}"#)
        lines.append(#"{"type":"user","cwd":"/Users/me/code/repo","gitBranch":"feature/x","message":{"content":"later"}}"#)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        XCTAssertGreaterThan(size, ClaudeTranscriptIndex.chunk * 2)

        let session = try XCTUnwrap(ClaudeTranscriptIndex.summarize(file, size: size, modified: Date()))
        XCTAssertEqual(session.title, "Renamed at the end")
        XCTAssertEqual(session.prompt, "first prompt")
        XCTAssertEqual(session.branch, "feature/x")

        XCTAssertNil(ClaudeTranscriptIndex.summarize(root.appendingPathComponent("not-an-id.jsonl"), size: 0, modified: Date()))
        XCTAssertNil(ClaudeTranscriptIndex.summarize(root.appendingPathComponent("\(UUID().uuidString.lowercased()).jsonl"), size: 0, modified: Date()),
                     "a missing file has no session")
    }

    func testPromptsFromBlocksAndOneLineTitles() {
        let head = Data((user([["type": "text", "text": "<local-command-stdout>x</local-command-stdout>"]]) + "\n"
            + user(42) + "\n" + user("  \n") + "\n").utf8)
        XCTAssertNil(ClaudeTranscriptIndex.parse(id: id, head: head, tail: Data(), modified: Date()),
                     "nothing to call the session without a prompt or title")
        XCTAssertEqual(ClaudeTranscriptIndex.oneLine(String(repeating: "a", count: 200)).count, 141)
        XCTAssertEqual(ClaudeTranscriptIndex.oneLine("first\nsecond"), "first")
    }
}

// MARK: - Diffs of tool input

final class ClaudeDiffToolInputTests: XCTestCase {
    func testEditNumbersLinesFromTheFile() throws {
        let file = try makeTemporaryDirectory().appendingPathComponent("a.swift")
        try "one\ntwo\nthree\nfour\n".write(to: file, atomically: true, encoding: .utf8)
        let input: [String: Any] = ["file_path": file.path, "old_string": "three", "new_string": "THREE"]
        let lines = try XCTUnwrap(ClaudeDiff.lines(tool: "Edit", input: input))
        XCTAssertEqual(lines.map(\.kind), [.removed, .added])
        XCTAssertEqual(lines.first?.oldNumber, 3)
        XCTAssertEqual(ClaudeDiff.lines(tool: "Edit", input: input), lines, "cached")

        let missing = try XCTUnwrap(ClaudeDiff.lines(tool: "Edit", input: ["file_path": "/no/such/file", "old_string": "a"]))
        XCTAssertEqual(missing.first?.oldNumber, 1, "without the file, lines count from 1")
        XCTAssertEqual(ClaudeDiff.lines(tool: "Edit", input: [:])?.map(\.kind), [.context])
    }

    func testMultiEditSeparatesEditsAndWriteShowsTheFile() throws {
        let multi = try XCTUnwrap(ClaudeDiff.lines(tool: "MultiEdit", input: ["edits": [
            ["old_string": "a", "new_string": "b"], ["old_string": "c", "new_string": "d"],
        ]]))
        XCTAssertEqual(multi.map(\.kind), [.removed, .added, .gap, .removed, .added])
        XCTAssertEqual(ClaudeDiff.lines(tool: "MultiEdit", input: [:]), [])

        let content = (1...500).map(String.init).joined(separator: "\n")
        let write = try XCTUnwrap(ClaudeDiff.lines(tool: "Write", input: ["content": content]))
        XCTAssertEqual(write.count, 400, "long files are cut off")
        XCTAssertEqual(write.last?.newNumber, 400)
        XCTAssertEqual(ClaudeDiff.lines(tool: "Write", input: [:])?.count, 1)
        XCTAssertNil(ClaudeDiff.lines(tool: "Read", input: [:]))
    }
}

// MARK: - Attachments

final class ClaudeAttachmentFileTests: XCTestCase {
    private func image(width: Int, height: Int, alpha: Bool) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: alpha ? 4 : 3, hasAlpha: alpha, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    func testImageFilesAreInlinedAndOtherFilesReferenced() throws {
        let dir = try makeTemporaryDirectory()
        let png = dir.appendingPathComponent("shot.png")
        try image(width: 20, height: 10, alpha: false).write(to: png)
        let text = dir.appendingPathComponent("notes.txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)

        let attached = try XCTUnwrap(ClaudeAttachment.load(png))
        XCTAssertTrue(attached.isImage)
        XCTAssertNotNil(attached.thumbnail)
        XCTAssertEqual(attached.byteCount, Int64(try Data(contentsOf: png).count))
        let sent = attached.withoutImageData()
        XCTAssertEqual(sent, attached, "the same attachment, by identity")
        guard case .image(let data, let type) = sent.kind else { return XCTFail("still an image") }
        XCTAssertTrue(data.isEmpty)
        XCTAssertEqual(type, "image/png")
        XCTAssertEqual(sent.byteCount, Int64(try Data(contentsOf: png).count), "falls back to the file's size")

        let file = try XCTUnwrap(ClaudeAttachment.load(text))
        XCTAssertFalse(file.isImage)
        XCTAssertEqual(file.withoutImageData().kind, .file)
        XCTAssertEqual(file.byteCount, 5)
        XCTAssertNotEqual(file, ClaudeAttachment.load(text), "every attachment is distinct")
        XCTAssertNil(ClaudeAttachment.load(dir.appendingPathComponent("missing.png")))
        XCTAssertFalse(try XCTUnwrap(ClaudeAttachment.load(dir)).isImage, "folders are referenced")
    }

    func testHistoryImagesAreWrittenOnce() throws {
        let data = image(width: 4, height: 4, alpha: true)
        let first = try XCTUnwrap(ClaudeAttachment.historyImage(data, type: .png))
        let second = try XCTUnwrap(ClaudeAttachment.historyImage(data, type: .png))
        XCTAssertEqual(first.url, second.url, "the same image maps to the same file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertEqual(first.name, "Image")
        guard case .image(let kept, let type) = first.kind else { return XCTFail("an image") }
        XCTAssertTrue(kept.isEmpty, "only the thumbnail stays in memory")
        XCTAssertEqual(type, "image/png")
        XCTAssertNotNil(first.thumbnail)
    }

    func testStaleScratchFilesAreRemoved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ShellAttachments", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stale = dir.appendingPathComponent("stale-\(UUID().uuidString).png")
        let fresh = dir.appendingPathComponent("fresh-\(UUID().uuidString).png")
        try Data([1]).write(to: stale)
        try Data([1]).write(to: fresh)
        addTeardownBlock { try? FileManager.default.removeItem(at: fresh) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 86400)], ofItemAtPath: stale.path)
        ClaudeAttachment.removeStaleFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testLargeTransparentImagesStayPNG() throws {
        let out = try XCTUnwrap(ClaudeAttachment.encodeForAPI(image(width: 2400, height: 200, alpha: true), type: .png))
        XCTAssertEqual(out.mediaType, "image/png")
        XCTAssertNil(ClaudeAttachment.encodeForAPI(Data("not an image".utf8), type: .png))
    }

    @MainActor
    func testATextOnlyPasteboardAttachesNothing() {
        let pb = NSPasteboard(name: NSPasteboard.Name("ShellTests-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("just text", forType: .string)
        XCTAssertTrue(ClaudeAttachment.from(pasteboard: pb).isEmpty)
        pb.clearContents()
        pb.setData(Data("garbage".utf8), forType: .png)
        XCTAssertTrue(ClaudeAttachment.from(pasteboard: pb).isEmpty, "undecodable image data attaches nothing")
    }
}
