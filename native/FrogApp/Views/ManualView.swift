import SwiftUI
import FrogCore

struct ManualView: View {
    @EnvironmentObject private var model: AppModel
    @State private var text = ""
    @State private var ruleID: UUID?
    @State private var copied = false

    private var selectedRule: Rule? { model.configuration.rules.first { $0.id == ruleID } }
    private var providerAvailable: Bool {
        guard let rule = selectedRule, let id = rule.providerID ?? model.configuration.defaultProviderID else { return false }
        return model.configuration.providers.contains { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            EditorHeading(title: "Try text", subtitle: "Run a rule here without switching apps. Your result appears below.")
                .padding(-16)
            HStack {
                Picker("Rule", selection: $ruleID) {
                    Text("Select a rule").tag(UUID?.none)
                    ForEach(model.configuration.rules) { rule in
                        Text(rule.name + (rule.enabled ? "" : " (disabled)")).tag(Optional(rule.id))
                    }
                }.frame(maxWidth: 460).disabled(model.isProcessing)
                Spacer()
                if model.isProcessing {
                    Button("Cancel") { model.cancelProcessing() }
                } else {
                    Button { run() } label: { Label("Process text", systemImage: "sparkles") }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedRule?.enabled != true || !providerAvailable)
                        .help("Process text (Command–Return)")
                }
            }
            if model.configuration.rules.isEmpty {
                InlineIssue(message: "Create a writing rule in Rules to get started.")
            } else if selectedRule?.enabled == false {
                InlineIssue(message: "Enable this rule in Rules before running it.")
            } else if selectedRule != nil && !providerAvailable {
                InlineIssue(message: "Choose a default provider in Providers, or assign a provider to this rule.")
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Input").font(.headline)
                    Spacer()
                    Text("\(text.count) characters").font(.caption).foregroundStyle(.secondary)
                    Button("Clear") { text = "" }.disabled(text.isEmpty || model.isProcessing)
                }
                TextEditor(text: $text).font(.body).padding(6)
                    .background(.background).clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    .accessibilityLabel("Text to process").disabled(model.isProcessing)
            }.frame(minHeight: 150, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Result").font(.headline)
                    Spacer()
                    Button(copied ? "Copied" : "Copy result") { ViewActions.copy(model.manualResult); copied = true }
                        .disabled(model.manualResult.isEmpty)
                    Button("Use as input") { text = model.manualResult }
                        .disabled(model.manualResult.isEmpty || model.isProcessing)
                }
                ScrollView {
                    Text(model.manualResult.isEmpty ? "Processed text will appear here." : model.manualResult)
                        .foregroundStyle(model.manualResult.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Processed result")
            }.frame(minHeight: 150, maxHeight: .infinity)
            Text(model.configuration.preferences.historyEnabled ? "History recording is on. Successful requests are saved locally." : "History recording is off. This request will not be added to local history.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24)
        .onAppear { selectInitialRule() }
        .onChange(of: model.configuration.rules) { _, _ in selectInitialRule() }
        .onChange(of: model.manualResult) { _, _ in copied = false }
    }

    private func selectInitialRule() {
        if !model.configuration.rules.contains(where: { $0.id == ruleID }) {
            ruleID = model.configuration.rules.first(where: \.enabled)?.id
        }
    }

    private func run() {
        guard let ruleID else { return }
        copied = false
        model.processManual(text: text, ruleID: ruleID)
    }
}
