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
    @State private var viewing: UUID?
    @State private var search = ""
    @State private var category: HistoryFilter?
    @State private var confirmClear = false
    @State private var deleting: HistoryItem?
    @State private var copiedID: UUID?
    private func hidden(_ entry: HistoryItem) -> Bool { (entry.requiresReveal || model.configuration.preferences.hideHistoryText) && !visibility.revealed.contains(entry.id) }

    private var allEntries: [HistoryItem] { HistoryFeed.items(saved: model.history, clipboard: clipboard.entries) }
    private var entries: [HistoryItem] { HistoryFeed.items(saved: model.history, clipboard: clipboard.entries, filter: category, search: search, revealed: visibility.revealed) }

    var body: some View {
        let displayedEntries = entries
        let lastEntryID = displayedEntries.last?.id
        VStack(alignment: .leading, spacing: 14) {
            if let viewing = allEntries.first(where: { $0.id == self.viewing }) {
                HStack {
                    Button { self.viewing = nil } label: { Label("History", systemImage: "arrow.left") }
                    Spacer()
                    if viewing.requiresReveal || model.configuration.preferences.hideHistoryText { revealButton(viewing) }
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
                            Text(entry.text).font(.system(size: 13)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(16).minimalScrollbars()
                    }
                }.frogTableSurface()
                    .onCopyCommand {
                        guard !hidden(viewing) else { return [] }
                        if viewing.clipboardEntry != nil { copy(viewing); return [] }
                        return [NSItemProvider(object: viewing.text as NSString)]
                    }
            } else {
            PageHeader(title: "History", subtitle: "") {
                HStack {
                    if !model.configuration.preferences.historyEnabled {
                        Button("Enable saved history") {
                            var preferences = model.configuration.preferences
                            preferences.historyEnabled = true
                            do { try model.savePreferences(preferences) } catch { model.report(error) }
                        }
                    }
                    Button("Clear all", systemImage: "trash", role: .destructive) { confirmClear = true }
                        .disabled(allEntries.isEmpty)
                }
            }
            ListToolbar(placeholder: "Search history", search: $search) {
                FilterTag(title: "All", selected: category == nil) { category = nil }
                ForEach(HistoryFilter.allCases) { value in
                    FilterTag(title: value.title, selected: category == value) { category = value }
                }
            }

            if allEntries.isEmpty {
                FrogEmptyState(symbol: "clock.arrow.circlepath", title: "No history yet",
                               message: model.configuration.preferences.historyEnabled
                               ? "Transformations and interrupted recordings will appear here."
                                : "Enable saved history or clipboard history in Shortcuts.")
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
            .onChange(of: model.configuration.preferences.hideHistoryText) { _, _ in visibility.revealed = [] }
            .onDisappear { visibility.revealed = []; deleting = nil }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in visibility.revealed = []; deleting = nil }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in visibility.revealed = [] }
            .onChange(of: allEntries.map(\.id)) { _, ids in
                visibility.revealed.formIntersection(ids)
                if let viewing, !ids.contains(viewing) { self.viewing = nil }
                if let deleting, deleting.clipboardEntry != nil, !ids.contains(deleting.id) { self.deleting = nil }
            }
            .task(id: copiedID) {
                guard copiedID != nil else { return }
                do { try await Task.sleep(for: .seconds(1.5)); copiedID = nil } catch { }
            }
            .confirmationDialog("Clear all local history?", isPresented: $confirmClear) {
                Button("Clear all history", role: .destructive) {
                    do { try model.clearHistory() } catch { model.report(error) }
                }
            } message: { Text("Saved originals and results will be deleted, and in-memory clipboard entries will be forgotten.") }
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
        HStack(spacing: 12) {
            Button { if item.requiresReveal { visibility.revealed.insert(item.id) }; viewing = item.id } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        FrogBadge(text: item.filter.title)
                        if item.clipboardEntry != nil { FrogBadge(text: "Memory only") }
                        Text(item.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10)).foregroundStyle(FrogStyle.muted).lineLimit(1)
                        Spacer()
                    }
                    if let saved = item.savedEntry { interruptionStatus(saved) }
                    Text(hidden(item) ? "•••••••• · Click to reveal" : item.text.isEmpty ? L10n.text("No transcript available") : HistoryPreview.text(item.text)).font(.system(size: 12)).foregroundStyle(FrogStyle.ink)
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Open full entry")
            if item.requiresReveal || model.configuration.preferences.hideHistoryText { revealButton(item) }
            IconAction(title: copiedID == item.id ? "Copied" : "Copy result", symbol: copiedID == item.id ? "checkmark" : "doc.on.doc") {
                copy(item); copiedID = item.id
            }.disabled(item.text.isEmpty)
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
