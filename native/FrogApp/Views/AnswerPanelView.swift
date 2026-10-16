import SwiftUI
import FrogCore

/// The answer next to a selection: which rule and model answered, the answer and its follow-ups,
/// what is happening now, and a field for the next question.
struct AnswerPanelView: View {
    @ObservedObject var model: AnswerPanelModel
    @State private var contentHeight: CGFloat = 0
    @State private var chromeHeight: CGFloat = 0

    /// The answer scrolls once the panel reaches its tallest.
    private var scrollHeight: CGFloat { min(contentHeight, max(80, model.maxHeight - chromeHeight)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                header
                if let selection = model.session?.selection, !selection.isEmpty {
                    Text(Self.oneLine(selection)).font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                        .lineLimit(1).truncationMode(.middle)
                        .accessibilityLabel("\(L10n.text("Selected text")): \(Self.oneLine(selection))")
                }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            .background(WindowDragRegion())
            .overlay(alignment: .bottom) { Divider().opacity(0.6) }
            .measured(ChromeHeightKey.self)
            // Before the first text and after a failure without any, the status line follows the header directly.
            if hasContent {
                ScrollViewReader { proxy in
                    ScrollView {
                        answer.padding(.horizontal, 14).padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .measured(ContentHeightKey.self)
                    }
                    .minimalScrollbars()
                    .frame(height: scrollHeight)
                    .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
                    // A follow-up's answer starts below the earlier ones, often out of sight in a full panel.
                    .onChange(of: model.session?.pendingQuestion) { _, question in
                        guard question != nil else { return }
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.followUpID, anchor: .top) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                statusLine
                // A failure or stop without any answer has nothing to ask about, copy or save.
                if hasAnswer || model.session?.phase.isRunning == true { footer }
            }
            .measured(ChromeHeightKey.self)
        }
        .frame(width: AnswerPanelController.width)
        .fixedSize(horizontal: false, vertical: true)
        .onPreferenceChange(ChromeHeightKey.self) { chromeHeight = $0 }
        .onChange(of: chromeHeight + scrollHeight, initial: true) { _, height in model.heightChanged(height) }
        .environment(\.locale, L10n.locale)
        .foregroundStyle(FrogStyle.ink)
        .frogPanel()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("Explain answer"))
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.session?.ruleName ?? "").font(FrogType.section).lineLimit(1)
                if let label = model.session?.modelLabel, !label.isEmpty {
                    Text(label).font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            let pinTitle = model.pinned ? "Stop keeping open" : "Keep open"
            Button { model.togglePin() } label: {
                Image(systemName: model.pinned ? "pin.fill" : "pin").frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(model.pinned ? FrogStyle.accent : FrogStyle.muted)
            .help(L10n.text(pinTitle)).accessibilityLabel(L10n.text(pinTitle))
            Button { model.close() } label: {
                Image(systemName: "xmark").frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(FrogStyle.muted)
            .help(L10n.text("Close (Esc)")).accessibilityLabel(L10n.text("Close"))
        }
        .font(.system(size: 12, weight: .medium))
    }

    @ViewBuilder private var answer: some View {
        if let session = model.session {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(session.turns.enumerated()), id: \.offset) { index, turn in
                    if index > 0 { question(turn.question) }
                    AnswerMarkdown(text: turn.answer)
                }
                if let pending = session.pendingQuestion, !session.turns.isEmpty { question(pending).id(Self.followUpID) }
                if !session.partial.isEmpty { AnswerMarkdown(text: session.partial) }
            }
            .font(FrogType.body)
            .textSelection(.enabled)
        }
    }

    private static let followUpID = "follow-up"

    /// A rule across the panel's width sets each follow-up apart from the answer before it.
    private func question(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.5)
            Text(text).font(FrogType.label).foregroundStyle(FrogStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    /// A note that could not be saved takes the line until the next action.
    @ViewBuilder private var statusLine: some View {
        if let session = model.session, let line = noteFailure ?? session.statusLine {
            HStack(spacing: 8) {
                if noteFailure == nil, session.phase.isPending { ProgressView().controlSize(.mini) }
                Text(line).font(FrogType.caption)
                    .foregroundStyle(failed || noteFailure != nil ? FrogStyle.warning : FrogStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                switch noteFailure == nil ? model.recovery : nil {
                case .retry: Button(L10n.text("Retry")) { model.retry() }
                case .editRule: Button(L10n.text("Edit rule")) { model.editRule() }
                case .allowAccessibility: Button(L10n.text("Open System Settings")) { model.allowAccessibility() }
                case nil: EmptyView()
                }
            }
            .buttonStyle(FrogButtonStyle()).controlSize(.small)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .overlay(alignment: .top) { if hasContent { Divider().opacity(0.6) } }
            .accessibilityElement(children: .combine)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField(L10n.text(followUpPlaceholder), text: $model.question)
                    .textFieldStyle(.plain).font(FrogType.body)
                    .padding(.horizontal, 8).frame(height: 26)
                    .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius))
                    .overlay(RoundedRectangle(cornerRadius: FrogStyle.controlRadius).strokeBorder(FrogStyle.border.opacity(0.6)))
                    // It stays enabled while the answer runs, so it keeps focus and the next question can be typed.
                    .disabled(followUpBlocked)
                    .onSubmit { model.ask(model.question) }
                    .accessibilityLabel(L10n.text("Ask a follow-up"))
                if model.session?.phase.isRunning == true {
                    Button(L10n.text("Stop")) { model.stop() }.help(L10n.text("Stop (⌘.)"))
                }
                Button { model.copy() } label: {
                    if model.copied { Label(L10n.text("Copied"), systemImage: "checkmark") } else { Text(L10n.text("Copy")) }
                }
                .help(L10n.text("Copy (⌘↩)")).disabled(!hasAnswer)
                if model.offersNotes { saveNoteButton }
            }
            if let message = model.followUpMessage {
                Text(message).font(FrogType.caption).foregroundStyle(FrogStyle.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(FrogButtonStyle()).controlSize(.small)
        .padding(10)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
    }

    @ViewBuilder private var saveNoteButton: some View {
        if model.noteState == .saved {
            Label(L10n.text("Saved"), systemImage: "checkmark").font(FrogType.caption).foregroundStyle(FrogStyle.accent)
                .padding(.horizontal, 4).accessibilityLabel(L10n.text("Saved to note"))
        } else {
            Button(L10n.text("Save to note")) { model.saveNote() }
                .help(L10n.text("Save to note (⌘S)"))
                .disabled(!model.canSaveNote)
        }
    }

    // MARK: State

    private var noteFailure: String? {
        if case .failed(let message) = model.noteState { message } else { nil }
    }

    private var failed: Bool {
        if case .failed = model.session?.phase { true } else { false }
    }

    /// Blocked once the conversation is full, or after a failure until Retry. A question typed while the answer
    /// runs is asked with Return once it is done.
    private var followUpBlocked: Bool {
        guard let session = model.session else { return true }
        return session.followUpBlock != nil && !session.phase.isRunning
    }

    /// After a failure the reason is in the status line; a full conversation says so in the field.
    private var followUpPlaceholder: String {
        guard let session = model.session, !failed, !session.phase.isRunning, let block = session.followUpBlock else { return "Ask a follow-up" }
        return block
    }

    /// Any answer text or follow-up question to show above the status line.
    private var hasContent: Bool {
        guard let session = model.session else { return false }
        return !session.turns.isEmpty || !session.partial.isEmpty
    }

    private var hasAnswer: Bool {
        guard let session = model.session else { return false }
        return !session.partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.turns.last?.answer.isEmpty == false
    }

    /// One line of the selection, short enough that laying it out stays cheap for a long selection.
    static func oneLine(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard flat.count > 400 else { return flat }
        return String(flat.prefix(200)) + "…" + String(flat.suffix(200))
    }
}

/// An answer in the Notes renderer's blocks.
private struct AnswerMarkdown: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(MarkdownPreview.blocks(text)) { MarkdownBlockView(block: $0) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The header and the footer, summed.
private struct ChromeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

private extension View {
    func measured<Key: PreferenceKey>(_ key: Key.Type) -> some View where Key.Value == CGFloat {
        background(GeometryReader { proxy in Color.clear.preference(key: key, value: proxy.size.height) })
    }
}
