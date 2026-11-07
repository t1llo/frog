import SwiftUI
import FrogCore

/// The answer next to a selection: one quiet line for the rule and its model, the answer and its follow-ups, a failure
/// or the limit with its fix, a field for the next question, and the shared footer band: what is happening on the
/// leading side ("Answering…" with a breathing dot) and the actions with their keys on the trailing side, Stop ⌘. and
/// Close esc while it runs, Copy ⌘↩, Save ⌘S and Close esc once it is done, as in every other panel.
struct AnswerPanelView: View {
    @ObservedObject var model: AnswerPanelModel
    @State private var contentHeight: CGFloat = 0
    @State private var chromeHeight: CGFloat = 0

    /// The answer scrolls once the panel reaches its tallest.
    /// The fade under the answer, which also adds its height as an empty margin below the last line.
    private static let fadeHeight: CGFloat = 20
    /// The answer and the fade's margin, so a short answer sits fully above the fade and never scrolls.
    private var scrollHeight: CGFloat { min(contentHeight + Self.fadeHeight, max(80, model.maxHeight - chromeHeight)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.leading, FrogStyle.cardPadding).padding(.trailing, FrogStyle.panelInset).padding(.vertical, FrogStyle.panelInset)
                .background(WindowDragRegion())
                .measured(ChromeHeightKey.self)
            // Before the first text and after a failure without any, the status line follows the header directly.
            if hasContent {
                ScrollViewReader { proxy in
                    ScrollView {
                        answer.padding(.horizontal, FrogStyle.cardPadding).padding(.top, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .measured(ContentHeightKey.self)
                    }
                    .scrollIndicators(.never)
                    .bottomScrollFade(height: Self.fadeHeight)
                    .frame(height: scrollHeight)
                    .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
                    // A follow-up's answer starts below the earlier ones, often out of sight in a full panel.
                    .onChange(of: model.session?.pendingQuestion) { _, question in
                        guard question != nil else { return }
                        withAnimation(FrogMotion.reveal) { proxy.scrollTo(Self.followUpID, anchor: .top) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                statusLine
                // A stop without any answer has nothing to ask about, copy or save. A failure without one offers only
                // its fix (Retry) on the status line: a field that could not be used until then only got in the way.
                if hasAnswer || model.session?.phase.isRunning == true { followUp }
                footer
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

    /// The rule, and the model with its provider ("gpt-5-mini · OpenAI"), the same way in every state.
    private var header: some View {
        HStack(spacing: 4) {
            // The rule as a popup's title, the model a muted line beside it on the same baseline.
            HStack(alignment: .firstTextBaseline, spacing: FrogStyle.space6) {
                Text(model.session?.ruleName ?? "").font(FrogType.section).foregroundStyle(FrogStyle.ink).layoutPriority(1)
                if let session = model.session, !session.modelName.isEmpty {
                    // The provider too, so an answer, or an error, reads against the service that gave it.
                    Text(session.modelLabel.isEmpty ? session.modelName : session.modelLabel).font(FrogType.small)
                        .truncationMode(.middle).help(session.modelLabel)
                }
            }
            Spacer(minLength: 8)
            // Close is in the footer with its key; the pin is the header's one control, as it belongs to the panel.
            let pinTitle = model.pinned ? "Stop keeping open" : "Keep open"
            PanelIcon(symbol: model.pinned ? "pin.fill" : "pin", title: pinTitle, active: model.pinned) { model.togglePin() }
        }
        .foregroundStyle(FrogStyle.muted).lineLimit(1)
    }

    @ViewBuilder private var answer: some View {
        if let session = model.session {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(session.turns.enumerated()), id: \.offset) { index, turn in
                    if index > 0 { question(turn.question) }
                    AnswerMarkdown(text: turn.answer)
                }
                if let pending = session.pendingQuestion, !session.turns.isEmpty { question(pending).id(Self.followUpID) }
                // The footer says the answer is still coming, so the text carries no marker of its own.
                if !session.partial.isEmpty { AnswerMarkdown(text: session.partial) }
            }
            .font(FrogType.body).lineSpacing(3)
            .textSelection(.enabled)
        }
    }

    private static let followUpID = "follow-up"

    /// Space sets each follow-up apart from the answer before it.
    private func question(_ text: String) -> some View {
        Text(text).font(FrogType.label).foregroundStyle(FrogStyle.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
    }

    /// How the answer ended when that needs saying (a failure, Stopped, the limit) with its fix; a note that could not
    /// be saved takes the line until the next action. While the answer runs, the footer says what is happening.
    @ViewBuilder private var statusLine: some View {
        if let session = model.session, !session.phase.isRunning || noteFailure != nil, let line = noteFailure ?? session.statusLine {
            HStack(spacing: 8) {
                if failed || noteFailure != nil {
                    Image(systemName: ProcessingIndicator.failureSymbol).font(FrogType.small).foregroundStyle(FrogStyle.warning)
                        .accessibilityHidden(true)
                }
                // The triangle carries the warning colour; the message stays readable in the text colour.
                Text(line).font(failed || noteFailure != nil ? FrogType.small : FrogType.caption)
                    .foregroundStyle(failed || noteFailure != nil ? FrogStyle.ink : FrogStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                switch noteFailure == nil ? model.recovery : nil {
                case .retry: Button(L10n.text("Retry")) { model.retry() }
                case .editRule: Button(L10n.text("Edit rule")) { model.editRule() }
                case .allowAccessibility: Button(L10n.text("Open System Settings")) { model.allowAccessibility() }
                case nil: EmptyView()
                }
            }
            .buttonStyle(.frog())
            .padding(.horizontal, FrogStyle.cardPadding).padding(.vertical, FrogStyle.panelInset)
            .accessibilityElement(children: .combine)
        }
    }

    /// The next question, the panel's full width. It stays enabled while the answer runs, so it keeps focus and the
    /// next question can be typed, then asked with Return once the answer is done.
    private var followUp: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The shared field, so its placeholder is the lighter placeholder grey in light as in dark.
            FrogTextField(placeholder: followUpPlaceholder, text: $model.question)
                .font(FrogType.row)
                .padding(.horizontal, FrogStyle.rowInset)
                .frogControlSurface(height: FrogStyle.controlHeight, radius: FrogStyle.controlRadius)
                .disabled(followUpBlocked || (failed && !hasAnswer))
                .onSubmit { model.ask(model.question) }
                .accessibilityLabel(L10n.text("Ask a follow-up"))
            if let message = model.followUpMessage {
                Text(message).font(FrogType.caption).foregroundStyle(FrogStyle.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // The field sits a panel inset from the edge, so its 10-point corners nest in the panel's 18.
        .padding(FrogStyle.panelInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The shared footer band. While the answer runs: what is happening and Stop; once it is done: Copy and, with
    /// notes on, Save, each turning into what it did ("Copied", "Saved"). Close always, last.
    private var footer: some View {
        let running = model.session?.phase.isRunning == true
        return FrogFooter {
            if running {
                PulseDot()
                Text(L10n.text(model.session?.statusLine ?? "Answering…"))
            }
        } actions: {
            if running {
                FrogFooterHint("Stop", keys: "⌘.") { model.stop() }
            } else {
                if hasAnswer { FrogFooterHint(model.copied ? "Copied" : "Copy", keys: "⌘↩") { model.copy() } }
                if model.offersNotes && hasAnswer {
                    if model.noteState == .saved { FrogFooterHint("Saved", keys: "") }
                    else if model.canSaveNote { FrogFooterHint("Save", keys: "⌘S") { model.saveNote() }.help(L10n.text("Save to note")) }
                }
            }
            FrogFooterHint("Close", keys: "esc") { model.close() }
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
}

/// One of the panel's actions as a small icon, named for VoiceOver, with its shortcut on hover: an `IconAction` at the
/// compact height, which keeps its own help text. An active one, such as a pinned panel or a copied answer, takes the
/// accent colour. With `label` the icon carries a short word after it, for an action its glyph alone does not name.
private struct PanelIcon: View {
    let symbol: String
    let title: String
    var label: String? = nil
    var help: String? = nil
    var active = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: FrogStyle.space4) {
                Image(systemName: symbol).font(.system(size: 12, weight: .regular))
                if let label { Text(L10n.text(label)).font(FrogType.small).lineLimit(1).fixedSize() }
            }
            .foregroundStyle(active ? FrogStyle.accentText : hovering && enabled ? FrogStyle.ink : FrogStyle.muted)
            .padding(.horizontal, label == nil ? 0 : FrogStyle.space8)
            .frame(minWidth: FrogStyle.compactHeight, minHeight: FrogStyle.compactHeight, maxHeight: FrogStyle.compactHeight)
            .frogRowHighlight(hovering: hovering && enabled)
        }
        .buttonStyle(.plain).opacity(enabled || active ? 1 : 0.4)
        .onHover { hovering = $0 }
        .help(L10n.text(help ?? title)).accessibilityLabel(L10n.text(title))
    }
}

/// A quiet dot that breathes while the answer is on its way; it holds still under Reduce Motion.
private struct PulseDot: View {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        // The repeating animation reaches the opacity only: scoped to the whole view it also carried the dot's first
        // position along, so it slid in from the panel's corner when the footer appeared.
        Circle().fill(FrogStyle.muted).frame(width: 6, height: 6)
            .animation(reduceMotion ? nil : FrogMotion.pulse) { $0.opacity(on || reduceMotion ? 0.9 : 0.35) }
            .onAppear { on = true }
            .accessibilityHidden(true)
    }
}

/// An answer in the Notes renderer's blocks: a list's items close together, and a list set apart from the paragraph
/// after it by more space than paragraphs keep, so the list reads as one group.
private struct AnswerMarkdown: View {
    let text: String
    var body: some View {
        let blocks = MarkdownPreview.blocks(text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                MarkdownBlockView(block: block).padding(.top, index == 0 ? 0 : Self.space(after: blocks[index - 1], before: block))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    static func space(after previous: MarkdownBlock, before block: MarkdownBlock) -> CGFloat {
        switch (previous.listDepth > 0, block.listDepth > 0) {
        case (true, true): FrogStyle.space4
        case (true, false): FrogStyle.space12
        default: FrogStyle.space6
        }
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
