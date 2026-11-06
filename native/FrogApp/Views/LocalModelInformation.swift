import SwiftUI
import FrogCore

/// A local model's facts as a table, with its links in one row.
struct LocalModelInformation: View {
    let item: LocalModelDescriptor
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: FrogStyle.space16) {
            // A sheet is its own window, so its header keeps the title.
            FrogPageHeader(title: item.name, subtitle: item.kind == .audio ? "A speech model that runs on this Mac once downloaded." : "A text model that runs on this Mac once downloaded.")
                .environment(\.frogToolbarTitle, false)
            FrogSection {
                fact("Languages", item.languages)
                fact("Runtime", item.runtimeName)
                fact("Download", item.downloadSize, caption: "Memory use while running can be higher.")
                fact("Source", item.repository)
                if let variant = item.variant { fact("Variant", variant) }
                if let original = item.originalRepository { fact("Based on", original) }
                fact("License", item.license ?? "See the model card")
                if item.backend == .whisperKit {
                    FrogRowNote(text: "WhisperKit also installs the matching tokenizer from the upstream Hugging Face model.")
                }
            }
            FrogSheetButtons(padded: false) {
                Link(destination: item.sourceURL) { Label("Model card", systemImage: "arrow.up.right") }
                Link(destination: item.filesURL) { Label("Files", systemImage: "arrow.up.right") }
                if let original = item.originalRepository, let url = URL(string: "https://huggingface.co/\(original)") {
                    Link(destination: url) { Label("Original model", systemImage: "arrow.up.right") }
                }
            } trailing: {
                FrogPrimaryButton("Done") { dismiss() }
            }.labelStyle(TrailingIconLabelStyle())
        }.padding(FrogStyle.sheetPadding).frame(width: 480).foregroundStyle(FrogStyle.ink).background(FrogStyle.panelSurface)
            .buttonStyle(.frog()).environment(\.locale, L10n.locale)
    }

    /// One fact: the label on the left, with a caption under it when the value needs one, the value on the right.
    private func fact(_ label: String, _ value: String, caption: String? = nil) -> some View {
        FrogRow(label, caption: caption) {
            Text(value).font(FrogType.body).foregroundStyle(FrogStyle.ink).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle).help(value)
                .frame(maxWidth: 300, alignment: .trailing)
        }
    }
}

/// A link's arrow after its text, as in "Model card ↗".
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: LabelStyleConfiguration) -> some View {
        HStack(spacing: FrogStyle.space4) { configuration.title; configuration.icon.font(.system(size: 10, weight: .semibold)) }
    }
}

struct AddLocalModelView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var onAdded: (LocalModelDescriptor) -> Void
    @State private var source = ""
    @State private var candidates: [LocalModelDescriptor] = []
    @State private var loading = false
    @State private var issue: String?
    @State private var inspection: Task<Void, Never>?

    var body: some View {
        let empty = source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: FrogStyle.space16) {
            FrogPageHeader(title: "Add Hugging Face model", subtitle: "MLX text, WhisperKit speech, or supported Parakeet sources.")
                .environment(\.frogToolbarTitle, false)
            VStack(alignment: .leading, spacing: FrogStyle.space6) {
                FrogTextField(placeholder: "https://huggingface.co/owner/model", text: $source)
                    .textFieldStyle(.plain).font(FrogType.body)
                    .padding(.horizontal, FrogStyle.space10).frogControlSurface(radius: FrogStyle.controlRadius)
                    .accessibilityLabel("Hugging Face link")
                    .disabled(loading).onSubmit { inspect() }
                    .onChange(of: source) { _, _ in candidates = []; issue = nil }
                // A quiet line on the field's edge, and a plain button that fills the field with it.
                HStack(spacing: FrogStyle.space8) {
                    Text("For example: huggingface.co/mlx-community/Qwen3-0.6B-4bit").font(FrogType.small)
                        .foregroundStyle(FrogStyle.muted).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button("Use example") { source = "https://huggingface.co/mlx-community/Qwen3-0.6B-4bit" }
                        .buttonStyle(.frog(.ghost, compact: true)).disabled(loading).padding(.trailing, -10)
                }
            }
            if let issue { InlineIssue(message: issue).textSelection(.enabled) }
            if !candidates.isEmpty {
                ScrollView {
                    FrogSection {
                        ForEach(candidates) { item in
                            FrogRow(item.name, caption: item.runtimeName) {
                                Button(model.configuration.modelCatalog.contains(where: { $0.id == item.id }) ? "Show model" : "Add model") {
                                    do { try model.addLocalModel(item); onAdded(item); dismiss() } catch { issue = error.localizedDescription }
                                }.buttonStyle(.frog(compact: true))
                            }
                        }
                    }
                }.frame(maxHeight: 250).fixedSize(horizontal: false, vertical: true)
            }
            FrogSheetButtons(padded: false) {
                if loading {
                    FrogLoadingNote(text: "Reading the model's details…")
                } else {
                    Text("Checking reads only its details.").font(FrogType.small).foregroundStyle(FrogStyle.muted)
                }
            } trailing: {
                FrogCancelButton { inspection?.cancel(); dismiss() }
                FrogPrimaryButton("Check source", disabledReason: loading ? "Reading the model's details…"
                                  : empty ? "Paste a link or a model ID first" : nil) { inspect() }
            }
        }.padding(FrogStyle.sheetPadding).frame(width: 540).foregroundStyle(FrogStyle.ink).background(FrogStyle.panelSurface)
            .buttonStyle(.frog()).environment(\.locale, L10n.locale)
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
