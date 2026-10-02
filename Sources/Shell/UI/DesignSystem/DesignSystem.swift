import AppKit
import SwiftUI

// Shared building blocks for Shell's chrome: one status vocabulary, one set of
// radii and type sizes, and the small controls (pills, icon tiles, key hints,
// labeled capsule buttons) every surface reuses.
//
// Surfaces still derive from the user's terminal theme (`ChromePalette`), so a
// custom theme keeps the window coherent. Status and selection colors are
// system colors, so they read the same in every theme and match macOS.

/// Corner radii, spacing and type sizes for chrome. Code text uses the
/// terminal font; everything else uses SF Pro at these sizes.
enum DS {
    enum Radius {
        /// Pills, small badges, key caps.
        static let pill: CGFloat = 5
        /// Icon tiles, compact buttons.
        static let control: CGFloat = 6
        /// Rows, fields, menus.
        static let row: CGFloat = 8
        /// Cards, panels, popovers.
        static let card: CGFloat = 10
        /// The floating sidebar and large surfaces.
        static let panel: CGFloat = 12
    }

    enum Size {
        static let caption: CGFloat = 10.5
        static let small: CGFloat = 11
        static let subtitle: CGFloat = 11.5
        static let body: CGFloat = 12.5
        static let title: CGFloat = 13
        static let heading: CGFloat = 15
    }

    /// Gap between the floating sidebar and the window edge.
    static let sidebarInset: CGFloat = 8
    /// Height of the unified toolbar.
    static let toolbarHeight: CGFloat = 52

    /// Status colors. Orange = working, yellow = needs you, green = done,
    /// red = failed, blue = selection and links (follows the system accent).
    enum Status {
        static let working = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0xF0 / 255, green: 0x9A / 255, blue: 0x72 / 255, alpha: 1)
                : NSColor(srgbRed: 0xC4 / 255, green: 0x62 / 255, blue: 0x3F / 255, alpha: 1)
        })
        static let needsYou = Color(nsColor: .systemYellow)
        static let done = Color(nsColor: .systemGreen)
        static let failed = Color(nsColor: .systemRed)
        static let info = Color(nsColor: .systemBlue)
        static let review = Color(nsColor: .systemPurple)
        /// The fill behind a selected row: the system accent, like Finder.
        static let selection = Color.accentColor
    }

    /// Claude's brand orange, used for the ✻ mark and Claude actions.
    static let claude = Status.working
}

// MARK: - Status

/// The one place that turns an agent state into the sidebar/palette/dashboard
/// indicator: an orange spinner while working, a yellow "Input" pill when it
/// needs you, a green check when it finished unseen.
enum StatusKind: Equatable {
    case working, needsYou, done, failed, idle

    init(_ agent: AgentStatus?) {
        switch agent {
        case .working: self = .working
        case .needsInput: self = .needsYou
        case .finished: self = .done
        case nil: self = .idle
        }
    }

    var color: Color {
        switch self {
        case .working: DS.Status.working
        case .needsYou: DS.Status.needsYou
        case .done: DS.Status.done
        case .failed: DS.Status.failed
        case .idle: .secondary
        }
    }

    /// Sort key: needs-you first, then working, then the rest.
    var priority: Int {
        switch self {
        case .needsYou: 0
        case .working: 1
        case .failed: 2
        case .done: 3
        case .idle: 4
        }
    }
}

/// An orange ring spinner. A repeating rotation animation, not a per-frame
/// redraw, and still for Reduce Motion.
struct SpinnerRing: View {
    var color: Color = DS.Status.working
    var size: CGFloat = 11
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: 2)
            Circle().trim(from: 0, to: 0.28).stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(turning ? 360 : 0))
                .animation(turning ? .linear(duration: 0.9).repeatForever(autoreverses: false) : nil, value: turning)
        }
        .frame(width: size, height: size)
        .onAppear { turning = !reduceMotion }
        .accessibilityLabel("Working")
    }
}

/// Spinner, "Input" pill or check for an agent state; nothing when idle.
struct StatusIndicator: View {
    let status: StatusKind

