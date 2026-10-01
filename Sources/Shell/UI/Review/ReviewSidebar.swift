import SwiftUI

/// The left column: the changed files with stage checkboxes, then the commit box.
struct ReviewSidebar: View {
    @Bindable var model: ReviewChangesModel
    var onEditorFocus: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Changes").font(.system(size: DS.Size.title, weight: .semibold))
                Spacer()
                Button("Stage all") { model.stageAll() }
                    .buttonStyle(.link)
                    .font(.system(size: DS.Size.small))
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
            Divider()
            commitBox
        }
        .frame(width: 290)
    }

    private var commitBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Commit message").font(.system(size: DS.Size.body, weight: .semibold))
                Spacer()
                if model.canDraft {
                    Button { model.draftMessage() } label: {
                        HStack(spacing: 4) {
                            if model.isDrafting { ProgressView().controlSize(.mini) } else {
                                Image(systemName: "sparkle").foregroundStyle(DS.Status.review)
                            }
                            Text("Write for me")
                        }
                    }
                    .buttonStyle(.labeled(.plain, compact: true))
                    .disabled(model.isDrafting)
                    .help("Draft a message from the staged changes with Apple Intelligence, on this Mac")
                }
            }
            ReviewCommitEditor(text: $model.commitMessage, onFocusChange: onEditorFocus)
                .frame(height: 130)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: DS.Radius.row))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.row).strokeBorder(Color.primary.opacity(0.12)))
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
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.labeled(.primary))
                Button("Commit & Push") { model.commit(push: true) }
                    .buttonStyle(.labeled(.neutral))
            }
            .disabled(model.isCommitting)
            Text("⌘⏎ commit · ⇧⌘⏎ commit and push").font(.system(size: DS.Size.caption)).foregroundStyle(.tertiary)
        }
        .padding(14)
    }

    static func commitTitle(_ n: Int) -> String {
        n == 0 ? "Commit" : "Commit \(n) file\(n == 1 ? "" : "s")"
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
                    .font(.system(size: 14))
                    .foregroundStyle(file.stageState == .none ? (selected ? Color.white.opacity(0.8) : .secondary)
                                     : (selected ? .white : DS.Status.selection))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(file.stageState == .full ? "Unstage \(file.fileName)" : "Stage \(file.fileName)")
            Text(file.letter)
                .font(.system(size: DS.Size.small, weight: .bold, design: .monospaced))
                .foregroundStyle(selected ? .white : ReviewStyle.color(file.status))
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.fileName).font(.system(size: DS.Size.body, weight: .medium)).lineLimit(1)
                if !file.folder.isEmpty {
                    Text(file.folder).font(.system(size: DS.Size.caption))
                        .foregroundStyle(selected ? Color.white.opacity(0.75) : .secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                if file.additions > 0 { Text("+\(file.additions)") }
                if file.deletions > 0 { Text("−\(file.deletions)") }
            }
            .font(.system(size: DS.Size.small).monospacedDigit())
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
}
