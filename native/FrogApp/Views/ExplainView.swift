import SwiftUI
import FrogCore

/// The Explain page: select text, press the shortcut, read the answer in a panel.
struct ExplainView: View {
    @ObservedObject var plugin: ExplainPlugin
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var notesFile = ""
    @State private var notesFileIssue: String?
    @FocusState private var editingFile: Bool

    private var settings: ExplainConfig { plugin.settings }
    private var bubbleOn: Bool { model.selectionBubble?.settings.on == true }

    var body: some View {
        FrogPage {
            FrogPageHeader(title: "Explain", subtitle: "Select text, press the shortcut, read the answer.")
            if let rule = plugin.rule {
                FrogSection {
                    FrogRow("Shortcut") { HotkeyRecorder(hotkey: ruleBinding(rule, \.hotkey)) }
                    if let issue = model.hotkeyErrors[rule.id] { FrogRowNote(text: issue, tone: FrogStyle.warning) }
                    FrogRow("Model") { RuleModelPicker(rule: Binding(get: { rule }, set: save)) }
                    FrogRow("Surrounding text", caption: "Sends the sentence around the selection too.") {
                        Toggle("Surrounding text", isOn: setting(\.context)).labelsHidden().toggleStyle(.switch)
                    }
                    if bubbleOn {
                        FrogRow("In the selection bubble") {
                            Toggle("In the selection bubble", isOn: ruleBinding(rule, \.showsInBubble)).labelsHidden().toggleStyle(.switch)
                        }
                    }
                }
                notes
            } else {
                FrogEmptyState(symbol: "questionmark.bubble", title: "No Explain rule", message: "Add it back to explain selected text.") {
                    Button("Add Explain") {
                        do { try plugin.addRule() } catch { model.report(error) }
                    }.buttonStyle(.frog(.primary))
                }
            }
        }
    }

    private var notes: some View {
        FrogSection("Notes") {
            FrogRow("Save to note", caption: "Adds Save to note to the answer panel.") {
                Toggle("Save to note", isOn: Binding(get: { settings.notes.on }, set: { value in
                    withAnimation(reduceMotion ? nil : FrogMotion.reveal) { update { $0.notes.on = value } }
                })).labelsHidden().toggleStyle(.switch)
            }
            if settings.notes.on {
                Group {
                    FrogRow("Folder", caption: settings.notes.folder ?? "None chosen") {
                        Button("Choose…") {
                            Task { do { _ = try await model.chooseAnswerNotesFolder() } catch { model.report(error) } }
                        }
                    }
                    FrogRow("Save as") {
                        FrogDropdown(selected: settings.notes.mode, options: ExplainConfig.NotesMode.allCases, width: 180,
                                     title: { $0 == .perAnswer ? "A note per answer" : "Added to one note" }) { mode in
                            update { $0.notes.mode = mode }
                        }
                    }
                    if settings.notes.mode == .append {
                        FrogRow("File", caption: notesFileIssue ?? "YYYY, MM and DD become the date.") {
                            TextField("Daily/YYYY-MM-DD.md", text: $notesFile)
                                .textFieldStyle(.plain).font(FrogType.body)
                                .padding(.horizontal, 8).frame(width: 200).frogControlSurface()
                                .focused($editingFile)
                                .onSubmit(saveNotesFile)
                                .onChange(of: editingFile) { _, editing in if !editing { saveNotesFile() } }
                                .onAppear { notesFile = settings.notes.file }
                                .onChange(of: settings.notes.file) { _, value in notesFile = value }
                                .accessibilityLabel("Notes file")
                        }
                    }
                    FrogRow("Open after saving") {
                        Toggle("Open after saving", isOn: setting(\.notes.open)).labelsHidden().toggleStyle(.switch)
                    }
                }.transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
    }

    private func setting(_ key: WritableKeyPath<ExplainConfig, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: key] }, set: { value in update { $0[keyPath: key] = value } })
    }

    private func ruleBinding<Value>(_ rule: Rule, _ key: WritableKeyPath<Rule, Value>) -> Binding<Value> {
        Binding(get: { rule[keyPath: key] }, set: { value in var updated = rule; updated[keyPath: key] = value; save(updated) })
    }

    private func save(_ rule: Rule) {
        do { try model.saveRule(rule) } catch { model.report(error) }
    }

    private func update(_ change: (inout ExplainConfig) -> Void) {
        var new = settings
        change(&new)
        do { try plugin.save(new) } catch { model.report(error) }
    }

    /// Keeps a valid file; an invalid one stays in the field with the reason below it.
    private func saveNotesFile() {
        let value = notesFile.trimmingCharacters(in: .whitespaces)
        guard value != settings.notes.file else { notesFileIssue = nil; return }
        do {
            _ = try AnswerNote.expand(pattern: value, date: Date(), calendar: .current)
            notesFileIssue = nil
            update { $0.notes.file = value }
        } catch {
            notesFileIssue = error.localizedDescription
        }
    }
}
