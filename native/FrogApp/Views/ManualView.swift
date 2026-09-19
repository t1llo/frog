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
        PageScroll {
            PageHeader(title: "Room to play with words.", subtitle: "Drop in a draft. Pick a rule. See what happens.") {
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
                HStack(spacing: 16) {
                    SymbolTile(symbol: "wand.and.stars")
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Give it a direction").font(.system(size: 13, weight: .semibold))
                        Text("Your rule brings the instructions.").font(.system(size: 12)).foregroundStyle(FrogStyle.muted)
                    }
                    Spacer()
                    Picker("Writing rule", selection: $ruleID) {
                        Text("Select a rule").tag(UUID?.none)
                        ForEach(model.configuration.rules) { rule in
                            Text(rule.name + (rule.enabled ? "" : " (disabled)")).tag(Optional(rule.id))
                        }
                    }.labelsHidden().frame(width: 220).disabled(model.isProcessing)
                }
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
