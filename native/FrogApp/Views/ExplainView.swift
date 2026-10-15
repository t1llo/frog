import SwiftUI
import FrogCore

/// Answer rules and how answers behave.
struct ExplainView: View {
    @EnvironmentObject private var model: AppModel
    @State private var notesFile = ""
    @State private var notesFileIssue: String?
    @FocusState private var editingFile: Bool

    private var settings: ExplainSettings { model.configuration.preferences.explainSettings }

    var body: some View {
        RulesView(fixedCategory: .text, output: .panel) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsSection(title: "Settings") {
                    CompactRow(title: "Include surrounding text",
                               detail: "Sends the sentence or paragraph around the selection, up to 1,000 characters, so the answer fits the context.") {
                        Toggle("Include surrounding text", isOn: Binding(get: { settings.includeContext }, set: { value in
                            update { $0.includeContext = value }
                        })).labelsHidden().toggleStyle(.switch)
                    }
                    Divider()
                    CompactRow(title: "Save answers to notes",
                               detail: "Adds Save to note to the answer panel and to answers in History. Notes are Markdown files in a folder you choose, such as an Obsidian vault.") {
                        Toggle("Save answers to notes", isOn: Binding(get: { settings.notes }, set: { value in
                            update { $0.notes = value }
                        })).labelsHidden().toggleStyle(.switch)
                    }
                }
                if settings.notes { notesSection }
            }
        }
    }

    private var notesSection: some View {
        SettingsSection(title: "Notes") {
            CompactRow(title: "Folder", detail: settings.notesFolder ?? "No folder chosen") {
                Button("Choose…") {
                    Task {
                        do { try await model.chooseAnswerNotesFolder() } catch { model.report(error) }
                    }
                }
            }
            Divider()
            CompactRow(title: "Save as") {
                CompactSegments(values: ExplainSettings.NotesMode.allCases, selected: settings.notesMode, width: 260,
                                title: { $0 == .perAnswer ? "One note per answer" : "Add to one note" }) { mode in
                    update { $0.notesMode = mode }
                }
            }
            if settings.notesMode == .append {
                Divider()
                CompactRow(title: "File", detail: notesFileIssue ?? "Inside the notes folder. YYYY, MM and DD become today's date.") {
                    TextField("Daily/YYYY-MM-DD.md", text: $notesFile)
                        .textFieldStyle(.plain).font(.system(size: 11, design: .monospaced))
                        .frame(width: 200).padding(6)
                        .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: 5))
                        .focused($editingFile)
                        .onSubmit(saveNotesFile)
                        .onChange(of: editingFile) { _, editing in if !editing { saveNotesFile() } }
                        .onAppear { notesFile = settings.notesFile }
                        .onChange(of: settings.notesFile) { _, value in notesFile = value }
                        .accessibilityLabel("Notes file")
                }
            }
            Divider()
            CompactRow(title: "Open the note after saving",
                       detail: "In Obsidian when the folder is inside a vault, otherwise in your Markdown app.") {
                Toggle("Open the note after saving", isOn: Binding(get: { settings.notesOpen }, set: { value in
                    update { $0.notesOpen = value }
                })).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    /// Keeps a valid path; an invalid one stays in the field with the reason below it.
    private func saveNotesFile() {
        let value = notesFile.trimmingCharacters(in: .whitespaces)
        guard value != settings.notesFile else { notesFileIssue = nil; return }
        do {
            _ = try AnswerNote.expand(pattern: value, date: Date(), calendar: .current)
            notesFileIssue = nil
            update { $0.notesFile = value }
        } catch {
            notesFileIssue = error.localizedDescription
        }
    }

    private func update(_ change: (inout ExplainSettings) -> Void) {
        do {
            try model.updateToolkit { toolkit in
                var settings = toolkit.explain ?? ExplainSettings()
                change(&settings)
                toolkit.explain = settings.normalized
            }
        } catch { model.report(error) }
    }
}
