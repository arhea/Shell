import AppKit
import SwiftUI

/// The commit message field: plain text with the first line (the subject)
/// in bold, and a placeholder. Reports focus so the view's shortcuts stay on.
struct ReviewCommitEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder = "Summary of the change\n\nWhy it changed (optional)"
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let tv = CommitTextView()
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.textContainerInset = NSSize(width: 5, height: 8)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.delegate = context.coordinator
        tv.placeholder = placeholder
        tv.onFocusChange = { focused in context.coordinator.parent.onFocusChange(focused) }
        tv.setAccessibilityLabel("Commit message")
        scroll.documentView = tv
        tv.string = text
        Self.style(tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        tv.string = text
        Self.style(tv)
    }

    static let bodyFont = NSFont.systemFont(ofSize: DS.Size.body)
    static let subjectFont = NSFont.systemFont(ofSize: DS.Size.body, weight: .semibold)
    /// About 1.5× line height, as in the design.
    static let paragraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 3.5
        return p
    }()

    /// Bold subject line, regular body.
    static func style(_ tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let ns = tv.string as NSString
        let all = NSRange(location: 0, length: ns.length)
        let firstLine = ns.lineRange(for: NSRange(location: 0, length: 0))
        storage.beginEditing()
        storage.addAttributes([.font: bodyFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph], range: all)
        if firstLine.length > 0 { storage.addAttributes([.font: subjectFont, .foregroundColor: NSColor.labelColor], range: firstLine) }
        storage.endEditing()
        // Restyled after every change, so the typing font only matters for the next character.
        let inSubject = tv.selectedRange().location < firstLine.upperBound || !ns.contains("\n")
        tv.typingAttributes = [.font: inSubject ? subjectFont : bodyFont, .paragraphStyle: paragraph,
                               .foregroundColor: inSubject ? NSColor.labelColor : NSColor.secondaryLabelColor]
        tv.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ReviewCommitEditor
        init(_ parent: ReviewCommitEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            ReviewCommitEditor.style(tv)
            parent.text = tv.string
        }
    }
}

/// An NSTextView with a placeholder and focus callbacks.
final class CommitTextView: NSTextView {
    var placeholder = ""
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: ReviewCommitEditor.bodyFont, .foregroundColor: NSColor.placeholderTextColor]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5), y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: attrs)
    }
}
