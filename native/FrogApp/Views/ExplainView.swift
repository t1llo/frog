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
    @State private var pickerRequest = ModelPickerOpenRequest()

    private var settings: ExplainConfig { plugin.settings }
    private var bubbleOn: Bool { model.selectionBubble?.settings.on == true }

    var body: some View {
        FrogPage {
            FrogPageHeader(title: "Explain", subtitle: "Select text, press the shortcut, read the answer.")
            if let rule = plugin.rule {
                if !model.ruleHasModel(rule) {
                    ModelMissingNotice(feature: "Explain", speech: false) { pickerRequest.open(rule.id) }
                }
                FrogSection("Shortcut & model") {
                    FrogRow("Shortcut", caption: "Select text in any app, then press it.") { HotkeyRecorder(hotkey: ruleBinding(rule, \.hotkey)) }
                    if let issue = model.hotkeyErrors[rule.id] { FrogRowNote(text: issue, tone: FrogStyle.warning) }
                    // The notice above says Explain cannot answer yet; the picker's own mark shows where to fix it.
                    FrogRow("Model", caption: "Writes the answer.") {
                        RuleModelPicker(rule: Binding(get: { rule }, set: save))
                    }
                }
                FrogSection("Answer") {
                    FrogRow("Surrounding text", caption: "Also sends the sentence around the selection.") {
                        Toggle("Surrounding text", isOn: setting(\.context)).labelsHidden().toggleStyle(.frogSwitch).controlSize(.small)
                    }
                }
                bubble(rule)
                notes
            } else {
                FrogEmptyState(symbol: ExplainPlugin.info.symbol, title: "No Explain rule", message: "Add it back to explain selected text.",
                               tint: ExplainPlugin.info.tint) {
                    Button("Add Explain") {
                        do { try plugin.addRule() } catch { model.report(error) }
                    }.buttonStyle(.frog(.primary))
                }
            }
        }
        .environment(\.modelPickerOpenRequest, pickerRequest)
    }

    /// Whether Explain is one of the buttons in the selection bubble. The bubble itself is set up on the Writing page.
    @ViewBuilder private func bubble(_ rule: Rule) -> some View {
        FrogSection("Selection bubble") {
            if bubbleOn {
                FrogRow("Show Explain in the bubble", caption: "The bubble appears after you select text by dragging, double-clicking or with Shift and arrow keys. Turn it on, off or limit it on the Writing page.") {
                    Toggle("Show Explain in the bubble", isOn: ruleBinding(rule, \.showsInBubble)).labelsHidden().toggleStyle(.frogSwitch).controlSize(.small)
                }
            } else {
                // A notice, not a setting: the bubble is switched on the Writing page.
                FrogRow("The selection bubble is off", caption: "The shortcut works either way.") {
                    Button("Turn on in Writing") { model.toolkit.select(.feature(.writing)) }
                }
            }
        }
    }

    private var notes: some View {
        FrogSection("Notes") {
            FrogRow("Save to note", caption: "Adds a Save to note button to the answer panel.") {
                Toggle("Save to note", isOn: Binding(get: { settings.notes.on }, set: { value in
                    withAnimation(reduceMotion ? nil : FrogMotion.reveal) { update { $0.notes.on = value } }
                })).labelsHidden().toggleStyle(.frogSwitch).controlSize(.small)
            }
            if settings.notes.on {
                Group {
                    FrogRow("Folder", caption: settings.notes.folder ?? "No folder chosen yet") {
                        Button("Choose…") {
                            Task { do { _ = try await model.chooseAnswerNotesFolder() } catch { model.report(error) } }
                        }
                    }
                    FrogRow("Save as", caption: settings.notes.mode == .append ? "Each answer is added to the file below." : "Each answer becomes its own note.") {
                        FrogDropdown(selected: settings.notes.mode, options: ExplainConfig.NotesMode.allCases, width: 180,
                                     title: { $0 == .perAnswer ? "A note per answer" : "Added to one note" }) { mode in
                            update { $0.notes.mode = mode }
                        }
                    }
                    if settings.notes.mode == .append {
                        FrogRow("File", caption: notesFileIssue ?? "YYYY, MM and DD become the date.") {
                            FrogTextField(placeholder: "Daily/YYYY-MM-DD.md", text: $notesFile)
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
                    FrogRow("Open after saving", caption: "Opens the note in Obsidian when the folder is a vault.") {
                        Toggle("Open after saving", isOn: setting(\.notes.open)).labelsHidden().toggleStyle(.frogSwitch).controlSize(.small)
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
