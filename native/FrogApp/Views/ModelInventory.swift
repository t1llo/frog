import SwiftUI
import FrogCore

struct ModelInventory: View {
    @EnvironmentObject private var model: AppModel
    /// One kind, or every model with speech and text under their own headings.
    var kind: LocalModelDescriptor.Kind? = nil
    var search = ""
    var revealedModelID: String?
    @State private var information: LocalModelDescriptor?
    @State private var deleting: LocalModelDescriptor?
    private var deletion: ModelDeletionPrompt? {
        deleting.map { ModelDeletionPrompt($0, configuration: model.configuration, installed: model.localModels.installed) }
    }
    private var inventory: [LocalModelDescriptor] {
        let visible = Set(model.localModels.progress.keys).union(model.localModels.errors.keys).union(model.localModels.unfinished).union([revealedModelID].compactMap { $0 })
        return model.configuration.modelInventory(installed: model.localModels.installed, including: visible)
            .filter { (kind == nil || $0.kind == kind) && (search.isEmpty || ($0.name + " " + $0.repository).localizedStandardContains(search)) }
    }
    var body: some View {
        let inventory = inventory
        let available = inventory.filter { !model.localModels.installed.contains($0.id) }
        VStack(alignment: .leading, spacing: FrogStyle.sectionSpacing) {
            // Nothing downloaded is said by the lists below, not by an empty card of its own.
            let downloaded = inventory.filter { model.localModels.installed.contains($0.id) }
            if !downloaded.isEmpty { group("Downloaded", items: downloaded, installed: true) }
            if kind == nil {
                group("Speech models", items: available.filter { $0.kind == .audio }, installed: false)
                group("Text models", items: available.filter { $0.kind == .text }, installed: false)
            } else {
                group("Available to download", items: available, installed: false)
            }
        }.sheet(item: $information) { item in LocalModelInformation(item: item) }
        .confirmationDialog(deletion?.title ?? "Delete download?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete download", role: .destructive) {
                guard let item = deleting else { return }
                deleting = nil
                Task { do { try await model.deleteLocalModel(item) } catch { model.report(error) } }
            }
        } message: { Text(deletion?.message ?? "") }
    }
    private func group(_ title: String, items: [LocalModelDescriptor], installed: Bool) -> some View {
        // Headed like a `FrogSection`, so every heading on the page has one size.
        VStack(alignment: .leading, spacing: FrogStyle.space10) {
            FrogSectionHeader(title) {
                // What the downloads listed here take on disk together.
                if installed, let total = model.localModels.totalDiskUse(of: items.map(\.id)) {
                    Text(LocalModelDescriptor.byteCount(total))
                }
            }
            VStack(spacing: 2) {
                ForEach(items) { item in
                    let unfinished = !installed && model.localModels.progress[item.id] == nil && model.localModels.unfinished.contains(item.id)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            // The same tile as in setup, one per runtime.
                            PluginIconTile(mark: .model(item))
                            // The heading says whether it is downloaded and the button what it does, so no glyph repeats it.
                            // One line of facts; the runtime and the guidance are in the help and the information sheet.
                            VStack(alignment: .leading, spacing: 2) {
                                // One line height with or without the badge, so every row is as tall as the next.
                                HStack(spacing: 6) {
                                    Text(item.name).font(FrogType.row)
                                    if item.isRecommended { RecommendedModelBadge() }
                                }.frame(height: 16)
                                Text([installed && kind == nil ? (item.kind == .audio ? "Speech" : "Text") : "",
                                      installed ? model.localModels.size(of: item) : item.downloadSize,
                                      model.localModels.loaded.contains(item.id) ? "In memory" : "", unfinished ? "Partly downloaded" : "",
                                      L10n.text(item.recommendationSummary ?? item.languages)].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(FrogType.small).foregroundStyle(FrogStyle.muted).lineLimit(1).truncationMode(.tail)
                                    .help([item.runtimeName, item.languages, item.kind == .audio ? "Live preview uses repeated short audio chunks, not a continuous streaming decoder. Speed and accuracy are relative catalog guidance." : "Relative catalog guidance; performance depends on your Mac and input."].filter { !$0.isEmpty }.joined(separator: " · "))
                            }
                            Spacer()
                            IconAction(title: "Model information", symbol: "info.circle") { information = item }
                            if let progress = model.localModels.progress[item.id] {
                                ModelDownloadProgress(fraction: progress.fraction, preparing: model.localModels.preparing.contains(item.id), width: 70)
                                Button("Cancel") { model.localModels.cancelDownload(item.id) }.buttonStyle(.frog(compact: true))
                            } else if installed {
                                IconMenu(title: "Model actions") {
                                    Button("Check files") { model.localModels.checkFiles(item.id) }
                                        .disabled(model.localModels.fileChecks[item.id] == .checking)
                                    Button("Delete download…", role: .destructive) { deleting = item }
                                        .disabled(model.localModels.busy || model.dictating)
                                }
                            } else {
                                Button(L10n.text(unfinished ? "Resume" : "Download")) { model.localModels.download(item) }.buttonStyle(.frog(compact: true)).disabled(!LocalModels.supported)
                                if unfinished {
                                    IconAction(title: "Discard the partly downloaded files", symbol: "trash", destructive: true) { model.localModels.discardDownload(item.id) }
                                } else if item.id.hasPrefix("hf-") {
                                    IconAction(title: "Remove model source", symbol: "minus.circle") {
                                        do { try model.removeLocalModelSource(item) } catch { model.report(error) }
                                    }
                                }
                            }
                        }
                        ModelDownloadSummary(progress: model.localModels.progress[item.id], preparing: model.localModels.preparing.contains(item.id))
                        if installed, model.localModels.progress[item.id] == nil, let check = model.localModels.fileChecks[item.id] { fileCheck(check, item: item) }
                        if let error = model.localModels.errors[item.id] { Text(error).font(FrogType.caption).foregroundStyle(FrogStyle.warning).textSelection(.enabled) }
                    }.padding(.vertical, 8).padding(.horizontal, FrogStyle.rowPadding)
                }
                if items.isEmpty {
                    Text(L10n.text(installed ? (search.isEmpty ? "Nothing downloaded yet. Pick a model below." : "No downloaded model matches.")
                                   : (search.isEmpty ? "No other models" : "No model matches.")))
                        .font(FrogType.body).foregroundStyle(FrogStyle.muted)
                        .padding(.horizontal, FrogStyle.rowPadding).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(FrogStyle.listInset).frogTableSurface()
        }
    }
    /// What "Check files" found: a missing or damaged file can be fetched again.
    @ViewBuilder private func fileCheck(_ state: LocalModels.FileCheckState, item: LocalModelDescriptor) -> some View {
        switch state {
        case .checking:
            FrogLoadingNote(text: "Checking files…")
        case .finished(let check) where check.passed:
            Label(check.summary, systemImage: "checkmark.seal").font(FrogType.caption).foregroundStyle(FrogStyle.muted)
        case .finished(let check):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(check.summary, systemImage: "exclamationmark.triangle").font(FrogType.caption).foregroundStyle(FrogStyle.warning).textSelection(.enabled)
                Spacer()
                Button("Repair") { Task { do { try await model.localModels.repair(item.id) } catch { model.report(error) } } }
                    .buttonStyle(.frog(compact: true)).disabled(model.localModels.busy || model.dictating)
                    .help("Download the missing or damaged files again into the same folder")
            }
        }
    }
}

