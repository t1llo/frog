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
