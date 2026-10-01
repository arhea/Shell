import AppKit
import SwiftUI
import XCTest
@testable import Shell

/// Builds `ClaudeCodeSession`s in a given state by feeding them the
/// stream-json messages `claude` would send. Nothing is launched: without a
/// process, writes to its stdin are dropped.
@MainActor
enum ClaudeViewFixtures {
    static var palette: ClaudePalette { .current }

    /// Model, effort and mode are explicit so settings (whose default mode is auto) don't leak in.
    static func session(directory: String = NSTemporaryDirectory(),
                        arguments: ClaudeArguments = ClaudeArguments(model: "default", effort: "", permissionMode: "default"),
                        binary: String = "/usr/bin/false") -> ClaudeCodeSession {
        ClaudeCodeSession(request: ClaudeLaunchRequest(directory: directory, binary: binary, arguments: arguments, environment: [:]))
    }

    static func systemInit(_ claude: ClaudeCodeSession, model: String = "claude-opus-5-5", mode: String? = nil,
                           skills: [String] = [], agents: [String] = [], mcp: [(String, String)] = [], slash: [String] = []) {
        var msg: [String: Any] = [
            "type": "system", "subtype": "init", "session_id": "session-1", "model": model,
            "mcp_servers": mcp.map { ["name": $0.0, "status": $0.1] }, "skills": skills, "agents": agents, "slash_commands": slash,
        ]
        if let mode { msg["permissionMode"] = mode }
        claude.handle(msg)
    }

    static func commands(_ claude: ClaudeCodeSession, _ list: [(name: String, description: String, hint: String)]) {
        claude.handle(["type": "system", "subtype": "commands_changed",
                       "commands": list.map { ["name": $0.name, "description": $0.description, "argumentHint": $0.hint] }])
    }

    static func assistantText(_ claude: ClaudeCodeSession, _ text: String, id: String = UUID().uuidString,
                              usage: [String: Int]? = nil, model: String? = nil) {
        var message: [String: Any] = ["id": id, "content": [["type": "text", "text": text]]]
        if let usage { message["usage"] = usage }
        if let model { message["model"] = model }
        claude.handle(["type": "assistant", "parent_tool_use_id": NSNull(), "message": message])
    }

    static func thinking(_ claude: ClaudeCodeSession, _ text: String, finished: Bool) {
        claude.handle(["type": "stream_event", "parent_tool_use_id": NSNull(), "event": ["type": "message_start", "message": ["id": UUID().uuidString]]])
        claude.handle(["type": "stream_event", "parent_tool_use_id": NSNull(),
                       "event": ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking"]]])
        claude.handle(["type": "stream_event", "parent_tool_use_id": NSNull(),
                       "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": text]]])
        if finished {
            claude.handle(["type": "stream_event", "parent_tool_use_id": NSNull(), "event": ["type": "content_block_stop", "index": 0]])
        }
    }

    static func tool(_ claude: ClaudeCodeSession, id: String, name: String, input: [String: Any]) {
        claude.handle(["type": "assistant", "parent_tool_use_id": NSNull(),
                       "message": ["id": UUID().uuidString, "content": [["type": "tool_use", "id": id, "name": name, "input": input]]]])
    }

    static func toolResult(_ claude: ClaudeCodeSession, id: String, content: String, isError: Bool = false, structured: Any? = nil) {
        var msg: [String: Any] = ["type": "user", "parent_tool_use_id": NSNull(),
                                  "message": ["content": [["type": "tool_result", "tool_use_id": id, "content": content, "is_error": isError]]]]
        if let structured { msg["tool_use_result"] = structured }
        claude.handle(msg)
    }

    static func permission(_ claude: ClaudeCodeSession, id: String = "req-1", tool: String, input: [String: Any],
                           description: String? = nil, suggestions: [Any] = [], reason: String? = nil, toolUseID: String? = nil) {
        var req: [String: Any] = ["subtype": "can_use_tool", "tool_name": tool, "input": input, "permission_suggestions": suggestions]
        if let description { req["description"] = description }
        if let reason { req["decision_reason"] = reason }
        if let toolUseID { req["tool_use_id"] = toolUseID }
        claude.handle(["type": "control_request", "request_id": id, "request": req])
    }

    static func controlResponse(_ claude: ClaudeCodeSession, id: String, response: [String: Any]? = nil, error: String? = nil) {
        if let error {
            claude.handle(["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": error]])
        } else {
            claude.handle(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": response ?? [:]]])
        }
    }

    /// Signs the session out the way a failed turn does.
    static func signOut(_ claude: ClaudeCodeSession) {
        claude.handle(["type": "assistant", "error": "authentication_failed", "parent_tool_use_id": NSNull(),
                       "message": ["id": "m-auth", "model": "<synthetic>", "content": [["type": "text", "text": "Not logged in · Please run /login"]]]])
        claude.handle(["type": "result", "subtype": "success", "is_error": true, "result": "Not logged in · Please run /login"])
    }

    static func questionInput(_ questions: [(question: String, header: String, options: [(String, String, String?)], multi: Bool)]) -> [String: Any] {
        ["questions": questions.map { q in
            ["question": q.question, "header": q.header, "multiSelect": q.multi,
             "options": q.options.map { o -> [String: Any] in
                 var d: [String: Any] = ["label": o.0, "description": o.1]
                 if let p = o.2 { d["preview"] = p }
                 return d
             }] as [String: Any]
        }]
    }

