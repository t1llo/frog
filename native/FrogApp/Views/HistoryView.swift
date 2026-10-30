import SwiftUI
import FrogCore

/// Frog's saved results: rewritten text, answers and dictation. Producers record through `AppModel.recordHistory`.
struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject var visibility = HistoryVisibility()
    @State private var filter: HistoryFilter?
    @State private var search = ""
    @State private var viewing: UUID?
    @State private var confirmClear = false
    @State private var deleting: HistoryEntry?
    @State private var note: NoteProgress?

    private var preferences: Preferences { model.configuration.preferences }
    /// With Hide history text on, texts stay masked until revealed, and are masked again when the page closes.
    private func hidden(_ entry: HistoryEntry) -> Bool { preferences.hideHistoryText && !visibility.revealed.contains(entry.id) }
    static let mask = String(repeating: "•", count: 12)

    var body: some View {
        // Built once per pass; the list shown is narrowed from it.
        let all = HistoryFeed.items(model.history)
        Group {
            if let entry = all.first(where: { $0.id == viewing }) { detail(entry) }
            else { list(all) }
        }
        .buttonStyle(FrogButtonStyle())
        .onAppear { model.refreshHistory() }
        .onChange(of: preferences.hideHistoryText) { _, _ in visibility.revealed = [] }
        .onChange(of: filter) { _, _ in visibility.revealed = [] }
        .onDisappear { visibility.revealed = []; deleting = nil }
        .background(WindowClosing { visibility.revealed = []; deleting = nil })
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in visibility.revealed = [] }
        .onChange(of: all.map(\.id)) { _, ids in
            visibility.revealed.formIntersection(ids)
            if let viewing, !ids.contains(viewing) { self.viewing = nil }
        }
        .confirmationDialog("Clear all history?", isPresented: $confirmClear) {
            Button("Clear all history", role: .destructive) {
                do { try model.clearHistory() } catch { model.report(error) }
            }
        } message: { Text("Saved originals and results are deleted from this Mac.") }
        .confirmationDialog("Delete this entry?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete entry", role: .destructive) {
                if let deleting { do { try model.deleteHistory(id: deleting.id) } catch { model.report(error) } }
                deleting = nil
            }
        }
    }

    // MARK: List

    private func list(_ all: [HistoryEntry]) -> some View {
        let shown = HistoryFeed.narrowed(all, filter: filter, search: search)
        let empty = HistoryEmptyState.describing(all: all, shown: shown, filter: filter, search: search)
        let filters = HistoryFilter.visible(explainEnabled: preferences.featureEnabled(.explain),
                                            hasAnswers: all.contains { $0.kind == .answers })
        return FrogPage(width: FrogStyle.wideWidth) {
            FrogPageHeader(title: "History") {
                IconMenu(title: "History actions") {
                    Button("Clear all", systemImage: "trash", role: .destructive) { confirmClear = true }.disabled(all.isEmpty)
                }
            }
            if !preferences.historyEnabled, all.isEmpty {
                FrogEmptyState(symbol: "clock.arrow.circlepath", title: "History is off", message: "Turn it on to keep results on this Mac.") {
                    Button("Turn on") { setHistoryEnabled() }.buttonStyle(.frog(.primary))
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if !all.isEmpty {
                        ListToolbar(placeholder: "Search history", search: $search) {
                            CompactSegments(values: [nil] + filters.map(Optional.some), selected: filter, width: 70 * CGFloat(filters.count + 1),
                                            title: { $0?.title ?? "All" }) { filter = $0 }
                        }
                    }
                    if !preferences.historyEnabled {
                        HStack(spacing: 8) {
                            FrogRowNote(text: "History is off. New results are not kept.")
                            Button("Turn on") { setHistoryEnabled() }.buttonStyle(.frog(compact: true))
                        }
                    }
                    switch empty {
                    case .noMatches?:
                        FrogEmptyState(symbol: "magnifyingglass", title: "No matches", message: "Try another word or filter.")
                    case .noAnswers?:
                        FrogEmptyState(symbol: "questionmark.bubble", title: "No answers yet", message: "Answers from Explain show here.")
                    case _?:
                        FrogEmptyState(symbol: "clock.arrow.circlepath", title: "No history yet",
                                       message: "Rewritten text, answers and recordings show here.")
                    case nil:
                        LazyVStack(spacing: 2) { ForEach(shown) { entry in row(entry) } }.padding(6).frogTableSurface()
                    }
                }
            }
        }
    }

    private func row(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 10) {
            Button { viewing = entry.id } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: Self.symbol(entry.kind))
                        .font(.system(size: 13)).foregroundStyle(FrogStyle.muted).frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            Text(entry.ruleName).font(FrogType.bodyMedium).foregroundStyle(FrogStyle.ink).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1)
                        }
                        Text(hidden(entry) ? "\(Self.mask) · Click to reveal"
                             : entry.processedText.isEmpty ? L10n.text("No transcript available") : HistoryPreview.text(entry.processedText))
                            .font(FrogType.body).foregroundStyle(FrogStyle.ink)
                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        Text(Self.metadata(entry.kind, entry)).font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1)
                        interruptionStatus(entry)
                    }
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Open entry")
            if preferences.hideHistoryText { revealButton(entry) }
            CopyAction(title: "Copy result") { ViewActions.copy(entry.processedText) }.disabled(entry.processedText.isEmpty || hidden(entry))
        }.padding(.horizontal, 8).padding(.vertical, 8).frogHoverRow()
            .contextMenu {
                Button("Open entry") { viewing = entry.id }
                Button("Copy", systemImage: "doc.on.doc") { ViewActions.copy(entry.processedText) }.disabled(entry.processedText.isEmpty || hidden(entry))
                Button("Delete entry", systemImage: "trash", role: .destructive) { deleting = entry }
            }
    }

    // MARK: Detail

    private func detail(_ entry: HistoryEntry) -> some View {
        FrogPage(width: FrogStyle.wideWidth) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button { viewing = nil } label: { Label("History", systemImage: "chevron.left") }
                        .buttonStyle(.frog(.ghost)).keyboardShortcut(.cancelAction)
                        // ⌘[ goes back too, through a button that is not drawn.
                        .background {
                            Button("Back to history") { viewing = nil }.keyboardShortcut("[", modifiers: .command)
                                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                        }
                    Spacer()
                    if preferences.hideHistoryText { revealButton(entry) }
                    if entry.answer != nil, model.answerNotesEnabled, !hidden(entry) { noteButton(entry) }
                    IconAction(title: "Delete entry", symbol: "trash", destructive: true) { deleting = entry }
                }.frame(height: FrogStyle.controlHeight)
                FrogPageHeader(title: entry.ruleName, subtitle: entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                interruptionStatus(entry)
                Group {
                    if hidden(entry) {
                        VStack(spacing: 12) {
                            Image(systemName: "eye.slash").foregroundStyle(FrogStyle.muted)
                            Button("Reveal text") { visibility.revealed.insert(entry.id) }
                        }.frame(maxWidth: .infinity).padding(32)
                    } else {
                        HistoryDetail(entry: entry).padding(14)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).frogTableSurface()
                    .onCopyCommand { hidden(entry) ? [] : [NSItemProvider(object: entry.processedText as NSString)] }
                if note?.id == entry.id, case .failed(let message) = note?.state { InlineIssue(message: message) }
            }
        }
    }

    private func setHistoryEnabled() {
        var preferences = model.configuration.preferences
        preferences.historyEnabled = true
        do { try model.savePreferences(preferences) } catch { model.report(error) }
    }

    static func symbol(_ filter: HistoryFilter) -> String {
        switch filter { case .text: "text.alignleft"; case .answers: "questionmark.bubble"; case .audio: "waveform" }
    }

    static func metadata(_ filter: HistoryFilter, _ entry: HistoryEntry) -> String {
        [filter.title, entry.providerName, entry.model].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private func interruptionStatus(_ entry: HistoryEntry) -> some View {
        if let label = entry.interruptionLabel {
            HStack(spacing: 8) {
                FrogBadge(text: label)
                if model.dictation.recoveringHistoryIDs.contains(entry.id) {
                    ProgressView().controlSize(.mini)
                    Text("Transcribing…")
                } else if entry.transcriptState == .failed {
                    Text("Transcription failed")
                } else if entry.transcriptState == .partial {
                    Text("Partial transcript")
                }
            }.font(FrogType.caption).foregroundStyle(FrogStyle.muted)
        }
    }

    /// Saves the answer and its follow-ups as a note; "Saved" shows for two seconds.
    private func noteButton(_ entry: HistoryEntry) -> some View {
        let state = note?.id == entry.id ? note?.state : nil
        return IconAction(title: state == .saved ? "Saved" : "Save to note", symbol: state == .saved ? "checkmark" : "square.and.arrow.down") {
            let content = AnswerNoteContent(entry: entry)
            note = NoteProgress(id: entry.id, state: .saving)
            Task {
                do {
                    _ = try await model.saveAnswerNote(content)
                    note = NoteProgress(id: entry.id, state: .saved)
                    try? await Task.sleep(for: .seconds(2))
                    if note == NoteProgress(id: entry.id, state: .saved) { note = nil }
                } catch is CancellationError {
                    note = nil
                } catch {
                    note = NoteProgress(id: entry.id, state: .failed(error.localizedDescription))
                }
            }
        }.disabled(state == .saving)
    }

    private func revealButton(_ entry: HistoryEntry) -> some View {
        IconAction(title: hidden(entry) ? "Reveal text" : "Hide text", symbol: hidden(entry) ? "eye" : "eye.slash") {
            if visibility.revealed.contains(entry.id) { visibility.revealed.remove(entry.id) } else { visibility.revealed.insert(entry.id) }
        }
    }
}

