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
    private var choices: [RuleModelSelection] {
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
        item.providerID.flatMap { id in model.configuration.providers.first { $0.id == id }?.name } ?? "Downloaded in Frog"
    }
    var body: some View {
        Button {
            local = selected?.providerID == nil && selected != nil; search = ""; showing.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected?.providerID == nil ? "cpu" : "cloud").foregroundStyle(FrogStyle.muted)
                Text(selected.map(name) ?? "Choose a model").lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(FrogStyle.muted)
            }.font(.system(size: 11, weight: .medium)).padding(.horizontal, 9).frame(width: 220, height: 32)
                .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(FrogStyle.border.opacity(0.6)))
        }.buttonStyle(.plain).accessibilityLabel(speech ? "Speech model" : "Text model")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(spacing: 9) {
                    SearchBox(placeholder: "Find a model", text: $search)
                    CompactSegments(values: [true, false], selected: local, title: { $0 ? "Local" : "External" }) { local = $0 }
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(choices.filter { search.isEmpty || (name($0) + " " + source($0)).localizedStandardContains(search) }, id: \.self) { item in
                                Button { item.apply(to: &rule); showing = false } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(name(item)).font(.system(size: 12))
                                            Text(source(item)).font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                                        }
                                        Spacer()
                                        if selected == item { Image(systemName: "checkmark").foregroundStyle(FrogStyle.accent) }
                                    }.padding(8).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                            if choices.isEmpty { Text("Add models in Models to use them here.").font(.caption).foregroundStyle(FrogStyle.muted).padding(12) }
                        }
                    }.frame(maxHeight: 230)
                    Divider()
                    Button("No model selected") {
                        if speech { rule.action?.audioModelID = nil; rule.action?.audioProviderID = nil }
                        else { rule.providerID = nil; rule.model = ""; rule.action?.localTextModelID = nil }
                        showing = false
                    }.buttonStyle(.plain).font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.padding(10).frame(width: 300).foregroundStyle(FrogStyle.ink).background(FrogStyle.panelSurface)
            }
    }
}
