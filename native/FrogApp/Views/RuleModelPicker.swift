import SwiftUI
import FrogCore

/// A rule's model: the searchable dropdown, with downloaded models and those of external providers in sections.
struct RuleModelPicker: View {
    @EnvironmentObject private var model: AppModel
    @Binding var rule: Rule
    var speech = false

    private var selected: RuleModelSelection? {
        if speech, let id = rule.action?.audioModelID { return .init(providerID: rule.action?.audioProviderID, modelID: id, category: .audio) }
        if !speech, let id = rule.action?.localTextModelID { return .init(modelID: id, category: .text) }
        if !speech, let id = rule.providerID, !rule.model.isEmpty { return .init(providerID: id, modelID: rule.model, category: .text) }
        return nil
    }
    private func choices(local: Bool) -> [RuleModelSelection?] {
        let kind: ProviderModel.Category = speech ? .audio : .text
        if local {
            return model.configuration.modelCatalog.filter { $0.kind == (speech ? .audio : .text) && model.localModels.installed.contains($0.id) }
                .map { .init(modelID: $0.id, category: kind) }
        }
        return model.configuration.providers.flatMap { provider in
            provider.models.filter { $0.category == kind }.map { .init(providerID: provider.id, modelID: $0.id, category: kind) }
        }
    }
    private func name(_ item: RuleModelSelection) -> String {
        if let id = item.providerID { return model.configuration.providers.first { $0.id == id }?.modelName(item.modelID) ?? item.modelID }
        return model.configuration.localModel(item.modelID)?.name ?? item.modelID
    }
    private func source(_ item: RuleModelSelection) -> String {
        if let id = item.providerID { return model.configuration.providers.first { $0.id == id }?.name ?? "External provider" }
        guard let descriptor = model.configuration.localModel(item.modelID) else { return "Downloaded in Frog" }
        let summary = speech ? descriptor.recommendationSummary ?? descriptor.languages : nil
        return [descriptor.downloadSize, descriptor.runtimeName, summary].compactMap { $0 }.joined(separator: " · ")
    }
    private func item(_ choice: RuleModelSelection?) -> FrogDropdownItem {
        guard let choice else { return FrogDropdownItem("No model") }
        let local = choice.providerID == nil
        let recommended = local && model.configuration.localModel(choice.modelID)?.isRecommended == true
        return FrogDropdownItem(name(choice), detail: source(choice), symbol: local ? "cpu" : "cloud",
                                badge: recommended ? "Recommended" : nil)
    }

    var body: some View {
        // A rule without a model cannot run: the button asks for one, led by a warning mark inside it, instead of
        // reading like an ordinary value. That mark is the control's one sign; the page says it once in a notice.
        dropdown(local: choices(local: true), external: choices(local: false))
    }

    private func dropdown(local: [RuleModelSelection?], external: [RuleModelSelection?]) -> some View {
        FrogDropdown(selected: selected, sections: [
            .init(values: [nil]),
            .init("Downloaded", values: local),
            .init("External", values: external)
        ], searchPrompt: "Find a model", listWidth: 380,
           footnote: local.isEmpty && external.isEmpty ? "Download a model or add a provider in Models to use it here." : nil,
           item: item, choose: { choice in
            if let choice { choice.apply(to: &rule) }
            else if speech { rule.action?.audioModelID = nil; rule.action?.audioProviderID = nil }
            else { rule.providerID = nil; rule.model = ""; rule.action?.localTextModelID = nil }
        })
        .buttonTitle { $0 == nil ? (speech ? "Choose a speech model" : "Choose a model") : item($0).title }
        .warning(selected == nil ? "This rule cannot run until it has a model" : nil)
        .accessibilityLabel(speech ? "Speech model" : "Text model")
    }
}

/// The mark beside a control whose value keeps a feature from working, such as a rule without a model.
struct ProblemMark: View {
    let help: String
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(FrogStyle.warning)
            .help(L10n.text(help)).accessibilityLabel(L10n.text(help))
    }
}

/// A notice above a page's sections that a feature will not work yet, with the one action that fixes it.
struct ProblemNotice<Action: View>: View {
    let title: String
    let message: String
    @ViewBuilder var action: Action
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 16)).foregroundStyle(FrogStyle.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(title)).font(FrogType.section).foregroundStyle(FrogStyle.ink)
                Text(L10n.text(message)).font(FrogType.small).foregroundStyle(FrogStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            action
        }
        .padding(.horizontal, FrogStyle.rowInset).padding(.vertical, FrogStyle.space12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: FrogStyle.cardRadius, style: .continuous).fill(FrogStyle.warning.opacity(0.12)))
        .accessibilityElement(children: .contain)
    }
}

/// "Explain won't work yet": shown above a feature's sections while its rule has no model. With nothing to choose
/// from, it leads to Models; otherwise the flagged Model row below is where to choose.
struct ModelMissingNotice: View {
    @EnvironmentObject private var model: AppModel
    let feature: String
    let speech: Bool
    var body: some View {
        let choices = model.hasModelChoices(speech: speech)
        ProblemNotice(title: "\(feature) won't work yet",
                      message: choices ? "Choose a \(speech ? "speech" : "text") model below."
                                       : "Download a \(speech ? "speech" : "text") model or connect a provider first.") {
            if !choices { Button("Open Models") { model.toolkit.select(.models) }.buttonStyle(.frog(.primary)) }
        }
    }
}

/// What a rule's model is called on its row and in agent answers.
@MainActor
extension AppModel {
    /// Whether the rule has a model it can run with.
    func ruleHasModel(_ rule: Rule) -> Bool {
        if rule.category == .application { return true }
        if rule.category == .audio { return rule.action?.audioModelID != nil }
        return (try? resolved(rule)) != nil
    }
    /// Whether any model of the kind is downloaded or offered by a provider, so a rule can choose one.
    func hasModelChoices(speech: Bool) -> Bool {
        let kind: ProviderModel.Category = speech ? .audio : .text
        return configuration.modelCatalog.contains { $0.kind == (speech ? .audio : .text) && localModels.installed.contains($0.id) }
            || configuration.providers.contains { $0.models.contains { $0.category == kind } }
    }
    func localModelLabel(_ id: String) -> String {
        (configuration.localModel(id)?.name ?? id) + (localModels.installed.contains(id) ? "" : " · Not downloaded")
    }
    func ruleModelLabel(_ rule: Rule) -> String {
        if rule.category == .application { return rule.action?.applicationPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Choose application" }
        if rule.category == .audio {
            guard let id = rule.action?.audioModelID else { return "Choose a speech model" }
            if let provider = configuration.providers.first(where: { $0.id == rule.action?.audioProviderID }) { return provider.name + " · " + provider.modelName(id) }
            return localModelLabel(id)
        }
        guard let provider = try? resolved(rule) else { return "Choose a text model" }
        return provider.id == Self.localProviderID ? localModelLabel(provider.model) : provider.name + " · " + provider.modelName(provider.model)
    }
}
