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
    /// The entry whose text was just copied from the header, so its button says Copied.
    @State private var copiedEntry: UUID?
    /// The row under the pointer, whose actions take the time's place.
    @State private var hoveredEntry: UUID?

    /// `viewing` opens one entry's detail rather than the list, for pictures of it.
    init(viewing: UUID? = nil) { _viewing = State(initialValue: viewing) }

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
        return FrogPage {
            FrogPageHeader(title: "History", subtitle: "Rewritten text, answers and recordings, kept on this Mac") {
                if !all.isEmpty {
                    IconMenu(title: "History actions", bordered: false) {
                        Button("Clear all", systemImage: "trash", role: .destructive) { confirmClear = true }
                    }
                }
            }
            if !preferences.historyEnabled, all.isEmpty {
                FrogEmptyState(symbol: HistoryPlugin.info.symbol, title: "History is off", message: "Turn it on to keep results on this Mac.",
                               tint: HistoryPlugin.info.tint) {
                    Button("Turn on") { setHistoryEnabled() }.buttonStyle(.frog(.primary))
                }
            } else {
                // The filters head the list as a section's heading would, a little apart from it.
                VStack(alignment: .leading, spacing: FrogStyle.space12) {
                    if !all.isEmpty {
                        ListToolbar(placeholder: "Search history", search: $search) {
                            CompactSegments(values: [nil] + filters.map(Optional.some), selected: filter,
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
                        FrogEmptyState(symbol: ExplainPlugin.info.symbol, title: "No answers yet", message: "Answers from Explain show here.",
                                       tint: ExplainPlugin.info.tint)
                    case _?:
                        FrogEmptyState(symbol: HistoryPlugin.info.symbol, title: "No history yet",
                                       message: "Rewritten text, answers and recordings show here.", tint: HistoryPlugin.info.tint)
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
                HStack(alignment: .top, spacing: 12) {
                    let feature = Self.feature(entry.kind)
                    PluginIconTile(symbol: feature.symbol, tint: feature.tint.color, size: .list)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            Text(entry.ruleName).font(FrogType.row).foregroundStyle(FrogStyle.ink).lineLimit(1)
                            Spacer(minLength: 8)
                            // The row's actions take the time's place while the pointer is over it.
                            RecentTimestampText(date: entry.timestamp)
                                .font(FrogType.caption).foregroundStyle(FrogStyle.muted).lineLimit(1)
                                .help(entry.timestamp.formatted(date: .complete, time: .shortened))
                                .opacity(hoveredEntry == entry.id ? 0 : 1)
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
        }
        // The actions sit on the title's line in the time's place, shown only while the pointer is over the row, so
        // a list of entries is not a column of copy icons. The context menu copies too.
        .overlay(alignment: .topTrailing) {
            if hoveredEntry == entry.id {
                HStack(spacing: 0) {
                    if preferences.hideHistoryText { revealButton(entry) }
                    CopyAction(title: "Copy result") { ViewActions.copy(entry.processedText) }.disabled(entry.processedText.isEmpty || hidden(entry))
                }.frame(height: 16)
            }
        }
        .onHover { inside in
            if inside { hoveredEntry = entry.id } else if hoveredEntry == entry.id { hoveredEntry = nil }
        }
        // Without a pointer the hover actions never show, so VoiceOver gets them as the row's own actions.
        .accessibilityActions {
            if !entry.processedText.isEmpty, !hidden(entry) { Button("Copy result") { ViewActions.copy(entry.processedText) } }
            if preferences.hideHistoryText { Button(hidden(entry) ? "Reveal text" : "Hide text") { toggleReveal(entry) } }
        }
        .padding(.horizontal, 8).padding(.vertical, 8).frogHoverRow()
            .contextMenu {
                Button("Open entry") { viewing = entry.id }
                Button("Copy", systemImage: "doc.on.doc") { ViewActions.copy(entry.processedText) }.disabled(entry.processedText.isEmpty || hidden(entry))
                if preferences.hideHistoryText {
                    Button(hidden(entry) ? "Reveal text" : "Hide text", systemImage: hidden(entry) ? "eye" : "eye.slash") { toggleReveal(entry) }
                }
                Button("Delete entry", systemImage: "trash", role: .destructive) { deleting = entry }
            }
    }

    // MARK: Detail

    private func detail(_ entry: HistoryEntry) -> some View {
        // The toolbar's Back and ⌘[ (and Escape) return to the list; the entry's name takes the toolbar's title.
        FrogPage {
            FrogPageHeader(title: entry.ruleName, subtitle: Self.detailSubtitle(entry)) {
                if preferences.hideHistoryText { revealButton(entry) }
                if entry.answer != nil, model.answerNotesEnabled, !hidden(entry) { noteButton(entry) }
                // One Copy for the page: the result, or the answer. The other texts copy from the menu.
                let copied = copiedEntry == entry.id
                Button(L10n.text(copied ? "Copied" : entry.answer != nil ? "Copy answer" : "Copy result"),
                       systemImage: copied ? "checkmark" : "doc.on.doc") {
                    ViewActions.copy(entry.processedText); copiedEntry = entry.id
                }.disabled(entry.processedText.isEmpty || hidden(entry))
                IconMenu(title: "Entry actions", bordered: false) {
                    if !entry.originalText.isEmpty {
                        Button(entry.answer != nil ? "Copy selection" : "Copy original", systemImage: "doc.on.doc") {
                            ViewActions.copy(entry.originalText)
                        }.disabled(hidden(entry))
                    }
                    if let followUps = entry.answer?.followUps, !followUps.isEmpty {
                        Button("Copy follow-ups", systemImage: "doc.on.doc") {
                            ViewActions.copy(followUps.map { "\($0.question)\n\n\($0.answer)" }.joined(separator: "\n\n"))
                        }.disabled(hidden(entry))
                    }
                    Button("Delete entry…", systemImage: "trash", role: .destructive) { deleting = entry }
                }
            }
            interruptionStatus(entry)
            Group {
                if hidden(entry) {
                    VStack(spacing: 12) {
                        Image(systemName: "eye.slash").foregroundStyle(FrogStyle.muted)
                        Button("Reveal text") { visibility.revealed.insert(entry.id) }
                    }.frame(maxWidth: .infinity).padding(32).frogTableSurface()
                } else {
                    HistoryDetail(entry: entry)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .onCopyCommand { hidden(entry) ? [] : [NSItemProvider(object: entry.processedText as NSString)] }
            if note?.id == entry.id, case .failed(let message) = note?.state { InlineIssue(message: message) }
        }.frogPageBack("history-entry-\(entry.id)", parent: "History", escapes: true) { viewing = nil }
    }

    /// When, and with what: "Today 13:14 · Ollama · llama3.2".
    static func detailSubtitle(_ entry: HistoryEntry) -> String {
        let source: [String] = entry.answer.map { [$0.application ?? ""] } ?? []
        return ([RecentTimestamp.text(entry.timestamp)] + source + [entry.providerName, entry.model, entry.targetLanguage])
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func setHistoryEnabled() {
        var preferences = model.configuration.preferences
        preferences.historyEnabled = true
        do { try model.savePreferences(preferences) } catch { model.report(error) }
    }

    /// The feature that made an entry, whose icon its row shows: Writing, Explain or Dictation.
    static func feature(_ filter: HistoryFilter) -> PluginInfo {
        switch filter { case .text: WritingPlugin.info; case .answers: ExplainPlugin.info; case .audio: DictationPlugin.info }
    }

    /// What made it: "Ollama · llama3.2". The row's tile already names the feature.
    static func metadata(_ filter: HistoryFilter, _ entry: HistoryEntry) -> String {
        [entry.providerName, entry.model].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private func interruptionStatus(_ entry: HistoryEntry) -> some View {
        if let label = entry.interruptionLabel {
            HStack(spacing: 8) {
                FrogBadge(text: label)
                if model.dictation?.recoveringHistoryIDs.contains(entry.id) == true {
                    FrogSpinner(size: .mini)
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
        IconAction(title: hidden(entry) ? "Reveal text" : "Hide text", symbol: hidden(entry) ? "eye" : "eye.slash") { toggleReveal(entry) }
    }

    private func toggleReveal(_ entry: HistoryEntry) {
        if visibility.revealed.contains(entry.id) { visibility.revealed.remove(entry.id) } else { visibility.revealed.insert(entry.id) }
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
    /// The comparison is worked out once per entry, not on every render.
    @State private var diffs = HistoryDiffMemo()

    var body: some View {
        VStack(alignment: .leading, spacing: FrogStyle.sectionSpacing) {
            if let answer = entry.answer {
                answerSections(answer)
            } else if entry.originalText.isEmpty {
                section("Result") { HistoryLongText(text: entry.processedText, lineSpacing: 4) }
            } else {
                changes
            }
        }
        .foregroundStyle(FrogStyle.ink).buttonStyle(FrogButtonStyle())
    }

    /// A rewrite: the original and the result side by side in one card, with what changed marked in both, so the
    /// two read against each other rather than one under the other.
    @ViewBuilder private var changes: some View {
        let diff = diffs.diff(for: entry)
        FrogSection("Changes") {
            if let diff { Text(diff.summary).font(FrogType.small.monospacedDigit()) }
            else if entry.originalText == entry.processedText { Text("No changes") }
        } content: {
            HStack(alignment: .top, spacing: FrogStyle.space16 + FrogStyle.space8) {
                column("Original") {
                    if let diff { text(diff.original) } else { HistoryLongText(text: entry.originalText, lineSpacing: 4) }
                }
                column("Result") {
                    if let diff { text(diff.result) } else { HistoryLongText(text: entry.processedText, lineSpacing: 4) }
                }
            }.padding(.vertical, FrogStyle.space8)
        }
    }

    private func column<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: FrogStyle.space6) {
            SectionCaption(text: title)
            content()
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func text(_ value: AttributedString) -> some View {
        Text(value).font(FrogType.lead).lineSpacing(4).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }

    /// An answer: the first answer, its follow-ups, then what was asked about.
    @ViewBuilder
    private func answerSections(_ answer: AnswerRecord) -> some View {
        section("Answer") { HistoryLongText(text: entry.processedText, lineSpacing: 4) }
        if !answer.followUps.isEmpty {
            section("Follow-ups") {
                VStack(alignment: .leading, spacing: FrogStyle.space16) {
                    ForEach(Array(answer.followUps.enumerated()), id: \.offset) { _, turn in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(turn.question).font(FrogType.bodyMedium).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            HistoryLongText(text: turn.answer, lineSpacing: 4)
                        }
                    }
                }
            }
        }
        section("Selection") { HistoryLongText(text: entry.originalText, lineSpacing: 4) }
        if let context = answer.context, !context.isEmpty {
            section("Context") { HistoryLongText(text: context, lineSpacing: 4) }
        }
    }

    /// A heading and the text in a card under it; copying is the page header's.
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        FrogSection(title) { content().padding(.vertical, FrogStyle.space12) }
    }
}

/// The last entry's `HistoryDiff`, kept while the same entry is shown.
@MainActor final class HistoryDiffMemo {
    private var key: (id: UUID, original: String, result: String)?
    private var value: HistoryDiff?

    func diff(for entry: HistoryEntry) -> HistoryDiff? {
        if let key, key.id == entry.id, key.original == entry.originalText, key.result == entry.processedText { return value }
        key = (entry.id, entry.originalText, entry.processedText)
        value = HistoryDiff(original: entry.originalText, result: entry.processedText)
        return value
    }
}

/// What a rewrite changed, word by word: insertions marked in the result, removals struck through in the original.
/// Only for texts short enough to compare at once; longer ones are shown plain, a page at a time.
struct HistoryDiff {
    let original: AttributedString
    let result: AttributedString
    /// Words taken out and put in, for the heading's count.
    let removedWords: Int
    let addedWords: Int

    static let maxLength = 8_000

    /// "3 words changed", with what was added or removed beyond that ("2 words changed · 1 added"), or one side when
    /// the other is none ("4 words removed").
    var summary: String {
        func words(_ count: Int) -> String { count == 1 ? L10n.text("1 word") : "\(count) \(L10n.text("words"))" }
        switch (removedWords, addedWords) {
        case (0, let added): return "\(words(added)) \(L10n.text("added"))"
        case (let removed, 0): return "\(words(removed)) \(L10n.text("removed"))"
        default:
            let changed = "\(words(min(removedWords, addedWords))) \(L10n.text("changed"))"
            if addedWords > removedWords { return "\(changed) · \(addedWords - removedWords) \(L10n.text("added"))" }
            if removedWords > addedWords { return "\(changed) · \(removedWords - addedWords) \(L10n.text("removed"))" }
            return changed
        }
    }

    init?(original: String, result: String) {
        guard !original.isEmpty, !result.isEmpty, original != result,
              original.count <= Self.maxLength, result.count <= Self.maxLength else { return nil }
        let old = Self.tokens(original), new = Self.tokens(result)
        let difference = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        removedWords = removed.filter { !old[$0].allSatisfy(\.isWhitespace) }.count
        addedWords = inserted.filter { !new[$0].allSatisfy(\.isWhitespace) }.count
        self.original = Self.attributed(old, marked: removed, color: FrogStyle.critical, strike: true)
        self.result = Self.attributed(new, marked: inserted, color: FrogStyle.good, strike: false)
    }

    /// Words and the spaces between them, so spacing survives and only words are marked.
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var currentIsSpace: Bool?
        for character in text {
            let space = character.isWhitespace
            if currentIsSpace != nil, space != currentIsSpace { tokens.append(current); current = "" }
            current.append(character); currentIsSpace = space
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func attributed(_ tokens: [String], marked: Set<Int>, color: Color, strike: Bool) -> AttributedString {
        var text = AttributedString()
        for (index, token) in tokens.enumerated() {
            var part = AttributedString(token)
            if marked.contains(index), !token.allSatisfy(\.isWhitespace) {
                part.backgroundColor = color.opacity(0.2)
                // A line under or through the word too, so a mark on one narrow letter ("I") still shows.
                if strike { part.swiftUI.strikethroughStyle = Text.LineStyle(pattern: .solid, color: color); part.foregroundColor = FrogStyle.muted }
                else { part.swiftUI.underlineStyle = Text.LineStyle(pattern: .solid, color: color) }
            }
            text += part
        }
        return text
    }
}