/// What Frog asks before it deletes a download: which model, how much would have
/// to be fetched again, and what becomes of the rules that use it.
struct ModelDeletionPrompt: Equatable {
    let title: String
    let message: String
    init(_ item: LocalModelDescriptor, configuration: Configuration, installed: Set<String>) {
        let speech = item.kind == .audio
        func choice(_ rule: Rule) -> String? {
            speech ? (rule.action?.audioProviderID == nil ? rule.action?.audioModelID : nil) : rule.action?.localTextModelID
        }
        // The repair that the deletion makes, tried on a copy.
        var repaired = configuration
        repaired.modelsRemoved([RuleModelSelection(modelID: item.id, category: speech ? .audio : .text)], installed: installed.subtracting([item.id]))
        let users = configuration.rules.indices.filter { choice(configuration.rules[$0]) == item.id }
        title = "Delete \(item.name)?"
        // A source added by link may state no size.
        let size = item.downloadSize
        var text = "Its \(size.contains(where: \.isNumber) ? size + " " : "")download will be removed from this Mac."
        if let first = users.first {
            let rules = users.count == 1 ? "The rule that uses it" : "The \(users.count) rules that use it"
            if let next = choice(repaired.rules[first]) { text += " \(rules) will switch to \(configuration.localModel(next)?.name ?? next)." }
            else { text += " \(rules) will be left without a \(speech ? "speech" : "text") model." }
        } else { text += " No rule uses it." }
        message = text
    }
}

/// A download's bar; once the files are in, the wait while the model is made ready.
struct ModelDownloadProgress: View {
    let fraction: Double
    let preparing: Bool
    let width: CGFloat
    var body: some View {
        if preparing {
            FrogLoadingNote(text: "Preparing…")
        } else {
            ProgressView(value: fraction).frame(width: width)
        }
    }
}

/// The line under a download's bar while the files arrive: the bytes so far, the
/// speed and the time left, so that a slow download can be told from a stalled one.
struct ModelDownloadSummary: View {
    let progress: DownloadProgress?
    let preparing: Bool
    var body: some View {
        if !preparing, let summary = progress?.summary {
            Text(summary).font(FrogType.caption).monospacedDigit().foregroundStyle(FrogStyle.muted)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// The shared accent badge, so it has every badge's height and contrast in both themes.
struct RecommendedModelBadge: View {
    var body: some View { FrogBadge(text: "Recommended", active: true) }
}
