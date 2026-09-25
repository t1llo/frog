import SwiftUI
import FrogCore

struct ManualView: View {
    @EnvironmentObject private var model: AppModel
    @State private var text = ""
    @State private var ruleID: UUID?
    @State private var copied = false
    @State private var providerID: UUID?
    @State private var modelID: String?

    private var selectedRule: Rule? { model.configuration.rules.first { $0.id == ruleID } }
    private var providerAvailable: Bool {
        selectedProvider != nil
    }

    private var selectedProvider: ProviderConfiguration? {
        model.configuration.providers.first { $0.id == (providerID ?? selectedRule?.providerID ?? model.configuration.defaultProviderID) }
    }

    private var selectedModelID: String {
        modelID ?? (providerID == nil && selectedRule?.model.isEmpty == false ? selectedRule!.model : selectedProvider?.model ?? "")
    }

    var body: some View {
        PageScroll {
            PageHeader(title: "Try text", subtitle: "Paste a draft, choose a rule, and review the result.") {
                if model.isProcessing {
                    Button("Cancel request") { model.cancelProcessing() }
                } else {
                    Button { run() } label: { Label("Transform", systemImage: "sparkles") }
                        .buttonStyle(FrogButtonStyle(primary: true))
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedRule?.enabled != true || !providerAvailable)
                        .help("Process text (Command–Return)")
                }
            }
            FrogCard {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Give it a direction").font(.system(size: 13, weight: .semibold))
                    FrogMenu(title: "Writing rule", value: selectedRule?.name ?? "Select a rule") {
                        ForEach(model.configuration.rules) { rule in
                            Button(rule.name + (rule.enabled ? "" : " (disabled)")) {
                                ruleID = rule.id; providerID = nil; modelID = nil
                            }.disabled(!rule.enabled)
                        }
                    }
                    HStack(alignment: .top, spacing: 16) {
                        FrogMenu(title: "Provider", value: selectedProvider?.name ?? "Choose a provider") {
                            Button("Use rule’s provider") { providerID = nil; modelID = nil }
                            ForEach(model.configuration.providers) { provider in
                                Button(provider.name) { providerID = provider.id; modelID = nil }
                            }
                        }
                        FrogMenu(title: "Model", value: selectedProvider?.modelName(selectedModelID) ?? "Choose a model") {
                            if let provider = selectedProvider {
                                ForEach(provider.models) { choice in Button(choice.name) { modelID = choice.id } }
                            }
                        }.disabled(selectedProvider == nil)
                    }
                    Text("These choices apply to this draft only; your saved rule stays the same.").font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                }.disabled(model.isProcessing)
            }
            if model.configuration.rules.isEmpty {
                InlineIssue(message: "Create a writing rule in Rules to get started.")
            } else if selectedRule?.enabled == false {
                InlineIssue(message: "Enable this rule in Rules before running it.")
            } else if selectedRule != nil && !providerAvailable {
                InlineIssue(message: "Choose a default provider in Providers, or assign a provider to this rule.")
            }
            VStack(spacing: 16) {
                FrogCard(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            SectionCaption(text: "Your draft")
                            Spacer()
                            Text("\(text.count) characters").font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                            Button("Clear") { text = "" }.buttonStyle(.plain).foregroundStyle(FrogStyle.muted)
                                .disabled(text.isEmpty || model.isProcessing).padding(.leading, 10)
                        }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
                        ZStack(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("A rough draft, a tricky sentence, an email that needs a little care…")
                                    .font(.system(size: 14)).foregroundStyle(FrogStyle.muted).padding(.horizontal, 5).padding(.top, 1)
                                    .allowsHitTesting(false).accessibilityHidden(true)
                            }
                            TextEditor(text: $text).font(.system(size: 14)).lineSpacing(5).scrollContentBackground(.hidden)
                                .frame(minHeight: 155).accessibilityLabel("Text to process").disabled(model.isProcessing)
                        }.padding(.horizontal, 16).padding(.bottom, 20)
                    }
                }
                FrogCard(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            HStack(spacing: 8) {
                                Image(systemName: "sparkles").foregroundStyle(FrogStyle.accent)
                                SectionCaption(text: "A fresh take")
                                if model.isProcessing { ProgressView().controlSize(.mini) }
                            }
                            Spacer()
                            if !model.manualResult.isEmpty {
                                Button("Use as input") { text = model.manualResult }.disabled(model.isProcessing)
                                Button(copied ? "Copied" : "Copy result", systemImage: copied ? "checkmark" : "doc.on.doc") {
                                    ViewActions.copy(model.manualResult); copied = true
                                }
                            }
                        }.padding(20)
                        if model.manualResult.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "text.alignleft").font(.system(size: 24, weight: .light))
                                Text(model.isProcessing ? "Finding the right words…" : "Your transformed text will land here.").font(.system(size: 13))
                            }.foregroundStyle(FrogStyle.muted).frame(maxWidth: .infinity, minHeight: 130).padding(.bottom, 20)
                        } else {
                            Text(model.manualResult).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                                .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
                                .padding(.horizontal, 20).padding(.bottom, 20).accessibilityLabel("Processed result: \(model.manualResult)")
                        }
                    }
                }
            }
            HStack {
                Label(model.configuration.preferences.historyEnabled ? "Saved to your local history" : "History is off. This draft won’t be saved.", systemImage: model.configuration.preferences.historyEnabled ? "clock" : "lock")
                Spacer()
                ShortcutBadge(text: "⌘ ↩")
                Text("to transform")
            }.font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
        }
        .onAppear { selectInitialRule() }
        .onChange(of: model.configuration.rules) { _, _ in selectInitialRule() }
        .onChange(of: model.manualResult) { _, _ in copied = false }
        .onChange(of: model.configuration.providers) { _, _ in
            if !model.configuration.providers.contains(where: { $0.id == providerID }) { providerID = nil }
            if selectedProvider?.models.contains(where: { $0.id == selectedModelID }) != true { modelID = nil }
        }
    }

    private func selectInitialRule() {
        if !model.configuration.rules.contains(where: { $0.id == ruleID }) {
            ruleID = model.configuration.rules.first(where: \.enabled)?.id
        }
    }

    private func run() {
        guard let ruleID else { return }
        copied = false
        model.processManual(text: text, ruleID: ruleID, providerID: providerID, modelID: modelID)
    }
}
