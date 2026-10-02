import SwiftUI

/// The left column: the changed files with stage checkboxes, then the commit box.
struct ReviewSidebar: View {
    @Bindable var model: ReviewChangesModel
    var onEditorFocus: (Bool) -> Void = { _ in }
    @State private var editorFocused = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Changes").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Stage all") { model.stageAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: DS.Size.subtitle))
                    .foregroundStyle(DS.Status.selection)
                    .disabled(model.files.allSatisfy { $0.stageState == .full })
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.files) { file in
                        ReviewFileRow(file: file, selected: model.selectedPath == file.path,
                                      toggle: { model.toggleStaged(file) }, select: { model.select(file) })
                    }
                }
                .padding(.horizontal, 8)
            }
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
            commitBox
        }
        .frame(width: 290)
        .background(ClaudePalette.current.surface)
    }

    private var commitBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Commit message").font(.system(size: 12, weight: .semibold))
                Spacer()
                if model.canDraft {
                    Button { model.draftMessage() } label: {
                        HStack(spacing: 5) {
                            if model.isDrafting { ProgressView().controlSize(.mini) } else { IntelligenceDiamond() }
                            Text("Write for me")
                        }
                        .font(.system(size: DS.Size.subtitle))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isDrafting)
                    .help("Draft a message from the staged changes with Apple Intelligence, on this Mac")
                }
            }
            ReviewCommitEditor(text: $model.commitMessage) { focused in
                editorFocused = focused
                onEditorFocus(focused)
            }
            .frame(height: 140)
            .background(ClaudePalette.current.isDark ? Color.black.opacity(0.22) : Color.white, in: RoundedRectangle(cornerRadius: DS.Radius.row))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.row).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .background {
                if editorFocused {
                    RoundedRectangle(cornerRadius: DS.Radius.row + 3).fill(DS.Status.selection.opacity(0.35)).padding(-3)
                }
            }
            if let error = model.error {
                ScrollView {
                    Text(error)
                        .font(.system(size: DS.Size.small))
                        .foregroundStyle(DS.Status.failed)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Button { model.commit() } label: {
                    HStack(spacing: 4) {
                        if model.isCommitting { ProgressView().controlSize(.mini) }
                        Text(Self.commitTitle(model.stagedCount))
                    }
                    .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.labeled(.primary))
                Button { model.commit(push: true) } label: {
                    Text("Commit & Push").frame(minHeight: 28)
                }
                .buttonStyle(.labeled(.neutral))
            }
            .disabled(model.isCommitting)
            Text("⌘⏎ commit · ⇧⌘⏎ commit and push").font(.system(size: DS.Size.small)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 14)
    }

    static func commitTitle(_ n: Int) -> String {
        n == 0 ? "Commit" : "Commit \(n) file\(n == 1 ? "" : "s")"
    }
}

/// The small blue-to-purple diamond marking on-device Apple Intelligence actions.
struct IntelligenceDiamond: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(LinearGradient(colors: [Color(red: 0.37, green: 0.69, blue: 1), Color(red: 0.75, green: 0.35, blue: 0.95)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 8, height: 8)
            .rotationEffect(.degrees(45))
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
    }
}

/// "☑ M  StreamWriter.swift / Sources/Shell/Claude   +9 −2"
struct ReviewFileRow: View {
    let file: ReviewFile
    let selected: Bool
    let toggle: () -> Void
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Image(systemName: checkbox)
                    .font(.system(size: 13))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(checkmarkColor, boxColor)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(file.stageState == .full ? "Unstage \(file.fileName)" : "Stage \(file.fileName)")
            Text(file.letter)
                .font(.system(size: DS.Size.small, weight: .bold))
                .foregroundStyle(selected ? .white : ReviewStyle.color(file.status))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.fileName).font(.system(size: DS.Size.body)).lineLimit(1)
                if !file.folder.isEmpty {
                    Text(file.folder).font(.system(size: DS.Size.small))
                        .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                if file.additions > 0 { Text("+\(file.additions)") }
                if file.deletions > 0 { Text("−\(file.deletions)") }
            }
            .font(ChatTypography.current.codeFont(size: DS.Size.small))
            .foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
        }
        .foregroundStyle(selected ? .white : .primary)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .rowBackground(selected: selected, hovering: hovering, accent: true)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: select)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var checkbox: String {
        switch file.stageState {
        case .full: "checkmark.square.fill"
        case .partial: "minus.square.fill"
        case .none: "square"
        }
    }

    /// The tick: blue on the white box of a selected row, white on blue otherwise.
    private var checkmarkColor: Color {
        guard file.stageState != .none else { return boxColor }
        return selected ? DS.Status.selection : .white
    }

    private var boxColor: Color {
        if file.stageState == .none { return selected ? Color.white.opacity(0.8) : Color.secondary }
        return selected ? .white : DS.Status.selection
    }
}