/// Reveal state is view-local and never part of saved application preferences.
@MainActor
final class HistoryVisibility: ObservableObject {
    @Published var revealed: Set<UUID> = []
}

/// A line limit clips drawing, but does not bound text layout work. Detail/search/copy
/// continue to use the original transcript; only list previews are shortened.
enum HistoryPreview {
    static func text(_ original: String) -> String {
        let prefix = original.prefix(513)
        return prefix.count > 512 ? String(prefix.prefix(512)) + "…" : String(prefix)
    }
}

/// Reports that the window holding the view closes. The settings window is kept after it
/// closes, so onDisappear does not run then. Other windows of the process close as well,
/// an update window for one, and must not count as this page closing.
struct WindowClosing: NSViewRepresentable {
    let closed: () -> Void
    func makeNSView(context: Context) -> ObserverView { ObserverView(closed: closed) }
    func updateNSView(_ view: ObserverView, context: Context) { view.closed = closed }
    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.observe(nil) }

    final class ObserverView: NSView {
        var closed: () -> Void
        private var observer: NSObjectProtocol?
        init(closed: @escaping () -> Void) { self.closed = closed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); observe(window) }

        /// Listens to `window` alone, and to nothing when the view has left its window.
        func observe(_ window: AnyObject?) {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.closed() }
            }
        }
        isolated deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}

