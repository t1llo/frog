import SwiftUI
import FrogCore

/// The answer next to a selection: one quiet line for the rule and its model, the answer and its follow-ups, what is
/// happening now, and a field for the next question with the actions as icons beside it.
struct AnswerPanelView: View {
    @ObservedObject var model: AnswerPanelModel
    @State private var contentHeight: CGFloat = 0
    @State private var chromeHeight: CGFloat = 0

    /// The answer scrolls once the panel reaches its tallest.
    private var scrollHeight: CGFloat { min(contentHeight, max(80, model.maxHeight - chromeHeight)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 5)
                .background(WindowDragRegion())
                .measured(ChromeHeightKey.self)
            // Before the first text and after a failure without any, the status line follows the header directly.
            if hasContent {
                ScrollViewReader { proxy in
                    ScrollView {
                        answer.padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 10)
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

    /// The rule and the model's name; the provider shows on hover.
    private var header: some View {
        HStack(spacing: 4) {
            Text(model.session?.ruleName ?? "").foregroundStyle(FrogStyle.ink).layoutPriority(1)
            if let session = model.session, !session.modelName.isEmpty {
                Text("·").accessibilityHidden(true)
                Text(session.modelName).help(session.modelLabel)
            }
            Spacer(minLength: 8)
            let pinTitle = model.pinned ? "Stop keeping open" : "Keep open"
            PanelIcon(symbol: model.pinned ? "pin.fill" : "pin", title: pinTitle, active: model.pinned) { model.togglePin() }
            PanelIcon(symbol: "xmark", title: "Close", help: "Close (Esc)") { model.close() }
        }
        .font(FrogType.label).foregroundStyle(FrogStyle.muted).lineLimit(1)
    }

    @ViewBuilder private var answer: some View {
        if let session = model.session {
            VStack(alignment: .leading, spacing: 8) {
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
        VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.5)
            Text(text).font(FrogType.label).foregroundStyle(FrogStyle.muted)
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
            .padding(.horizontal, 12).padding(.vertical, 6)
            .overlay(alignment: .top) { if hasContent { Divider().opacity(0.6) } }
            .accessibilityElement(children: .combine)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                TextField(L10n.text(followUpPlaceholder), text: $model.question)
                    .textFieldStyle(.plain).font(FrogType.body)
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius))
                    .overlay(RoundedRectangle(cornerRadius: FrogStyle.controlRadius).strokeBorder(FrogStyle.border.opacity(0.6)))
                    // It stays enabled while the answer runs, so it keeps focus and the next question can be typed.
                    .disabled(followUpBlocked)
                    .onSubmit { model.ask(model.question) }
                    .accessibilityLabel(L10n.text("Ask a follow-up"))
                    .padding(.trailing, 4)
                if model.session?.phase.isRunning == true {
                    PanelIcon(symbol: "stop.circle", title: "Stop", help: "Stop (⌘.)") { model.stop() }
                }
                PanelIcon(symbol: model.copied ? "checkmark" : "doc.on.doc", title: model.copied ? "Copied" : "Copy",
                          help: "Copy (⌘↩)", active: model.copied) { model.copy() }
                    .disabled(!hasAnswer)
                if model.offersNotes {
                    let saved = model.noteState == .saved
                    PanelIcon(symbol: saved ? "checkmark" : "square.and.arrow.down", title: saved ? "Saved to note" : "Save to note",
                              help: "Save to note (⌘S)", active: saved) { model.saveNote() }
                        .disabled(saved || !model.canSaveNote)
                }
            }
            if let message = model.followUpMessage {
                Text(message).font(FrogType.caption).foregroundStyle(FrogStyle.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 6)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
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
}

/// One of the panel's actions as a small icon, named for VoiceOver, with its shortcut on hover. An active one, such
/// as a pinned panel or a copied answer, takes the accent colour.
private struct PanelIcon: View {
    let symbol: String
    let title: String
    var help: String? = nil
    var active = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(active || (hovering && enabled) ? FrogStyle.accent : FrogStyle.muted)
                .frame(width: 24, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: FrogStyle.controlRadius))
        }
        .buttonStyle(.plain).opacity(enabled || active ? 1 : 0.4)
        .onHover { hovering = $0 }
        .help(L10n.text(help ?? title)).accessibilityLabel(L10n.text(title))
    }
}

/// An answer in the Notes renderer's blocks.
private struct AnswerMarkdown: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