    var body: some View {
        switch status {
        case .working: SpinnerRing()
        case .needsYou: Pill("Input", color: DS.Status.needsYou)
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(DS.Status.done)
                .accessibilityLabel("Done")
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(DS.Status.failed)
                .accessibilityLabel("Failed")
        case .idle: EmptyView()
        }
    }
}

/// A small tinted label: "Input", "3 to review", "Assigned", "Draft".
struct Pill: View {
    let text: String
    var color: Color
    var filled = false

    init(_ text: String, color: Color, filled: Bool = false) {
        self.text = text
        self.color = color
        self.filled = filled
    }

    var body: some View {
        Text(text)
            .font(.system(size: DS.Size.caption, weight: .semibold))
            .foregroundStyle(filled ? Color.black.opacity(0.85) : color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(filled ? color : color.opacity(0.15), in: RoundedRectangle(cornerRadius: DS.Radius.pill))
            .lineLimit(1)
            .fixedSize()
    }
}

/// A round count badge, e.g. the yellow "1" on Claude Sessions.
struct CountBadge: View {
    let count: Int
    var color: Color = DS.Status.needsYou

    var body: some View {
        Text("\(count)")
            .font(.system(size: DS.Size.small, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(color, in: Capsule())
            .fixedSize()
    }
}

// MARK: - Icon tiles

/// The 24pt rounded tile that leads every sidebar row and palette result.
struct IconTile<Content: View>: View {
    var tint: Color?
    var size: CGFloat = 24
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control)
                    .fill(tint.map { $0.opacity(0.16) } ?? Color.primary.opacity(0.07)))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control)
                    .strokeBorder(tint == nil ? Color.primary.opacity(0.1) : .clear, lineWidth: 0.5))
    }
}

/// Which mark a tab or result shows in its tile.
enum TileKind {
    case terminal, claude, codex, github, worktree, folder, symbol(String)
}

struct KindTile: View {
    let kind: TileKind
    var size: CGFloat = 24

    var body: some View {
        switch kind {
        case .terminal:
            IconTile(size: size) {
                Text("›_").font(.system(size: size * 0.42, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
            }
        case .claude:
            IconTile(tint: DS.claude, size: size) { ClaudeMark(size: size * 0.55) }
        case .codex:
            IconTile(size: size) {
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: size * 0.4, weight: .semibold))
            }
        case .github:
            IconTile(size: size) { GitHubMark().fill(Color.primary.opacity(0.9)).frame(width: size * 0.58, height: size * 0.58) }
        case .worktree:
            IconTile(size: size) { BranchGlyph(size: size * 0.5).foregroundStyle(.secondary) }
        case .folder:
            IconTile(size: size) { Image(systemName: "folder").font(.system(size: size * 0.45)).foregroundStyle(.secondary) }
        case .symbol(let name):
            IconTile(size: size) { Image(systemName: name).font(.system(size: size * 0.45)).foregroundStyle(.secondary) }
        }
    }
}

/// Claude's ✻ in brand orange, sized for tiles and buttons.
struct ClaudeMark: View {
    var size: CGFloat = 13
    var color: Color = DS.claude