/// What the page says in place of an empty list.
enum HistoryEmptyState: Equatable {
    case noHistory, noMatches, noAnswers

    /// "No matches" is for a filter or search that leaves nothing of an existing feed. The Answers filter without
    /// saved answers says how they get there. The feed trims the search, so spaces alone are no search.
    static func describing(all: [HistoryEntry], shown: [HistoryEntry], filter: HistoryFilter?, search: String) -> Self? {
        guard shown.isEmpty else { return nil }
        let searching = !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if filter == .answers, !searching, !all.contains(where: { $0.kind == .answers }) { return .noAnswers }
        return all.isEmpty ? .noHistory : .noMatches
    }
}

/// Laying out one text takes time that grows faster than its length: half a megabyte in a
/// single Text holds the window for many seconds. The detail shows a long text a page at a
/// time, each page a text of its own; copying and searching keep using the whole text.
enum HistoryPages {
    static let length = 20_000

    /// The first `count` pages of `text` and whether text remains after them.
    static func leading(_ text: String, count: Int) -> (pages: [Substring], more: Bool) {
        var pages: [Substring] = []
        var start = text.startIndex
        while pages.count < count, start < text.endIndex {
            let end = pageEnd(text, from: start)
            pages.append(text[start..<end]); start = end
        }
        return (pages, start < text.endIndex)
    }

