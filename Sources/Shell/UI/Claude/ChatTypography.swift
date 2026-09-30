import AppKit
import SwiftUI

/// Fonts and spacing for the native Claude view, from Settings › Chat Text.
struct ChatTypography: Equatable {
    var family: String
    var size: CGFloat
    var lineHeight: CGFloat
    var letterSpacing: CGFloat
    var paragraphSpacing: CGFloat
    var codeFamily: String
    var codeSize: CGFloat
    /// Reading width of transcript text (nil = the whole column).
    var maxWidth: CGFloat?
    /// Width of the chat column the composer fills (nil = the full pane).
    var columnWidth: CGFloat?

    /// System text is about 1.2× its size tall; the rest of the line height
    /// becomes extra spacing between lines.
    static let naturalLineHeight: CGFloat = 1.2

    var lineSpacing: CGFloat { max(0, ((lineHeight - Self.naturalLineHeight) * size).rounded()) }
    var blockSpacing: CGFloat { (size * paragraphSpacing).rounded() }

    /// Read through `ChatPreferences`, so chat views only re-render when a
    /// chat setting changes, not on every settings write.
    @MainActor
    static var current: ChatTypography { ChatPreferences.shared.typography }

    static func from(_ s: AppSettings) -> ChatTypography {
        let terminal = CGFloat(s.editorFontSize > 0 ? s.editorFontSize : s.fontSize)
        // Proportional text reads smaller than the terminal's monospaced font at the same size.
        let size = s.chatFontSize > 0 ? CGFloat(s.chatFontSize) : terminal + 1
        return ChatTypography(
            family: s.chatFontFamily, size: size,
            lineHeight: CGFloat(min(max(s.chatLineHeight, 1), 3)),
            letterSpacing: CGFloat(s.chatLetterSpacing),
            paragraphSpacing: CGFloat(max(s.chatParagraphSpacing, 0)),
            codeFamily: s.chatCodeFontFamily.isEmpty ? s.fontFamily : s.chatCodeFontFamily,
            codeSize: s.chatCodeFontSize > 0 ? CGFloat(s.chatCodeFontSize) : size - 1.5,
            maxWidth: s.chatMaxWidth > 0 ? CGFloat(s.chatMaxWidth) : nil,
            columnWidth: s.chatComposerWidth == .centered ? ChatComposerWidth.centeredMaxWidth : nil)
    }

    /// This typography at another base size (cards and captions scale with it).
    func scaled(to newSize: CGFloat) -> ChatTypography {
        var t = self
        t.codeSize = codeSize + (newSize - size)
        t.size = newSize
        return t
    }

    func font(size: CGFloat? = nil, weight: Font.Weight = .regular) -> Font {
        let s = size ?? self.size
        guard !family.isEmpty else { return .system(size: s, weight: weight) }
        return Font.custom(family, size: s).weight(weight)
    }

    func nsFont(size: CGFloat? = nil) -> NSFont {
        let s = size ?? self.size
        guard !family.isEmpty,
              let f = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: s) ?? NSFont(name: family, size: s)
        else { return .systemFont(ofSize: s) }
        return f
    }

    @MainActor
    func codeFont(size: CGFloat? = nil) -> Font {
        Font(InputEditorView.font(family: codeFamily, size: size ?? codeSize))
    }
}

/// The settings the native Claude view renders with, published separately
/// from `SettingsStore.settings`. Views that read the whole settings struct
/// re-render on any change (switching a sidebar tab, picking a model); these
/// properties only change when their own values do.
@MainActor
@Observable
final class ChatPreferences {
    static let shared = ChatPreferences()

    private(set) var typography: ChatTypography
    private(set) var toolCalls: ToolCallDisplay
    private(set) var diffStyle: DiffStyle

    private init() {
        let s = SettingsStore.shared.settings
        typography = .from(s)
        toolCalls = s.claudeToolCalls
        diffStyle = s.claudeDiffStyle
        SettingsStore.shared.observe { _, new in
            MainActor.assumeIsolated { ChatPreferences.shared.apply(new) }
        }
    }

    private func apply(_ s: AppSettings) {
        let t = ChatTypography.from(s)
        if t != typography { typography = t }
        if s.claudeToolCalls != toolCalls { toolCalls = s.claudeToolCalls }
        if s.claudeDiffStyle != diffStyle { diffStyle = s.claudeDiffStyle }
    }
}
