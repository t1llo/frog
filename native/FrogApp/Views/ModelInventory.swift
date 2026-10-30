import SwiftUI
import FrogCore

struct ModelInventory: View {
    @EnvironmentObject private var model: AppModel
    let kind: LocalModelDescriptor.Kind
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
            .filter { $0.kind == kind && (search.isEmpty || ($0.name + " " + $0.repository).localizedStandardContains(search)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
        group("Downloaded", items: inventory.filter { model.localModels.installed.contains($0.id) }, installed: true)
        group("Available to download", items: inventory.filter { !model.localModels.installed.contains($0.id) }, installed: false)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SectionCaption(text: title)
                // What the downloads listed here take on disk together.
                if installed, let total = model.localModels.totalDiskUse(of: items.map(\.id)) {
                    Text(LocalModelDescriptor.byteCount(total)).font(FrogType.small).foregroundStyle(FrogStyle.muted)
                }
            }
            VStack(spacing: 2) {
                ForEach(items) { item in
                    let unfinished = !installed && model.localModels.progress[item.id] == nil && model.localModels.unfinished.contains(item.id)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Image(systemName: installed ? "checkmark.circle.fill" : "arrow.down.circle").foregroundStyle(installed ? FrogStyle.accent : FrogStyle.muted)
                            VStack(alignment: .leading, spacing: 3) {
                                 HStack(spacing: 6) {
                                     Text(item.name).font(FrogType.bodyMedium)
                                     if item.isRecommended { RecommendedModelBadge() }
                                 }
                                Text([installed ? model.localModels.size(of: item) : item.downloadSize, item.runtimeName, model.localModels.loaded.contains(item.id) ? "In memory" : "", unfinished ? "Partly downloaded" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                                Text(L10n.text(item.recommendationSummary ?? item.languages))
                                    .font(FrogType.caption).foregroundStyle(FrogStyle.muted)
                                    .help(item.kind == .audio ? "Live preview uses repeated short audio chunks, not a continuous streaming decoder. Speed and accuracy are relative catalog guidance." : "Relative catalog guidance; performance depends on your Mac and input.")
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
                                        .disabled(model.localModels.busy || model.dictation.active)
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
                    }.padding(.vertical, 8).padding(.horizontal, 8)
                }
                if items.isEmpty { Text(L10n.text(installed ? "No downloaded models" : "No additional models")).font(FrogType.small).foregroundStyle(FrogStyle.muted).padding(8).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding(6).frogTableSurface()
        }
    }
    /// What "Check files" found: a missing or damaged file can be fetched again.
    @ViewBuilder private func fileCheck(_ state: LocalModels.FileCheckState, item: LocalModelDescriptor) -> some View {
        switch state {
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking files…").font(FrogType.small).foregroundStyle(FrogStyle.muted) }
        case .finished(let check) where check.passed:
            Label(check.summary, systemImage: "checkmark.seal").font(FrogType.caption).foregroundStyle(FrogStyle.muted)
        case .finished(let check):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(check.summary, systemImage: "exclamationmark.triangle").font(FrogType.caption).foregroundStyle(FrogStyle.warning).textSelection(.enabled)
                Spacer()
                Button("Repair") { Task { do { try await model.localModels.repair(item.id) } catch { model.report(error) } } }
                    .buttonStyle(.frog(compact: true)).disabled(model.localModels.busy || model.dictation.active)
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
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Preparing…").font(FrogType.small).foregroundStyle(FrogStyle.muted) }
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

struct RecommendedModelBadge: View {
    var body: some View { FrogBadge(text: "Recommended", active: true) }
}