    /// After a line end, otherwise after a space, otherwise between two characters. The cut is
    /// looked for in the last tenth of the page only, so no page is much shorter than the others.
    private static func pageEnd(_ text: String, from start: String.Index) -> String.Index {
        guard let limit = text.index(start, offsetBy: length, limitedBy: text.endIndex), limit < text.endIndex else { return text.endIndex }
        let tail = text[text.index(limit, offsetBy: -length / 10)..<limit]
        guard let cut = tail.lastIndex(where: \.isNewline) ?? tail.lastIndex(where: \.isWhitespace) else { return limit }
        return text.index(after: cut)
    }
}

struct HistoryLongText: View {
    let text: String
    var lineSpacing: CGFloat = 0
    @State private var shown = 1

    var body: some View {
        let leading = HistoryPages.leading(text, count: shown)
        VStack(alignment: .leading, spacing: lineSpacing) {
            ForEach(Array(leading.pages.enumerated()), id: \.offset) { _, page in
                // The next page starts on a new line, which stands for the line end that closes this one.
                Text(page.last?.isNewline == true ? page.dropLast() : page).font(FrogType.lead).lineSpacing(lineSpacing)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if leading.more {
                HStack(spacing: 10) {
                    Button("Show more") { shown += 1 }
                    Text("Long text is shown in parts. Copy takes all of it.").font(FrogType.small).foregroundStyle(FrogStyle.muted)
                }.padding(.top, 10)
            }
        }
    }
}

/// Save to note for one History entry.
private struct NoteProgress: Equatable {
    let id: UUID
    let state: AnswerController.NoteState
}

private struct HistoryDetail: View {
    let entry: HistoryEntry
    @State private var copied: String?

    var body: some View {
        // Sections are set apart by space and their captions.
        VStack(alignment: .leading, spacing: 20) {
            if let answer = entry.answer {
                answerSections(answer)
            } else {
                metadataLine([entry.providerName, entry.model, entry.targetLanguage])
                textSection("Result", text: entry.processedText)
                textSection("Original", text: entry.originalText)
            }
        }.padding(.top, 4)
            .foregroundStyle(FrogStyle.ink).buttonStyle(FrogButtonStyle())
    }

    private func metadataLine(_ parts: [String]) -> some View {
        Text(parts.filter { !$0.isEmpty }.joined(separator: " · "))
            .font(FrogType.small).foregroundStyle(FrogStyle.muted).textSelection(.enabled)
    }

    /// An answer: the first answer, its follow-ups, then what was asked about.
    @ViewBuilder
    private func answerSections(_ answer: AnswerRecord) -> some View {
        metadataLine([answer.application ?? "", entry.providerName, entry.model])
        textSection("Answer", text: entry.processedText)
        if !answer.followUps.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("Follow-ups", copying: answer.followUps.map { "\($0.question)\n\n\($0.answer)" }.joined(separator: "\n\n"))
                ForEach(Array(answer.followUps.enumerated()), id: \.offset) { _, turn in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(turn.question).font(FrogType.label).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        HistoryLongText(text: turn.answer, lineSpacing: 4)
                    }
                }
            }
        }
        textSection("Selection", text: entry.originalText)
        if let context = answer.context, !context.isEmpty {
            textSection("Context", text: context)
        }
    }

    private func textSection(_ title: String, text: String) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(title, copying: text)
                HistoryLongText(text: text, lineSpacing: 4)
            }
    }

    private func sectionHeader(_ title: String, copying text: String) -> some View {
        HStack {
            SectionCaption(text: title)
            Spacer()
            Button(L10n.text(copied == title ? "Copied" : "Copy"), systemImage: copied == title ? "checkmark" : "doc.on.doc") {
                ViewActions.copy(text); copied = title
            }.buttonStyle(.frog(compact: true)).accessibilityLabel("Copy \(title.lowercased())").disabled(text.isEmpty)
        }
    }
}