    var body: some View {
        ClaudeLogoShape().fill(color).frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// The ⎇ branch glyph used in subtitles and chips.
struct BranchGlyph: View {
    var size: CGFloat = 11

    var body: some View {
        Image(systemName: "arrow.triangle.branch").font(.system(size: size, weight: .medium)).accessibilityHidden(true)
    }
}

/// GitHub's mark (Octicons `mark-github`, MIT), drawn from its 16×16 path.
struct GitHubMark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let s = min(rect.width, rect.height) / 16
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        p.move(to: pt(6.766, 11.328))
        p.addCurve(to: pt(3.25, 7.672), control1: pt(4.703, 11.078), control2: pt(3.25, 9.594))
        p.addCurve(to: pt(4, 5.484), control1: pt(3.25, 6.891), control2: pt(3.531, 6.047))
        p.addCurve(to: pt(4.063, 3.422), control1: pt(3.797, 4.969), control2: pt(3.828, 3.875))
        p.addCurve(to: pt(6.031, 4.125), control1: pt(4.688, 3.344), control2: pt(5.531, 3.672))
        p.addCurve(to: pt(8.016, 3.844), control1: pt(6.625, 3.938), control2: pt(7.25, 3.844))
        p.addCurve(to: pt(9.969, 4.109), control1: pt(8.781, 3.844), control2: pt(9.406, 3.938))
        p.addCurve(to: pt(11.938, 3.422), control1: pt(10.453, 3.672), control2: pt(11.313, 3.344))
        p.addCurve(to: pt(11.984, 5.469), control1: pt(12.156, 3.844), control2: pt(12.188, 4.937))
        p.addCurve(to: pt(12.75, 7.672), control1: pt(12.484, 6.062), control2: pt(12.75, 6.859))
        p.addCurve(to: pt(9.203, 11.312), control1: pt(12.75, 9.594), control2: pt(11.297, 11.047))
        p.addCurve(to: pt(10.093, 13.266), control1: pt(9.734, 11.656), control2: pt(10.093, 12.406))
        p.addLine(to: pt(10.093, 14.891))
        p.addCurve(to: pt(10.953, 15.438), control1: pt(10.093, 15.359), control2: pt(10.484, 15.625))
        p.addCurve(to: pt(16, 8.03), control1: pt(13.781, 14.359), control2: pt(16, 11.53))
        p.addCurve(to: pt(7.984, 0), control1: pt(16, 3.61), control2: pt(12.406, 0))
        p.addCurve(to: pt(0, 8.031), control1: pt(3.563, 0), control2: pt(0, 3.61))
        p.addCurve(to: pt(5.172, 15.453), control1: pt(-0.009, 11.347), control2: pt(2.058, 14.314))
        p.addCurve(to: pt(6, 14.906), control1: pt(5.594, 15.609), control2: pt(6, 15.328))
        p.addLine(to: pt(6, 13.656))
        p.addCurve(to: pt(5.25, 13.812), control1: pt(5.781, 13.75), control2: pt(5.5, 13.812))
        p.addCurve(to: pt(3.172, 12.203), control1: pt(4.219, 13.812), control2: pt(3.61, 13.25))
        p.addCurve(to: pt(2.453, 11.484), control1: pt(3, 11.781), control2: pt(2.812, 11.531))
        p.addCurve(to: pt(2.203, 11.297), control1: pt(2.266, 11.469), control2: pt(2.203, 11.391))
        p.addCurve(to: pt(2.828, 10.969), control1: pt(2.203, 11.109), control2: pt(2.516, 10.969))
        p.addCurve(to: pt(4.078, 11.829), control1: pt(3.281, 10.969), control2: pt(3.672, 11.25))
        p.addCurve(to: pt(5.109, 12.484), control1: pt(4.391, 12.281), control2: pt(4.718, 12.484))
        p.addCurve(to: pt(6.109, 11.984), control1: pt(5.5, 12.484), control2: pt(5.75, 12.344))
        p.addCurve(to: pt(6.766, 11.328), control1: pt(6.375, 11.719), control2: pt(6.579, 11.484))
        p.closeSubpath()
        return p
    }
}

// MARK: - Controls

/// A shortcut shown at the trailing edge of a row or button: "⌘T", "⇧⌘P".
struct KeyHint: View {
    let keys: String
    var boxed = false

    init(_ keys: String, boxed: Bool = false) {
        self.keys = keys
        self.boxed = boxed
    }

    var body: some View {
        Text(keys)
            .font(.system(size: DS.Size.small))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, boxed ? 5 : 0).padding(.vertical, boxed ? 1 : 0)
            .background(boxed ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }
}

