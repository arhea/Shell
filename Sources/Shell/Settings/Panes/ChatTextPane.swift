import AppKit
import SwiftUI

/// Settings › Chat Text: fonts and spacing for the native Claude view, in the
/// spirit of VS Code's chat font settings.
struct ChatTextSettingsPane: View {
    @State private var families: [String] = []
    @State private var monospaced: [String] = []

    var body: some View {
        let s = SettingsStore.shared.settings
        let t = ChatTypography.from(s)
        Form {
            Section {
                Picker("Font family", selection: setting(\.chatFontFamily)) {
                    Text("System (SF Pro)").tag("")
                    Divider()
                    ForEach(families, id: \.self) { Text($0).tag($0) }
                }
                NumberRow(title: "Font size", key: "chatFontSize", value: setting(\.chatFontSize), range: 9...32, step: 0.5,
                          unit: "pt", automatic: String(format: "%g pt, terminal + 1", Double(t.size)))
                SliderRow(title: "Line height", key: "chatLineHeight", value: setting(\.chatLineHeight), range: 1.0...2.4, step: 0.05,
                          format: "%.2f×", defaultValue: 1.6)
                SliderRow(title: "Letter spacing", key: "chatLetterSpacing", value: setting(\.chatLetterSpacing), range: -0.5...2, step: 0.1,
                          format: "%.1f pt", defaultValue: 0)
                SliderRow(title: "Paragraph spacing", key: "chatParagraphSpacing", value: setting(\.chatParagraphSpacing), range: 0...2.5,
                          step: 0.1, format: "%.1f×", defaultValue: 1)
            } header: {
                Text("Text")
            } footer: {
                Text("Replies, your messages and the composer in the native Claude view. Line height and paragraph spacing are multiples of the font size.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Code") {
                Picker("Font family", selection: setting(\.chatCodeFontFamily)) {
                    Text("Terminal font (\(s.fontFamily.isEmpty ? "JetBrains Mono" : s.fontFamily))").tag("")
                    Divider()
                    ForEach(monospaced, id: \.self) { Text($0).tag($0) }
                }
                NumberRow(title: "Font size", key: "chatCodeFontSize", value: setting(\.chatCodeFontSize), range: 8...30, step: 0.5,
                          unit: "pt", automatic: String(format: "%g pt, text − 1.5", Double(t.codeSize)))
            }

            Section {
                Picker(selection: setting(\.chatComposerWidth)) {
                    ForEach(ChatComposerWidth.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Composer width").help("settings.json: chatComposerWidth")
                }
                Toggle("Limit the reading width", isOn: Binding(
                    get: { SettingsStore.shared.settings.chatMaxWidth > 0 },
                    set: { SettingsStore.shared.settings.chatMaxWidth = $0 ? AppSettings().chatMaxWidth : 0 }))
                if s.chatMaxWidth > 0 {
                    SliderRow(title: "Maximum width", key: "chatMaxWidth", value: setting(\.chatMaxWidth), range: 480...1600, step: 20,
                              format: "%.0f pt", defaultValue: AppSettings().chatMaxWidth)
                    Text("About \(Int(s.chatMaxWidth / (t.size * 0.5))) characters per line at this size. Long lines are harder to follow; 60–100 characters is comfortable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Layout")
            } footer: {
                Text("Centered keeps the composer and transcript in a column up to \(Int(ChatComposerWidth.centeredMaxWidth)) pt wide; Full width fills the pane. The reading width limits transcript text within that column.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Preview") {
                MarkdownView(text: Self.sample, palette: ClaudePalette.current, fontSize: t.size)
                    .padding(14)
                    .frame(maxWidth: t.maxWidth ?? .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(ClaudePalette.current.background))
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { Self.restoreDefaults() }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            let (all, mono) = await Task.detached {
                let names = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }.sorted()
                let mono = names.filter { family in
                    guard let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12) else { return false }
                    return font.isFixedPitch || family.localizedCaseInsensitiveContains("mono") || family.localizedCaseInsensitiveContains("code")
                }
                return (names, mono)
            }.value
            families = all
            monospaced = mono
        }
    }

    static func restoreDefaults() {
        let d = AppSettings()
        var s = SettingsStore.shared.settings
        s.chatFontFamily = d.chatFontFamily
        s.chatFontSize = d.chatFontSize
        s.chatLineHeight = d.chatLineHeight
        s.chatLetterSpacing = d.chatLetterSpacing
        s.chatParagraphSpacing = d.chatParagraphSpacing
        s.chatCodeFontFamily = d.chatCodeFontFamily
        s.chatCodeFontSize = d.chatCodeFontSize
        s.chatMaxWidth = d.chatMaxWidth
        s.chatComposerWidth = d.chatComposerWidth
        SettingsStore.shared.settings = s
    }

    static let sample = """
    Boundary check-ins were landing in the **previous** shift, so the facility dashboard double-counted indirect time. The fix changes `ShiftWindow.contains` to include the start time:

    - Compare with `>=` so a 06:00 check-in belongs to the new shift
    - Backfill the last 30 days of time cards

    ```go
    return !t.Before(w.Start) && t.Before(w.End)
    ```
    """
}

/// A number with a stepper; 0 means "automatic".
private struct NumberRow: View {
    let title: String
    let key: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let automatic: String

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if value > 0 {
                    TextField("", value: $value, format: .number.precision(.fractionLength(0...1)))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 52)
                    Text(unit).foregroundStyle(.secondary)
                    Stepper("", value: $value, in: range, step: step).labelsHidden()
                    Button("Auto") { value = 0 }.controlSize(.small)
                } else {
                    Text("Automatic (\(automatic))").foregroundStyle(.secondary)
                    Button("Set…") { value = Double(automatic.prefix { $0.isNumber || $0 == "." }) ?? range.lowerBound }
                        .controlSize(.small)
                }
            }
        } label: {
            Text(title).help("settings.json: \(key)")
        }
    }
}

/// A slider with its value and a reset-to-default button.
private struct SliderRow: View {
    let title: String
    let key: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String
    let defaultValue: Double

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Slider(value: $value, in: range, step: step) { EmptyView() }
                Text(String(format: format, value)).monospacedDigit().frame(width: 58, alignment: .trailing)
                Button { value = defaultValue } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .disabled(abs(value - defaultValue) < step / 2)
                    .help("Reset to \(String(format: format, defaultValue))")
            }
        } label: {
            Text(title).help("settings.json: \(key)")
        }
    }
}
