import SwiftUI

/// Review Changes (issue #42): the working tree's diff, split or unified,
/// with per-hunk staging, line comments sent to Claude, and a commit box.
///
///     ReviewChangesView(repository: repo, onBack: { … }, onSendToClaude: { prompt in … })
///
/// The view owns its model and starts and stops it with its lifetime.
struct ReviewChangesView: View {
    @State private var model: ReviewChangesModel
    let onBack: () -> Void
    let onSendToClaude: (String) -> Void

    @FocusState private var diffFocused: Bool
    @State private var editorFocused = false

    init(repository: GitRepository, onBack: @escaping () -> Void, onSendToClaude: @escaping (String) -> Void) {
        _model = State(initialValue: ReviewChangesModel(repository: repository))
        self.onBack = onBack
        self.onSendToClaude = onSendToClaude
    }

    /// For tests and previews: drive the view from an existing model.
    init(model: ReviewChangesModel, onBack: @escaping () -> Void, onSendToClaude: @escaping (String) -> Void) {
        _model = State(initialValue: model)
        self.onBack = onBack
        self.onSendToClaude = onSendToClaude
    }

    var body: some View {
        VStack(spacing: 0) {
            ReviewTopBar(model: model, onBack: onBack, onCommit: commitFromTopBar) { onSendToClaude(model.reviewPrompt) }
            Divider()
            HStack(spacing: 0) {
                ReviewSidebar(model: model) { editorFocused = $0 }
                Divider()
                VStack(spacing: 0) {
                    ReviewDiffList(model: model, onSendToClaude: onSendToClaude)
                        .focusable()
                        .focusEffectDisabled()
                        .focused($diffFocused)
                        .simultaneousGesture(TapGesture().onEnded { diffFocused = true })
                    Divider()
                    ReviewFooter(model: model)
                }
            }
        }
        .background { if diffFocused || editorFocused { shortcuts } }
        .onAppear {
            model.start()
            diffFocused = true
        }
        .onDisappear { model.stop() }
    }

    private func commitFromTopBar() {
        if model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.canDraft, model.stagedCount > 0 {
            model.draftMessage()
        } else {
            model.commit()
        }
    }

    /// Keyboard shortcuts, live only while the review has focus so ⌘] and ⌘[
    /// still move between panes elsewhere.
    private var shortcuts: some View {
        ZStack {
            Button("Next change") { model.nextChange(1) }.keyboardShortcut(.downArrow, modifiers: .option)
            Button("Previous change") { model.nextChange(-1) }.keyboardShortcut(.upArrow, modifiers: .option)
            Button("Next file") { model.nextFile(1) }.keyboardShortcut("]", modifiers: .command)
            Button("Previous file") { model.nextFile(-1) }.keyboardShortcut("[", modifiers: .command)
            if model.comment == nil {
                Button("Commit") { model.commit() }.keyboardShortcut(.return, modifiers: .command)
                Button("Commit and Push") { model.commit(push: true) }.keyboardShortcut(.return, modifiers: [.command, .shift])
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

/// "‹ Chat  Review changes / ⎇ branch → main · 3 files +79 −3 … Unified|Split ☑ Hide whitespace ✻ Ask Claude  Commit…"
struct ReviewTopBar: View {
    @Bindable var model: ReviewChangesModel
    let onBack: () -> Void
    let onCommit: () -> Void
    let askClaude: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                HStack(spacing: 3) { Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)); Text("Chat") }
            }
            .buttonStyle(.labeled(.plain))
            VStack(alignment: .leading, spacing: 1) {
                Text("Review changes").font(.system(size: DS.Size.title, weight: .semibold))
                HStack(spacing: 4) {
                    BranchGlyph(size: 10)
                    Text(model.branch).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "arrow.right").font(.system(size: 8))
                    Text(model.baseBranch)
                    Text("·")
                    Text("\(model.files.count) file\(model.files.count == 1 ? "" : "s")")
                    Text("+\(model.totalAdditions)").foregroundStyle(ReviewStyle.added)
                    Text("−\(model.totalDeletions)").foregroundStyle(ReviewStyle.removed)
                    if model.isLoading { ProgressView().controlSize(.mini) }
                }
                .font(.system(size: DS.Size.small))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            SegmentedTabs(items: [.init(id: false, title: "Unified"), .init(id: true, title: "Split")], selection: $model.split)
                .frame(width: 160)
            Toggle("Hide whitespace", isOn: $model.hideWhitespace)
                .toggleStyle(.checkbox)
                .font(.system(size: DS.Size.body))
            Button(action: askClaude) {
                HStack(spacing: 5) { ClaudeMark(size: 12); Text("Ask Claude to review") }
            }
            .buttonStyle(.labeled(.claude))
            .disabled(model.files.isEmpty)
            Button(ReviewSidebar.commitTitle(model.stagedCount) + "…", action: onCommit)
                .buttonStyle(.labeled(.primary))
                .disabled(model.isCommitting)
        }
        .padding(.horizontal, 14)
        .frame(height: DS.toolbarHeight)
    }
}

/// "File 2 of 3 · 1 viewed          ⌥↓ next change  ⌘] next file  Click a line number to comment"
struct ReviewFooter: View {
    let model: ReviewChangesModel

    var body: some View {
        HStack(spacing: 14) {
            Text(position).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            hint("⌥↓", "next change")
            hint("⌘]", "next file")
            Text("Click a line number to comment").foregroundStyle(.tertiary)
        }
        .font(.system(size: DS.Size.small))
        .padding(.horizontal, 14)
        .frame(height: 30)
    }

    private var position: String {
        guard !model.files.isEmpty else { return "No changes" }
        let i = (model.selectedIndex ?? 0) + 1
        return "File \(i) of \(model.files.count) · \(model.viewedCount) viewed"
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 4) { KeyHint(keys); Text(label).foregroundStyle(.tertiary) }
    }
}
