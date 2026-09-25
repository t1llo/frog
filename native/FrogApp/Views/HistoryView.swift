import SwiftUI
import FrogCore

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var viewing: HistoryEntry?
    @State private var search = ""
    @State private var confirmClear = false
    @State private var deleting: HistoryEntry?
    @State private var copiedID: UUID?

    private var entries: [HistoryEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.history }
        return model.history.filter { entry in
            [entry.ruleName, entry.originalText, entry.processedText, entry.providerName, entry.model]
                .contains { $0.localizedStandardContains(query) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "History", subtitle: "") {
                HStack {
                    Button("Clear all…", systemImage: "trash", role: .destructive) { confirmClear = true }
                        .disabled(model.history.isEmpty)
                }
            }
            ListToolbar(placeholder: "Search history", search: $search) {
                Text(L10n.text(model.configuration.preferences.historyEnabled ? "Recording on · On this Mac" : "Recording off"))
                    .font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                if !model.configuration.preferences.historyEnabled {
                    Button("Enable history") {
                        var preferences = model.configuration.preferences
                        preferences.historyEnabled = true
                        do { try model.savePreferences(preferences) } catch { model.report(error) }
                    }.fixedSize()
                }
            }

            if model.history.isEmpty {
                FrogEmptyState(symbol: "clock.arrow.circlepath", title: "No history yet",
                               message: model.configuration.preferences.historyEnabled
                               ? "Completed transformations will appear here."
                               : "Enable history to save future originals and results on this Mac.")
                Spacer(minLength: 0)
            } else if entries.isEmpty {
                FrogEmptyState(symbol: "magnifyingglass", title: "No matches", message: "Try another word or clear your search.")
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { item in
                            historyRow(item)
                            if item.id != entries.last?.id { Divider().opacity(0.5) }
                        }
                    }
                }
                .frogTableSurface()
            }
        }.padding(20)
            .onAppear { model.refreshHistory() }
            .sheet(item: $viewing) { HistoryDetail(entry: $0) }
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.ruleName).font(.system(size: 12, weight: .semibold)).foregroundStyle(FrogStyle.ink)
                        Text(item.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                    }.lineLimit(1)
                    Spacer()
                    }
                    Text(item.processedText).font(.system(size: 12)).foregroundStyle(FrogStyle.ink)
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help("View original and result")
            IconAction(title: copiedID == item.id ? "Copied" : "Copy result", symbol: copiedID == item.id ? "checkmark" : "doc.on.doc") {
                ViewActions.copy(item.processedText); copiedID = item.id
            }
            IconAction(title: "Delete entry", symbol: "trash", destructive: true) { deleting = item }
        }.padding(12)
    }
}

private struct HistoryDetail: View {
    let entry: HistoryEntry
    @Environment(\.dismiss) private var dismiss
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.ruleName).font(.system(size: 20, weight: .semibold))
                    Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text([entry.providerName, entry.model, entry.targetLanguage].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 11)).foregroundStyle(FrogStyle.muted).textSelection(.enabled)
            ScrollView {
                VStack(spacing: 14) {
                    textSection("Result", text: entry.processedText)
                    textSection("Original", text: entry.originalText)
                }.padding(1)
            }
        }.padding(20).frame(width: 560, height: 500).background(FrogStyle.canvas)
            .foregroundStyle(FrogStyle.ink).buttonStyle(FrogButtonStyle())
    }

    private func textSection(_ title: String, text: String) -> some View {
        FrogCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionCaption(text: title)
                    Spacer()
                    Button(L10n.text(copied == title ? "Copied" : "Copy"), systemImage: copied == title ? "checkmark" : "doc.on.doc") {
                        ViewActions.copy(text); copied = title
                    }.accessibilityLabel("Copy \(title.lowercased())")
                }
                Text(text).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
