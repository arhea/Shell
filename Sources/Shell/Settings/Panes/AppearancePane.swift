import AppKit
import SwiftUI

struct AppearanceSettingsPane: View {
    @State private var editingDark = ConfigController.shared.isDark
    @State private var search = ""

    var body: some View {
        let s = SettingsStore.shared.settings
        let library = ThemeLibrary.shared
        let selectedName = editingDark ? s.darkTheme : s.lightTheme
        Form {
            Section {
                Picker("Editing theme for", selection: $editingDark) {
                    Label("Light mode", systemImage: "sun.max").tag(false)
                    Label("Dark mode", systemImage: "moon").tag(true)
                }
                .pickerStyle(.segmented)
                HStack(spacing: 16) {
                    ThemeCard(theme: library.resolved(dark: false, settings: s), label: "Light: \(s.lightTheme)", selected: !editingDark)
                        .onTapGesture { editingDark = false }
                    ThemeCard(theme: library.resolved(dark: true, settings: s), label: "Dark: \(s.darkTheme)", selected: editingDark)
                        .onTapGesture { editingDark = true }
                }
            }

            Section("Theme (\(library.themes.count) available)") {
                TextField("Search themes", text: $search)
                    .textFieldStyle(.roundedBorder)
                let filtered = library.themes.filter {
                    (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) && (search.isEmpty ? $0.isDark == editingDark : true)
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        ForEach(filtered) { theme in
                            ThemeTile(theme: theme, selected: theme.name == selectedName)
                                .onTapGesture {
                                    if editingDark {
                                        SettingsStore.shared.settings.darkTheme = theme.name
                                    } else {
                                        SettingsStore.shared.settings.lightTheme = theme.name
                                    }
                                }
                        }
                    }
                    .padding(2)
                }
                .frame(height: 260)
                if search.isEmpty {
                    Text("Showing \(editingDark ? "dark" : "light") themes. Search to see all.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            ColorOverridesSection(dark: editingDark)

            Section("Window") {
                LabeledContent("Background opacity") {
                    Slider(value: setting(\.backgroundOpacity), in: 0.5...1, step: 0.01) { EmptyView() }
                    Text("\(Int(s.backgroundOpacity * 100))%").monospacedDigit().frame(width: 44)
                }
                Toggle("Blur behind translucent windows", isOn: setting(\.backgroundBlur))
                    .disabled(s.backgroundOpacity >= 1)
                LabeledContent("Minimum contrast") {
                    Slider(value: setting(\.minimumContrast), in: 1...7, step: 0.5) { EmptyView() }
                    Text(String(format: "%.1f", s.minimumContrast)).monospacedDigit().frame(width: 44)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ThemeCard: View {
    let theme: TerminalTheme
    let label: String
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                (Text("~ ").foregroundColor(Color(nsColor: theme.palette[4].nsColor))
                    + Text("❯ ").foregroundColor(Color(nsColor: theme.palette[2].nsColor))
                    + Text("ls -la").foregroundColor(Color(nsColor: theme.foreground.nsColor)))
                HStack(spacing: 3) {
                    ForEach(0..<8, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: theme.palette[i].nsColor)).frame(width: 14, height: 10)
                    }
                }
                HStack(spacing: 3) {
                    ForEach(8..<16, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: theme.palette[i].nsColor)).frame(width: 14, height: 10)
                    }
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: theme.background.nsColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
            Text(label).font(.caption).lineLimit(1)
        }
    }
}

struct ThemeTile: View {
    let theme: TerminalTheme
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                ForEach([1, 2, 3, 4, 5, 6], id: \.self) { i in
                    Rectangle().fill(Color(nsColor: theme.palette[i].nsColor))
                }
            }
            .frame(height: 6)
            .clipShape(Capsule())
            Text(theme.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(nsColor: theme.foreground.nsColor))
                .lineLimit(1)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: theme.background.nsColor)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
    }
}

struct ColorOverridesSection: View {
    let dark: Bool

    private var keyPath: WritableKeyPath<AppSettings, ColorOverrides> { dark ? \.darkOverrides : \.lightOverrides }

    var body: some View {
        let s = SettingsStore.shared.settings
        let theme = ThemeLibrary.shared.resolved(dark: dark, settings: s)
        let overrides = s[keyPath: keyPath]
        Section {
            colorRow("Background", theme.background, \.background)
            colorRow("Foreground", theme.foreground, \.foreground)
            colorRow("Cursor", theme.cursor ?? theme.foreground, \.cursor)
            colorRow("Selection", theme.selectionBackground ?? theme.accent, \.selectionBackground)
            LabeledContent("ANSI colors") {
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach([0, 8], id: \.self) { base in
                        HStack(spacing: 6) {
                            ForEach(base..<base + 8, id: \.self) { i in
                                ColorPicker("", selection: paletteBinding(i, theme.palette[i]), supportsOpacity: false)
                                    .labelsHidden()
                                    .help(Self.ansiNames[i])
                            }
                        }
                    }
                }
            }
            if !overrides.isEmpty {
                Button("Reset to theme colors") { SettingsStore.shared.settings[keyPath: keyPath] = ColorOverrides() }
            }
        } header: {
            Text("Color overrides (\(dark ? "dark" : "light") mode)")
        } footer: {
            Text("Overrides are layered on top of the selected theme.")
        }
    }

    static let ansiNames = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White",
                            "Bright Black", "Bright Red", "Bright Green", "Bright Yellow", "Bright Blue", "Bright Magenta", "Bright Cyan", "Bright White"]

    private func colorRow(_ title: String, _ current: RGB, _ field: WritableKeyPath<ColorOverrides, String?>) -> some View {
        LabeledContent(title) {
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: current.nsColor) },
                set: { SettingsStore.shared.settings[keyPath: keyPath][keyPath: field] = RGB(NSColor($0)).hex }),
                supportsOpacity: false)
            .labelsHidden()
        }
    }

    private func paletteBinding(_ i: Int, _ current: RGB) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: current.nsColor) },
            set: { SettingsStore.shared.settings[keyPath: keyPath].palette[i] = RGB(NSColor($0)).hex })
    }
}
