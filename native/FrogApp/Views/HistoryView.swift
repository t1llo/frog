import SwiftUI
import FrogCore

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedID: UUID?
    @State private var confirmClear = false
    @State private var copied = false

    private var entry: HistoryEntry? { model.history.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            EditorHeading(title: "Local history", subtitle: model.configuration.preferences.historyEnabled
                          ? "Successful transformations are saved on this Mac, within your history limits."
                          : "Recording is off. Existing entries remain until deleted or expired.")
            if model.history.isEmpty {
                ContentUnavailableView(model.configuration.preferences.historyEnabled ? "No history yet" : "History recording is off",
                                       systemImage: "clock",
                                       description: Text(model.configuration.preferences.historyEnabled
                                                         ? "Run a writing rule to see its input, result, and model details here."
                                                         : "Enable recording in Settings if you want to keep future transformations on this Mac."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(model.history, selection: $selectedID) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.ruleName).font(.headline)
                            Text(item.processedText).lineLimit(2).foregroundStyle(.secondary)
                            Text(item.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 5).tag(item.id)
                    }.frame(minWidth: 190, idealWidth: 240, maxWidth: 300)
                    if let entry {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Text(entry.ruleName).font(.title2.bold())
                                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                                    GridRow { Text("Date").foregroundStyle(.secondary); Text(entry.timestamp.formatted(date: .abbreviated, time: .standard)) }
                                    GridRow { Text("Provider").foregroundStyle(.secondary); Text(entry.providerName) }
                                    GridRow { Text("Model").foregroundStyle(.secondary); Text(entry.model) }
                                    if !entry.targetLanguage.isEmpty {
                                        GridRow { Text("Language").foregroundStyle(.secondary); Text(entry.targetLanguage) }
                                    }
                                }.font(.callout).textSelection(.enabled)
                                Divider()
                                historyText("Original", text: entry.originalText)
                                historyText("Result", text: entry.processedText)
                            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(minWidth: 300)
                    } else {
                        ContentUnavailableView("Select an entry", systemImage: "text.magnifyingglass", description: Text("Inspect its original text, result, and details."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            Divider()
            HStack {
                Button("Refresh", systemImage: "arrow.clockwise") { model.refreshHistory() }
                Button("Clear all…", role: .destructive) { confirmClear = true }.disabled(model.history.isEmpty)
                Spacer()
                if let entry {
                    Button(copied ? "Copied" : "Copy result") { ViewActions.copy(entry.processedText); copied = true }
                    Button("Delete entry", role: .destructive) {
                        do { try model.deleteHistory(id: entry.id); selectedID = nil } catch { model.report(error) }
                    }
                }
            }.padding()
        }
        .onAppear { model.refreshHistory() }
        .onChange(of: selectedID) { _, _ in copied = false }
        .confirmationDialog("Clear all local history?", isPresented: $confirmClear) {
            Button("Clear all history", role: .destructive) {
                do { try model.clearHistory(); selectedID = nil } catch { model.report(error) }
            }
        } message: { Text("All saved originals and results will be permanently deleted from this Mac.") }
    }

    private func historyText(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Copy \(title.lowercased())") { ViewActions.copy(text) }
            }
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .padding(12).background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
