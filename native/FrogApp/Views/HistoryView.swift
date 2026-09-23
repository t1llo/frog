import SwiftUI
import FrogCore

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedID: UUID?
    @State private var confirmClear = false
    @State private var deleting: HistoryEntry?
    @State private var copied = false

    private var entry: HistoryEntry? { model.history.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "Words worth keeping.", subtitle: "A little look back at your writing. Stored on this Mac.") {
                HStack {
                    IconAction(title: "Refresh history", symbol: "arrow.clockwise") { refresh() }
                    Button("Clear history…", systemImage: "trash", role: .destructive) { confirmClear = true }
                        .disabled(model.history.isEmpty)
                }
            }
            HStack(spacing: 10) {
                SectionCaption(text: "\(model.history.count) saved \(model.history.count == 1 ? "entry" : "entries")")
                Spacer()
                FrogBadge(text: model.configuration.preferences.historyEnabled ? "Recording on" : "Recording off", active: model.configuration.preferences.historyEnabled)
            }
            if model.history.isEmpty {
                FrogCard {
                    VStack(spacing: 0) {
                        FrogEmptyState(symbol: "clock.arrow.circlepath",
                                       title: model.configuration.preferences.historyEnabled ? "A fresh start" : "A clean slate, by choice",
                                       message: model.configuration.preferences.historyEnabled
                                       ? "Your next successful transformation will appear here, along with its original text and model details."
                                       : "History is off. Enable it to keep future originals and results on this Mac.")
                        if !model.configuration.preferences.historyEnabled {
                            Button("Enable history", systemImage: "clock.arrow.circlepath") {
                                var preferences = model.configuration.preferences
                                preferences.historyEnabled = true
                                do { try model.savePreferences(preferences) } catch { model.report(error) }
                            }.buttonStyle(FrogButtonStyle(primary: true)).padding(.bottom, 24)
                        }
                    }
                }
                Spacer(minLength: 0)
            } else {
                HStack(alignment: .top, spacing: 18) {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(model.history) { item in historyItem(item) }
                        }.padding(2)
                    }.frame(width: 205)
                    if let entry {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                FrogCard {
                                    VStack(alignment: .leading, spacing: 15) {
                                        HStack(alignment: .top) {
                                            VStack(alignment: .leading, spacing: 6) {
                                                Text(entry.ruleName).font(.system(size: 20, weight: .semibold, design: .rounded))
                                                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                                                    .font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                                            }
                                            Spacer()
                                            IconAction(title: "Delete entry", symbol: "trash", destructive: true) { deleting = entry }
                                        }
                                        Rectangle().fill(FrogStyle.border).frame(height: 1)
                                        VStack(alignment: .leading, spacing: 8) {
                                            metadata("Provider", value: entry.providerName)
                                            metadata("Model", value: entry.model)
                                            if !entry.targetLanguage.isEmpty { metadata("Language", value: entry.targetLanguage) }
                                        }
                                    }
                                }
                                historyText("Original", text: entry.originalText, result: false)
                                historyText("Result", text: entry.processedText, result: true)
                            }.padding(2)
                        }.frame(maxWidth: .infinity)
                    } else {
                        FrogCard {
                            FrogEmptyState(symbol: "text.magnifyingglass", title: "Take a closer look", message: "Choose an entry to see the original, the result, and the model behind it.")
                        }
                    }
                }.frame(maxHeight: .infinity)
            }
        }.padding(32).background(FrogStyle.canvas)
            .onAppear { refresh() }
            .onChange(of: selectedID) { _, _ in copied = false }
            .onChange(of: model.history.map(\.id)) { _, ids in
                if selectedID.map({ !ids.contains($0) }) ?? true { selectedID = ids.first }
            }
            .confirmationDialog("Clear all local history?", isPresented: $confirmClear) {
                Button("Clear all history", role: .destructive) {
                    do { try model.clearHistory(); selectedID = nil } catch { model.report(error) }
                }
            } message: { Text("All saved originals and results will be permanently deleted from this Mac.") }
            .confirmationDialog("Delete this history entry?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete entry", role: .destructive) {
                    if let deleting { delete(deleting) }
                    deleting = nil
                }
            } message: { Text("The saved original and result will be permanently deleted from this Mac.") }
    }

    private func historyItem(_ item: HistoryEntry) -> some View {
        Button { selectedID = item.id } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "text.badge.checkmark").foregroundStyle(FrogStyle.accent)
                    Spacer()
                    Text(item.timestamp, format: .dateTime.month(.abbreviated).day())
                        .font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                }
                Text(item.ruleName).font(.system(size: 12, weight: .semibold)).foregroundStyle(FrogStyle.ink).lineLimit(1)
                Text(item.processedText).font(.system(size: 11)).lineSpacing(3).lineLimit(3).foregroundStyle(FrogStyle.muted)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(15)
                .background(selectedID == item.id ? FrogStyle.accentSoft : FrogStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selectedID == item.id ? FrogStyle.accent.opacity(0.5) : FrogStyle.border, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityAddTraits(selectedID == item.id ? .isSelected : [])
    }

    private func metadata(_ title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).foregroundStyle(FrogStyle.muted).frame(width: 60, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 11))
    }

    private func historyText(_ title: String, text: String, result: Bool) -> some View {
        FrogCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    SectionCaption(text: title)
                    Spacer()
                    Button(result && copied ? "Copied" : "Copy", systemImage: result && copied ? "checkmark" : "doc.on.doc") {
                        ViewActions.copy(text)
                        if result { copied = true }
                    }.accessibilityLabel("Copy \(title.lowercased())")
                }
                Text(text).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func refresh() {
        model.refreshHistory()
        if !model.history.contains(where: { $0.id == selectedID }) { selectedID = model.history.first?.id }
    }

    private func delete(_ entry: HistoryEntry) {
        do { try model.deleteHistory(id: entry.id); selectedID = model.history.first?.id } catch { model.report(error) }
    }
}
