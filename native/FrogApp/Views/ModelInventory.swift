import SwiftUI
import FrogCore

struct ModelInventory: View {
    @EnvironmentObject private var model: AppModel
    let kind: LocalModelDescriptor.Kind
    var search = ""
    var revealedModelID: String?
    @State private var information: LocalModelDescriptor?
    private var inventory: [LocalModelDescriptor] {
        let visible = Set(model.localModels.progress.keys).union(model.localModels.errors.keys).union([revealedModelID].compactMap { $0 })
        return model.configuration.modelInventory(installed: model.localModels.installed, including: visible)
            .filter { $0.kind == kind && (search.isEmpty || ($0.name + " " + $0.repository).localizedStandardContains(search)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
        group("Downloaded", items: inventory.filter { model.localModels.installed.contains($0.id) }, installed: true)
        group("Available to download", items: inventory.filter { !model.localModels.installed.contains($0.id) }, installed: false)
        }.sheet(item: $information) { item in LocalModelInformation(item: item) }
    }
    private func group(_ title: String, items: [LocalModelDescriptor], installed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption(text: title)
            VStack(spacing: 0) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Image(systemName: installed ? "checkmark.circle.fill" : "arrow.down.circle").foregroundStyle(installed ? FrogStyle.accent : FrogStyle.muted)
                            VStack(alignment: .leading, spacing: 3) {
                                 HStack(spacing: 6) {
                                     Text(item.name).font(.system(size: 12, weight: .medium))
                                     if item.isRecommended { RecommendedModelBadge() }
                                 }
                                Text(item.size + (model.localModels.loaded.contains(item.id) ? " · In memory" : "")).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            IconAction(title: "Model information", symbol: "info.circle") { information = item }
                            if let progress = model.localModels.progress[item.id] {
                                ProgressView(value: progress).frame(width: 70)
                                Button("Cancel") { model.localModels.cancelDownload(item.id) }.controlSize(.small)
                            } else if installed {
                                Menu {
                                    Button("Delete download", role: .destructive) { Task { do { try await model.localModels.remove(item.id) } catch { model.report(error) } } }
                                        .disabled(model.localModels.busy || model.dictation.active)
                                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            } else {
                                Button("Download") { model.localModels.download(item) }.controlSize(.small).disabled(!LocalModels.supported)
                                if item.id.hasPrefix("hf-") {
                                    IconAction(title: "Remove model source", symbol: "minus.circle") {
                                        do { try model.removeLocalModelSource(item) } catch { model.report(error) }
                                    }
                                }
                            }
                        }
                        Text([item.runtimeName, item.languages].map(L10n.text).joined(separator: " · "))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .help(item.kind == .audio ? "Live preview uses repeated short audio chunks, not a continuous streaming decoder. Speed and accuracy are relative catalog guidance." : "Relative catalog guidance; performance depends on your Mac and input.")
                        if let error = model.localModels.errors[item.id] { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    }.padding(12)
                    if item.id != items.last?.id { Divider().opacity(0.5) }
                }
                if items.isEmpty { Text(L10n.text(installed ? "No downloaded models" : "No additional models")).font(.system(size: 11)).foregroundStyle(.secondary).padding(14).frame(maxWidth: .infinity, alignment: .leading) }
            }.frogTableSurface()
        }
    }
}
