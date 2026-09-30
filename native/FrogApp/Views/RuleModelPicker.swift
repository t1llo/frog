import SwiftUI
import FrogCore

/// Search and source filtering share a compact, single-line closed control.
struct RuleModelPicker: View {
    @EnvironmentObject private var model: AppModel
    @Binding var rule: Rule
    var speech = false
    @State private var showing = false
    @State private var local = false
    @State private var search = ""

    private var selected: RuleModelSelection? {
        if speech, let id = rule.action?.audioModelID { return .init(providerID: rule.action?.audioProviderID, modelID: id, category: .audio) }
        if !speech, let id = rule.action?.localTextModelID { return .init(modelID: id, category: .text) }
        if !speech, let id = rule.providerID, !rule.model.isEmpty { return .init(providerID: id, modelID: rule.model, category: .text) }
        return nil
    }
    private func choices(local: Bool) -> [RuleModelSelection] {
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
        return descriptor.size + " · " + descriptor.runtimeName
    }
    var body: some View {
        Button {
            local = selected.map { $0.providerID == nil } ?? !choices(local: true).isEmpty
            search = ""; showing.toggle()
        } label: {
            CompactDropdownLabel(value: selected.map(name) ?? "Choose a model", symbol: selected?.providerID == nil ? "cpu" : "cloud")
        }.buttonStyle(.plain).accessibilityLabel(speech ? "Speech model" : "Text model")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(spacing: 9) {
                    let choices = choices(local: local)
                    let matches = choices.filter { search.isEmpty || (name($0) + " " + source($0)).localizedStandardContains(search) }
                    SearchBox(placeholder: "Find a model", text: $search)
                    CompactSegments(values: [true, false], selected: local, title: { $0 ? "Local" : "External" }) { local = $0; search = "" }
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(matches, id: \.self) { item in
                                Button { item.apply(to: &rule); showing = false } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack(spacing: 6) {
                                                Text(name(item)).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                                                if item.providerID == nil, model.configuration.localModel(item.modelID)?.isRecommended == true { RecommendedModelBadge() }
                                            }
                                            Text(source(item)).font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                                            if item.providerID == nil, let descriptor = model.configuration.localModel(item.modelID), speech {
                                                Text(descriptor.recommendationSummary ?? descriptor.languages).font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                                            }
                                        }
                                        Spacer()
                                        if selected == item { Image(systemName: "checkmark").foregroundStyle(FrogStyle.accent) }
                                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                            if matches.isEmpty {
                                Text(choices.isEmpty ? (local ? "No downloaded models. Download one in Models to use it here." : "No external models. Add a compatible model to a provider in Models.") : "No models match this search.")
                                    .font(.caption).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true).padding(12)
                            }
                        }
                    }.id(local).frame(height: 280)
                    Divider()
                    Button("No model selected") {
                        if speech { rule.action?.audioModelID = nil; rule.action?.audioProviderID = nil }
                        else { rule.providerID = nil; rule.model = ""; rule.action?.localTextModelID = nil }
                        showing = false
                    }.buttonStyle(.plain).font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.padding(12).frame(width: 420).foregroundStyle(FrogStyle.ink).background(FrogStyle.panelSurface)
            }
    }
}
