import SwiftUI
import FrogCore

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var viewing: UUID?
    @State private var search = ""
    @State private var category: RuleCategory?
    @State private var confirmClear = false
    @State private var deleting: HistoryEntry?
    @State private var copiedID: UUID?
    @State private var revealed: Set<UUID> = []
    private func hidden(_ entry: HistoryEntry) -> Bool { model.configuration.preferences.hideHistoryText && !revealed.contains(entry.id) }

    private var entries: [HistoryEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.history.filter { entry in
            (category == nil || (entry.category ?? .text) == category) &&
            (query.isEmpty || [entry.ruleName, entry.originalText, entry.processedText, entry.providerName, entry.model, entry.interruptionLabel ?? ""]
                .contains { $0.localizedStandardContains(query) })
        }
    }

    var body: some View {
        let displayedEntries = entries
        let lastEntryID = displayedEntries.last?.id
        VStack(alignment: .leading, spacing: 14) {
            if let viewing = model.history.first(where: { $0.id == self.viewing }) {
                HStack {
                    Button { self.viewing = nil } label: { Label("History", systemImage: "arrow.left") }
                    Spacer()
                    if model.configuration.preferences.hideHistoryText { revealButton(viewing) }
                    IconAction(title: "Delete entry", symbol: "trash", destructive: true) { deleting = viewing }
                }.frame(height: 32)
                PageHeader(title: viewing.ruleName, subtitle: viewing.timestamp.formatted(date: .abbreviated, time: .shortened))
                interruptionStatus(viewing)
                ScrollView {
                    if hidden(viewing) {
                        VStack(spacing: 12) {
                            Image(systemName: "eye.slash").foregroundStyle(FrogStyle.muted)
                            Text("History text is hidden").font(.system(size: 12))
                            Button("Reveal text") { revealed.insert(viewing.id) }
                        }.frame(maxWidth: .infinity).padding(32)
                    } else { HistoryDetail(entry: viewing).padding(16).minimalScrollbars() }
                }.frogTableSurface()
                    .onCopyCommand { [NSItemProvider(object: viewing.processedText as NSString)] }
            } else {
            PageHeader(title: "History", subtitle: "") {
                HStack {
                    if !model.configuration.preferences.historyEnabled {
                        Button("Enable history") {
                            var preferences = model.configuration.preferences
                            preferences.historyEnabled = true
                            do { try model.savePreferences(preferences) } catch { model.report(error) }
                        }
                    }
                    Button("Clear all", systemImage: "trash", role: .destructive) { confirmClear = true }
                        .disabled(model.history.isEmpty)
                }
            }
            ListToolbar(placeholder: "Search history", search: $search) {
                FilterTag(title: "All", selected: category == nil) { category = nil }
                ForEach([RuleCategory.text, .audio]) { value in
                    FilterTag(title: value.title, selected: category == value) { category = value }
                }
            }

            if model.history.isEmpty {
                FrogEmptyState(symbol: "clock.arrow.circlepath", title: "No history yet",
                               message: model.configuration.preferences.historyEnabled
                               ? "Transformations and interrupted recordings will appear here."
                               : "Enable history to save future originals and results on this Mac.")
                Spacer(minLength: 0)
            } else if displayedEntries.isEmpty {
                FrogEmptyState(symbol: "magnifyingglass", title: "No matches", message: "Try another filter or clear your search.")
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
        }.padding(20)
            .onAppear { model.refreshHistory() }
            .onChange(of: model.configuration.preferences.hideHistoryText) { _, _ in revealed = [] }
            .onDisappear { revealed = [] }
            .onChange(of: model.history.map(\.id)) { _, ids in
                if let viewing, !ids.contains(viewing) { self.viewing = nil }
            }
            .task(id: copiedID) {
                guard copiedID != nil else { return }
                do { try await Task.sleep(for: .seconds(1.5)); copiedID = nil } catch { }
            }
            .confirmationDialog("Clear all local history?", isPresented: $confirmClear) {
                Button("Clear all history", role: .destructive) {
                    do { try model.clearHistory() } catch { model.report(error) }
                }
            } message: { Text("All saved originals and results will be permanently deleted from this Mac.") }
            .confirmationDialog("Delete this history entry?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete entry", role: .destructive) {
                    if let deleting {
                        do { try model.deleteHistory(id: deleting.id) } catch { model.report(error) }
                    }
                    deleting = nil
                }
            } message: { Text("The saved original and result will be permanently deleted from this Mac.") }
    }

    private func historyRow(_ item: HistoryEntry) -> some View {
        HStack(spacing: 12) {
            Button { viewing = item.id } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        FrogBadge(text: item.category == .audio ? "Audio" : "Text")
                        Text(item.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10)).foregroundStyle(FrogStyle.muted).lineLimit(1)
                        Spacer()
                    }
                    interruptionStatus(item)
                    Text(hidden(item) ? "••••••••••••" : item.processedText.isEmpty ? L10n.text("No transcript available") : item.processedText).font(.system(size: 12)).foregroundStyle(FrogStyle.ink)
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Open full entry")
            if model.configuration.preferences.hideHistoryText { revealButton(item) }
            IconAction(title: copiedID == item.id ? "Copied" : "Copy result", symbol: copiedID == item.id ? "checkmark" : "doc.on.doc") {
                ViewActions.copy(item.processedText); copiedID = item.id
            }.disabled(item.processedText.isEmpty)
            IconAction(title: "Delete entry", symbol: "trash", destructive: true) { deleting = item }
        }.padding(12)
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
    private func revealButton(_ entry: HistoryEntry) -> some View {
        IconAction(title: hidden(entry) ? "Reveal text" : "Hide text", symbol: hidden(entry) ? "eye" : "eye.slash") {
            if revealed.contains(entry.id) { revealed.remove(entry.id) } else { revealed.insert(entry.id) }
        }
    }
}

private struct HistoryDetail: View {
    let entry: HistoryEntry
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text([entry.providerName, entry.model, entry.targetLanguage].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).textSelection(.enabled)
            textSection("Result", text: entry.processedText)
            Divider().opacity(0.5)
            textSection("Original", text: entry.originalText)
        }.padding(.top, 4)
            .foregroundStyle(FrogStyle.ink).buttonStyle(FrogButtonStyle())
    }

    private func textSection(_ title: String, text: String) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionCaption(text: title)
                    Spacer()
                    Button(L10n.text(copied == title ? "Copied" : "Copy"), systemImage: copied == title ? "checkmark" : "doc.on.doc") {
                        ViewActions.copy(text); copied = title
                    }.accessibilityLabel("Copy \(title.lowercased())").disabled(text.isEmpty)
                }
                Text(text).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
    }
}

private extension HistoryEntry {
    var interruptionLabel: String? {
        switch interruption {
        case .escape: "Interrupted · Esc"
        case .cancelled: "Interrupted"
        case nil: nil
        }
    }
}
