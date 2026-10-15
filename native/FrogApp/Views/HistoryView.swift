import SwiftUI
import FrogCore

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject var visibility = HistoryVisibility()
    var body: some View { HistoryContent(clipboard: model.clipboardHistoryStore, visibility: visibility) }
}

/// Reveal state is view-local and never part of saved application preferences.
@MainActor
final class HistoryVisibility: ObservableObject {
    @Published var revealed: Set<UUID> = []
}

private struct HistoryContent: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var clipboard: ClipboardHistoryStore
    @ObservedObject var visibility: HistoryVisibility
    private var clipboardSelected: Bool { model.historyFilter == .clipboard }
    @State private var viewing: UUID?
    @State private var search = ""
    @State private var confirmClear = false
    @State private var deleting: HistoryItem?
    @State private var copiedID: UUID?
    init(clipboard: ClipboardHistoryStore, visibility: HistoryVisibility) {
        self.clipboard = clipboard; self.visibility = visibility
    }
    private func hidden(_ entry: HistoryItem) -> Bool { (entry.requiresReveal || model.configuration.preferences.hideHistoryText) && !visibility.revealed.contains(entry.id) }

    private var allEntries: [HistoryItem] { HistoryFeed.items(saved: model.history, clipboard: clipboard.entries) }

    var body: some View {
        // Merged and sorted once per pass; the list shown is narrowed from it.
        let all = allEntries
        let displayedEntries = HistoryFeed.narrowed(all, filter: model.historyFilter, search: search, revealed: visibility.revealed)
        let lastEntryID = displayedEntries.last?.id
        let emptyState = HistoryEmptyState.describing(all: all, shown: displayedEntries, filter: model.historyFilter, search: search,
                                                      clipboardEnabled: model.configuration.preferences.featureEnabled(.clipboard))
        VStack(alignment: .leading, spacing: 14) {
            if let viewing = all.first(where: { $0.id == self.viewing }) {
                HStack {
                    Button { self.viewing = nil } label: { Label("History", systemImage: "arrow.left") }
                        .keyboardShortcut(.cancelAction)
                        // ⌘[ goes back too, through a button that is not drawn.
                        .background { Button("Back to history") { self.viewing = nil }.keyboardShortcut("[", modifiers: .command).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true) }
                    Spacer()
                    if viewing.requiresReveal || model.configuration.preferences.hideHistoryText { revealButton(viewing) }
                    // Actions for an answer entry go here, before Delete.
                    IconAction(title: "Delete entry", symbol: "trash", destructive: true) { deleting = viewing }
                }.frame(height: 32)
                PageHeader(title: viewing.title, subtitle: viewing.timestamp.formatted(date: .abbreviated, time: .shortened))
                if let saved = viewing.savedEntry { interruptionStatus(saved) }
                if viewing.clipboardEntry != nil { Text("Clipboard · Memory only · Cleared when disabled or Frog quits").font(.system(size: 11)).foregroundStyle(FrogStyle.muted) }
                ScrollView {
                    if hidden(viewing) {
                        VStack(spacing: 12) {
                            Image(systemName: "eye.slash").foregroundStyle(FrogStyle.muted)
                            Text("History text is hidden").font(.system(size: 12))
                            Button("Reveal text") { visibility.revealed.insert(viewing.id) }
                        }.frame(maxWidth: .infinity).padding(32)
                    } else if let saved = viewing.savedEntry { HistoryDetail(entry: saved).padding(16).minimalScrollbars() }
                    else if let entry = viewing.clipboardEntry {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                SectionCaption(text: entry.isSensitive ? "Sensitive copied text" : "Copied text")
                                Spacer()
                                Button("Copy") { copy(viewing) }
                            }
                            HistoryLongText(text: entry.text)
                        }.padding(16).minimalScrollbars()
                    }
                }.frogTableSurface()
                    .onCopyCommand {
                        guard !hidden(viewing) else { return [] }
                        if viewing.clipboardEntry != nil { copy(viewing); return [] }
                        return [NSItemProvider(object: viewing.text as NSString)]
                    }
            } else {
            PageHeader(title: "History", subtitle: clipboardSelected ? "Copied text, kept in memory only." : "Recent text, audio and clipboard activity.") {
                HStack {
                    if clipboardSelected {
                        Button("Clipboard settings") { model.openFeature(.clipboard) }
                    } else if !model.configuration.preferences.historyEnabled {
                        Button("Enable saved history") {
                            var preferences = model.configuration.preferences
                            preferences.historyEnabled = true
                            do { try model.savePreferences(preferences) } catch { model.report(error) }
                        }
                    }
                    Menu {
                        Button(clipboardSelected ? "Clear clipboard" : "Clear all", systemImage: "trash", role: .destructive) { confirmClear = true }
                            .disabled(clipboardSelected ? clipboard.entries.isEmpty : all.isEmpty)
                    } label: { Image(systemName: "ellipsis").frame(width: 26).modifier(CompactActionSurface()) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("History actions")
                }
            }
                ListToolbar(placeholder: "Search history", search: $search) {
                    FilterTag(title: "All", selected: model.historyFilter == nil) { model.historyFilter = nil }
                    ForEach(HistoryFilter.visible(explainEnabled: model.configuration.preferences.featureEnabled(.explain),
                                                  hasAnswers: all.contains { $0.filter == .answers })) { value in
                        FilterTag(title: value.title, selected: model.historyFilter == value) { model.historyFilter = value }
                    }
                }

            if emptyState == .noMatches {
                FrogEmptyState(symbol: "magnifyingglass", title: "No matches", message: "Try another filter or clear your search.")
                Spacer(minLength: 0)
            } else if emptyState == .noAnswers {
                FrogEmptyState(symbol: "questionmark.bubble", title: "No answers yet",
                               message: "With History on, answers from Explain and your other answer rules appear here.")
                Spacer(minLength: 0)
            } else if emptyState == .clipboardOff {
                FrogEmptyState(symbol: "clipboard", title: "Clipboard is off", message: "Enable Clipboard in Features to keep the text you copy here, in memory only.")
                Spacer(minLength: 0)
            } else if let emptyState {
                let copied = emptyState == .noCopiedText
                FrogEmptyState(symbol: copied ? "clipboard" : "clock.arrow.circlepath", title: copied ? "No copied text yet" : "No history yet",
                               message: copied ? "Copy text in any app to add it here. Items are cleared when Clipboard is disabled or Frog quits." : model.configuration.preferences.historyEnabled
                                ? "Transformations and interrupted recordings will appear here."
                                 : "Enable saved history in Settings or Clipboard in Features.")
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(displayedEntries) { item in
                            historyRow(item)
                                .overlay(alignment: .bottom) {
                                    if item.id != lastEntryID { Divider().opacity(0.5) }
                                }
                        }
                    }.minimalScrollbars()
                }
                .frogTableSurface()
            }
            }
        }.padding(20).frame(maxWidth: 1080).frame(maxWidth: .infinity, alignment: .top)
            .buttonStyle(FrogButtonStyle())
            .onAppear { model.refreshHistory() }
            .onChange(of: model.configuration.preferences.hideHistoryText) { _, _ in visibility.revealed = [] }
            .onChange(of: model.historyFilter) { _, _ in viewing = nil; visibility.revealed = []; search = "" }
            .onDisappear { visibility.revealed = []; deleting = nil }
            .background(WindowClosing { visibility.revealed = []; deleting = nil })
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in visibility.revealed = [] }
            .onChange(of: all.map(\.id)) { _, ids in
                visibility.revealed.formIntersection(ids)
                if let viewing, !ids.contains(viewing) { self.viewing = nil }
                if let deleting, deleting.clipboardEntry != nil, !ids.contains(deleting.id) { self.deleting = nil }
            }
            .task(id: copiedID) {
                guard copiedID != nil else { return }
                do { try await Task.sleep(for: .seconds(1.5)); copiedID = nil } catch { }
            }
            .confirmationDialog(clipboardSelected ? "Clear clipboard history?" : "Clear all local history?", isPresented: $confirmClear) {
                Button(clipboardSelected ? "Clear clipboard history" : "Clear all history", role: .destructive) {
                    if clipboardSelected { clipboard.clear() }
                    else { do { try model.clearHistory() } catch { model.report(error) } }
                }
            } message: { Text(clipboardSelected ? "Copied items will be removed from memory." : "Saved originals and results will be deleted, and in-memory clipboard entries will be forgotten.") }
            .confirmationDialog("Delete this history entry?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete entry", role: .destructive) {
                    if let deleting {
                        do { try model.deleteHistory(id: deleting.id) } catch { model.report(error) }
                    }
                    deleting = nil
                }
            } message: { Text(deleting?.clipboardEntry != nil ? "The copied item will be removed from memory." : "The saved original and result will be permanently deleted from this Mac.") }
    }

    private func historyRow(_ item: HistoryItem) -> some View {
        HStack(spacing: 10) {
            Button { if item.requiresReveal { visibility.revealed.insert(item.id) }; viewing = item.id } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: rowSymbol(item.filter))
                        .font(.system(size: 13)).foregroundStyle(FrogStyle.muted).frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            Text(item.clipboardEntry != nil ? (item.requiresReveal ? "Sensitive copied text" : "Copied text") : item.title)
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(FrogStyle.ink).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(item.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 10)).foregroundStyle(FrogStyle.muted).lineLimit(1)
                        }
                        Text(hidden(item) ? "•••••••• · Click to reveal" : item.text.isEmpty ? L10n.text("No transcript available") : HistoryPreview.text(item.text)).font(.system(size: 12)).foregroundStyle(FrogStyle.ink)
                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        Text(metadata(item)).font(.system(size: 10)).foregroundStyle(FrogStyle.muted).lineLimit(1)
                        if let saved = item.savedEntry { interruptionStatus(saved) }
                    }
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Open full entry")
            if item.requiresReveal || model.configuration.preferences.hideHistoryText { revealButton(item) }
            IconAction(title: copiedID == item.id ? "Copied" : "Copy result", symbol: copiedID == item.id ? "checkmark" : "doc.on.doc") {
                copy(item); copiedID = item.id
            }.disabled(item.text.isEmpty)
        }.padding(.horizontal, 12).padding(.vertical, 10)
            .contextMenu {
                Button("Open full entry") { if item.requiresReveal { visibility.revealed.insert(item.id) }; viewing = item.id }
                Button("Copy", systemImage: "doc.on.doc") { copy(item) }.disabled(item.text.isEmpty)
                Button("Delete entry", systemImage: "trash", role: .destructive) { deleting = item }
            }
    }
    private func rowSymbol(_ filter: HistoryFilter) -> String {
        switch filter { case .text: "text.alignleft"; case .answers: "questionmark.bubble"; case .audio: "waveform"; case .clipboard: "clipboard" }
    }
    private func metadata(_ item: HistoryItem) -> String {
        if let saved = item.savedEntry {
            return [item.filter.title, saved.providerName, saved.model].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return "Clipboard · Memory only"
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
            }.font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
        }
    }
    private func revealButton(_ entry: HistoryItem) -> some View {
        IconAction(title: hidden(entry) ? "Reveal text" : "Hide text", symbol: hidden(entry) ? "eye" : "eye.slash") {
            if visibility.revealed.contains(entry.id) { visibility.revealed.remove(entry.id) } else { visibility.revealed.insert(entry.id) }
        }
    }
    private func copy(_ item: HistoryItem) {
        if let entry = item.clipboardEntry {
            if !clipboard.copy(entry) { model.report(FrogError.message("Could not copy the clipboard item.")) }
        } else { ViewActions.copy(item.text) }
    }
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
    case noHistory, noCopiedText, clipboardOff, noMatches, noAnswers

    /// "No matches" is for a filter or search that leaves nothing of an existing feed. The
    /// Clipboard filter without copied items has nothing to match, also when saved history
    /// exists, and while Clipboard is off nothing copied can appear. The Answers filter without
    /// saved answers says how they get there. The feed trims the search, so spaces alone are no search.
    static func describing(all: [HistoryItem], shown: [HistoryItem], filter: HistoryFilter?, search: String, clipboardEnabled: Bool) -> Self? {
        guard shown.isEmpty else { return nil }
        if filter == .clipboard, !clipboardEnabled { return .clipboardOff }
        let searching = !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if filter == .answers, !searching, !all.contains(where: { $0.filter == .answers }) { return .noAnswers }
        if all.isEmpty { return filter == .clipboard ? .noCopiedText : .noHistory }
        return filter == .clipboard && !searching ? .noCopiedText : .noMatches
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

private struct HistoryLongText: View {
    let text: String
    var lineSpacing: CGFloat = 0
    @State private var shown = 1

    var body: some View {
        let leading = HistoryPages.leading(text, count: shown)
        VStack(alignment: .leading, spacing: lineSpacing) {
            ForEach(Array(leading.pages.enumerated()), id: \.offset) { _, page in
                // The next page starts on a new line, which stands for the line end that closes this one.
                Text(page.last?.isNewline == true ? page.dropLast() : page).font(.system(size: 13)).lineSpacing(lineSpacing)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if leading.more {
                HStack(spacing: 10) {
                    Button("Show more") { shown += 1 }
                    Text("Long text is shown in parts. Copy takes all of it.").font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                }.padding(.top, 10)
            }
        }
    }
}

private struct HistoryDetail: View {
    let entry: HistoryEntry
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let answer = entry.answer {
                answerSections(answer)
            } else {
                metadataLine([entry.providerName, entry.model, entry.targetLanguage])
                textSection("Result", text: entry.processedText)
                Divider().opacity(0.5)
                textSection("Original", text: entry.originalText)
            }
        }.padding(.top, 4)
            .foregroundStyle(FrogStyle.ink).buttonStyle(FrogButtonStyle())
    }

    private func metadataLine(_ parts: [String]) -> some View {
        Text(parts.filter { !$0.isEmpty }.joined(separator: " · "))
            .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).textSelection(.enabled)
    }

    /// An answer: the first answer, its follow-ups, then what was asked about.
    @ViewBuilder
    private func answerSections(_ answer: AnswerRecord) -> some View {
        metadataLine([answer.application ?? "", entry.providerName, entry.model])
        textSection("Answer", text: entry.processedText)
        if !answer.followUps.isEmpty {
            Divider().opacity(0.5)
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
        Divider().opacity(0.5)
        textSection("Selection", text: entry.originalText)
        if let context = answer.context, !context.isEmpty {
            Divider().opacity(0.5)
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
            }.accessibilityLabel("Copy \(title.lowercased())").disabled(text.isEmpty)
        }
    }
}
