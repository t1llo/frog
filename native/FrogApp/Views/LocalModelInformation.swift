import SwiftUI
import FrogCore

struct LocalModelInformation: View {
    let item: LocalModelDescriptor
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: item.name, subtitle: item.runtimeName)
            Text(item.languages).font(.system(size: 12))
            VStack(alignment: .leading, spacing: 8) {
                SectionCaption(text: "Download source")
                Text(item.repository).textSelection(.enabled)
                if let variant = item.variant { Text("Variant: \(variant)").font(.caption).textSelection(.enabled) }
                HStack { Link("Model card ↗", destination: item.sourceURL); Link("Download files ↗", destination: item.filesURL) }
            }
            if let original = item.originalRepository, let url = URL(string: "https://huggingface.co/\(original)") {
                VStack(alignment: .leading, spacing: 6) {
                    SectionCaption(text: "Original model")
                    Link(original + " ↗", destination: url)
                }
            }
            Text("Download size: \(item.size). Runtime memory use can be higher.").font(.caption).foregroundStyle(FrogStyle.muted)
            Text("License: \(item.license ?? "See model card")").font(.caption)
            if item.backend == .whisperKit {
                Text("WhisperKit also installs the matching tokenizer from the upstream Hugging Face model.").font(.caption).foregroundStyle(FrogStyle.muted)
            }
            Text("Runs locally after download.").font(.caption).foregroundStyle(FrogStyle.muted)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(22).frame(width: 450).foregroundStyle(FrogStyle.ink).background(FrogStyle.panelSurface)
            .buttonStyle(FrogButtonStyle()).environment(\.locale, L10n.locale)
    }
}

struct AddLocalModelView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var onAdded: (LocalModelDescriptor.Kind) -> Void
    @State private var source = ""
    @State private var candidates: [LocalModelDescriptor] = []
    @State private var loading = false
    @State private var issue: String?
    @State private var inspection: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Add Hugging Face model", subtitle: "MLX text, WhisperKit speech, or supported Parakeet sources.")
            TextField("https://huggingface.co/owner/model", text: $source).textFieldStyle(.roundedBorder)
                .disabled(loading).onSubmit { inspect() }
                .onChange(of: source) { _, _ in candidates = []; issue = nil }
            Button("Example: huggingface.co/mlx-community/Qwen3-0.6B-4bit") { source = "https://huggingface.co/mlx-community/Qwen3-0.6B-4bit" }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(FrogStyle.accent).disabled(loading)
            HStack {
                Button("Check source") { inspect() }.disabled(loading || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if loading { ProgressView().controlSize(.small) }
            }
            if let issue { Text(issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if !candidates.isEmpty {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(candidates) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name).font(.system(size: 12, weight: .medium))
                                    Text(item.runtimeName).font(.caption).foregroundStyle(FrogStyle.muted)
                                }
                                Spacer()
                                Button(model.configuration.modelCatalog.contains(where: { $0.id == item.id }) ? "Show model" : "Add model") {
                                    do { try model.addLocalModel(item); onAdded(item.kind); dismiss() } catch { issue = error.localizedDescription }
                                }
                            }.padding(10).frogTableSurface()
                        }
                    }
                }.frame(maxHeight: 250)
            }
            Text("Checking reads metadata. Download installs the model separately. Use MLX, WhisperKit or a supported Parakeet conversion.")
                .font(.caption).foregroundStyle(FrogStyle.muted)
            HStack { Spacer(); Button("Cancel") { inspection?.cancel(); dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(22).frame(width: 520).foregroundStyle(FrogStyle.ink).background(FrogStyle.panelSurface)
            .buttonStyle(FrogButtonStyle()).environment(\.locale, L10n.locale)
            .onDisappear { inspection?.cancel() }
    }
    private func inspect() {
        guard !loading else { return }
        loading = true; issue = nil; candidates = []
        let input = source
        inspection = Task {
            defer { loading = false }
            do { let result = try await HuggingFaceModels().inspect(input); try Task.checkCancellation(); candidates = result }
            catch { if !Task.isCancelled { issue = error.localizedDescription } }
        }
    }
}
