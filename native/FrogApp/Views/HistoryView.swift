import SwiftUI
import FrogCore

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var viewing: HistoryEntry?
    @State private var search = ""
    @State private var category: RuleCategory?
    @State private var confirmClear = false
    @State private var deleting: HistoryEntry?
    @State private var copiedID: UUID?

    private var entries: [HistoryEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.history.filter { entry in
            (category == nil || (entry.category ?? .text) == category) &&
            (query.isEmpty || [entry.ruleName, entry.originalText, entry.processedText, entry.providerName, entry.model]
                .contains { $0.localizedStandardContains(query) })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let viewing {
                HStack {
                    Button { self.viewing = nil } label: { Label("History", systemImage: "arrow.left") }
                    Spacer()
                    IconAction(title: "Delete entry", symbol: "trash", destructive: true) { deleting = viewing }
                }.frame(height: 32)
                PageHeader(title: viewing.ruleName, subtitle: viewing.timestamp.formatted(date: .abbreviated, time: .shortened))
                ScrollView {
                    HistoryDetail(entry: viewing).padding(16).minimalScrollbars()
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
                               ? "Completed transformations will appear here."
                               : "Enable history to save future originals and results on this Mac.")
                Spacer(minLength: 0)
            } else if entries.isEmpty {
                FrogEmptyState(symbol: "magnifyingglass", title: "No matches", message: "Try another filter or clear your search.")
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { item in
                            historyRow(item)
                            if item.id != entries.last?.id { Divider().opacity(0.5) }
                        }
                    }.minimalScrollbars()
                }
                .frogTableSurface()
            }
            }
        }.padding(20)
            .onAppear { model.refreshHistory() }
            .onChange(of: model.history.map(\.id)) { _, ids in
                if let viewing, !ids.contains(viewing.id) { self.viewing = nil }
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
            Button { viewing = item } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        FrogBadge(text: item.category == .audio ? "Audio" : "Text")
                        Text(item.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10)).foregroundStyle(FrogStyle.muted).lineLimit(1)
                        Spacer()
                    }
                    Text(item.processedText).font(.system(size: 12)).foregroundStyle(FrogStyle.ink)
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Open full entry")
            IconAction(title: copiedID == item.id ? "Copied" : "Copy result", symbol: copiedID == item.id ? "checkmark" : "doc.on.doc") {
                ViewActions.copy(item.processedText); copiedID = item.id
            }
            IconAction(title: "Delete entry", symbol: "trash", destructive: true) { deleting = item }
        }.padding(12)
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
                    }.accessibilityLabel("Copy \(title.lowercased())")
                }
                Text(text).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
    }
}
