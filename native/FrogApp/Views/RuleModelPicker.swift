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
        guard let choice else { return FrogDropdownItem("No model", symbol: "circle.slash") }
        let local = choice.providerID == nil
        let recommended = local && model.configuration.localModel(choice.modelID)?.isRecommended == true
        return FrogDropdownItem(name(choice), detail: source(choice), symbol: local ? "cpu" : "cloud",
                                badge: recommended ? "Recommended" : nil)
    }

    var body: some View {
        let local = choices(local: true), external = choices(local: false)
        FrogDropdown(selected: selected, sections: [
            .init(values: [nil]),
            .init("Downloaded", values: local),
            .init("External", values: external)
        ], searchPrompt: "Find a model", listWidth: 380,
           footnote: local.isEmpty && external.isEmpty ? "Download a model or add a provider in Models to use it here." : nil,
           item: item) { choice in
            if let choice { choice.apply(to: &rule) }
            else if speech { rule.action?.audioModelID = nil; rule.action?.audioProviderID = nil }
            else { rule.providerID = nil; rule.model = ""; rule.action?.localTextModelID = nil }
        }
        .accessibilityLabel(speech ? "Speech model" : "Text model")
    }
}

/// What a rule's model is called on its row and in agent answers.
@MainActor
extension AppModel {
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