/// Labeled toolbar/row button: neutral capsule by default, filled blue for
/// the primary action, Claude orange for Claude actions.
struct LabeledButtonStyle: ButtonStyle {
    enum Role { case neutral, primary, claude, destructive, plain }
    var role: Role = .neutral
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? DS.Size.small : DS.Size.body, weight: role == .primary ? .semibold : .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 7 : 10)
            .frame(minHeight: compact ? 22 : 26)
            .background(background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control))
    }

    private var foreground: Color {
        switch role {
        case .primary: .white
        case .claude: DS.claude
        case .destructive: DS.Status.failed
        case .neutral, .plain: .primary
        }
    }

    private func background(pressed: Bool) -> Color {
        let boost = pressed ? 0.06 : 0
        switch role {
        case .primary: return DS.Status.selection.opacity(pressed ? 0.8 : 1)
        case .claude: return DS.claude.opacity(0.14 + boost)
        case .destructive: return DS.Status.failed.opacity(0.14 + boost)
        case .neutral: return Color.primary.opacity(0.08 + boost)
        case .plain: return pressed ? Color.primary.opacity(0.08) : .clear
        }
    }
}

extension ButtonStyle where Self == LabeledButtonStyle {
    static var labeled: LabeledButtonStyle { LabeledButtonStyle() }
    static func labeled(_ role: LabeledButtonStyle.Role, compact: Bool = false) -> LabeledButtonStyle {
        LabeledButtonStyle(role: role, compact: compact)
    }
}

/// Uppercase-free section header with an optional count: "Tabs   5".
struct SectionHeader: View {
    let title: String
    var count: Int?
    var trailing: AnyView?

    init(_ title: String, count: Int? = nil, trailing: AnyView? = nil) {
        self.title = title
        self.count = count
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: DS.Size.small, weight: .semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if let trailing { trailing }
            if let count { Text("\(count)").font(.system(size: DS.Size.small, weight: .semibold)).foregroundStyle(.secondary) }
        }
    }
}

/// A row background that shows hover and selection the same way everywhere.
struct RowBackground: ViewModifier {
    var selected: Bool
    var hovering: Bool
    var accentSelection = false

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: DS.Radius.row)
                .fill(selected ? (accentSelection ? DS.Status.selection : Color.primary.opacity(0.11))
                      : hovering ? Color.primary.opacity(0.06) : .clear))
    }
}

extension View {
    func rowBackground(selected: Bool, hovering: Bool, accent: Bool = false) -> some View {
        modifier(RowBackground(selected: selected, hovering: hovering, accentSelection: accent))
    }

    /// A raised card: subtle fill and hairline border.
    func cardSurface(tint: Color? = nil, radius: CGFloat = DS.Radius.card) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius)
                .fill(tint.map { $0.opacity(0.08) } ?? Color.primary.opacity(0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(tint.map { $0.opacity(0.45) } ?? Color.primary.opacity(0.08), lineWidth: tint == nil ? 0.5 : 1))
    }
}

/// A segmented control styled like the design's grouped capsules (Session /
/// Worktrees / Checks / Files; For you / Mine / All).
struct SegmentedTabs<ID: Hashable>: View {
    struct Item: Identifiable {
        let id: ID
        let title: String
        var count: Int?
        var dot: Color?
    }

    let items: [Item]
    @Binding var selection: ID

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                Button { selection = item.id } label: {
                    HStack(spacing: 4) {
                        Text(item.title)
                        if let count = item.count { Text("\(count)").foregroundStyle(.secondary) }
                        if let dot = item.dot { Circle().fill(dot).frame(width: 6, height: 6) }
                    }
                    .font(.system(size: DS.Size.body, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, 6).frame(height: 22)
                    .frame(maxWidth: .infinity)
                    .background(selection == item.id ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.control))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == item.id ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.Radius.row))
    }
}

/// Native window glass for floating chrome (the sidebar). Falls back to an
/// opaque fill when the user turns on Reduce Transparency.
struct GlassPanel: NSViewRepresentable {
    var cornerRadius: CGFloat = DS.Radius.panel

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        v.wantsLayer = true
        v.layer?.cornerRadius = cornerRadius
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.layer?.cornerRadius = cornerRadius
    }
}