    static func request(id: String = "req-1", tool: String, input: [String: Any], description: String? = nil,
                        suggestions: [Any] = [], reason: String? = nil) -> ClaudePermissionRequest {
        ClaudePermissionRequest(id: id, toolName: tool, displayName: tool, input: input, description: description,
                                suggestions: suggestions, reason: reason, toolUseID: nil)
    }

    static func item(_ kind: ClaudeItem.Kind, text: String = "", tool: String = "", input: [String: Any]? = nil,
                     result: String? = nil, isError: Bool = false, isRunning: Bool = false) -> ClaudeItem {
        let item = ClaudeItem(kind: kind, text: text)
        item.toolName = tool
        if let input { item.setInput(input) }
        item.result = result
        item.isError = isError
        item.isRunning = isRunning
        return item
    }

    /// A small PNG on disk.
    static func writePNG(to url: URL, width: Int = 40, height: Int = 20) throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }
}

/// Borderless windows can't become key unless they say so.
final class ClaudeTestKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Hosts a SwiftUI view in an offscreen borderless window so tests can click it.
@MainActor
final class ClaudeViewWindow<V: View> {
    let window: NSWindow
    let host: NSHostingView<V>
    private(set) var size: CGSize

    /// `size` nil fits the window to the view.
    init(_ view: V, width: CGFloat = 640, height: CGFloat? = nil) {
        host = NSHostingView(rootView: view)
        let fitted = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 10_000))
        size = CGSize(width: width, height: height ?? max(ceil(fitted.height), 20))
        window = ClaudeTestKeyWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        layout()
        size = host.bounds.size
    }

    func layout(settle: TimeInterval = 0.005) {
        host.layoutSubtreeIfNeeded()
        host.display()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
    }

    /// SwiftUI's stand-ins for its focusable controls (buttons, toggles,
    /// text fields) in the key-view loop, in reading order.
    func controls() -> [NSView] {
        // The proxies are only rebuilt with the key-view loop (e.g. after a
        // disabled button becomes enabled).
        layout(settle: 0.02)
        window.recalculateKeyViewLoop()
        layout(settle: 0.02)
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        // New proxies are appended, so sort into reading order.
        return all(host).filter { String(describing: Swift.type(of: $0)).contains("KeyViewProxy") }
            .sorted { a, b in abs(a.frame.minY - b.frame.minY) > 2 ? a.frame.minY < b.frame.minY : a.frame.minX < b.frame.minX }
    }

    /// Presses the `index`th focusable control with the keyboard (focus, then
    /// Space), which works for every button style, unlike synthesized clicks.
    func press(_ index: Int, file: StaticString = #filePath, line: UInt = #line) {
        let list = controls()
        guard list.indices.contains(index) else { return XCTFail("no control \(index); there are \(list.count)", file: file, line: line) }
        window.makeFirstResponder(list[index])
        layout(settle: 0.02) // SwiftUI moves its focus on the next turn of the run loop
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                                            isARepeat: false, keyCode: 49) {
                window.sendEvent(event)
            }
        }
        layout(settle: 0.02)
    }

    /// Presses every focusable control in order.
    func pressAll() {
        for i in controls().indices { press(i) }
    }

    /// SwiftUI toggles are AppKit controls (checkboxes and switches), not
    /// key-view stand-ins; these are they, top to bottom.
    func toggles() -> [NSControl] {
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        return all(host).compactMap { $0 as? NSControl }.filter { $0 is NSButton || $0 is NSSwitch }
            .sorted { $0.convert($0.bounds, to: host).minY < $1.convert($1.bounds, to: host).minY }
    }

    /// Clicks a toggle with the mouse (SwiftUI doesn't hear `performClick`).
    func flip(_ toggle: NSControl) {
        let r = toggle.convert(toggle.bounds, to: host)
        click(x: r.midX, y: r.midY)
        layout(settle: 0.02)
    }

    /// The first AppKit subview of type `T`.
    func subview<T: NSView>(_ type: T.Type) -> T? {
        func find(_ v: NSView) -> T? {
            if let t = v as? T { return t }
            for s in v.subviews { if let t = find(s) { return t } }
            return nil
        }
        return find(host)
    }

    /// Types into `field` through its field editor, as the user would.
    func type(_ text: String, into field: NSTextField) {
        window.makeFirstResponder(field)
        (window.firstResponder as? NSTextView)?.insertText(text, replacementRange: NSRange(location: 0, length: 0))
        layout()
    }

    /// Clicks at a point measured from the view's top-left corner.
    func click(x: CGFloat, y: CGFloat) {
        let point = host.convert(NSPoint(x: x, y: y), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        // Controls that track the mouse read the mouse-up from the queue, so
        // it has to be there before the mouse-down is handled.
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
        // Nothing tracked it: deliver the mouse-up straight to the window too.
        if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            window.sendEvent(queued)
        }
        layout()
    }

    /// Moves the mouse to a point measured from the top-left corner.
    func hover(x: CGFloat, y: CGFloat) {
        let point = host.convert(NSPoint(x: x, y: y), to: nil)
        if let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            window.sendEvent(event)
        }
        layout()
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
}

extension XCTestCase {
    /// A window for `view`, closed when the test ends.
    @MainActor
    func claudeWindow<V: View>(_ view: V, width: CGFloat = 640, height: CGFloat? = nil) -> ClaudeViewWindow<V> {
        let w = ClaudeViewWindow(view, width: width, height: height)
        addTeardownBlock { @MainActor in w.close() }
        return w
    }
}
