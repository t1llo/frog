import SwiftUI
import FrogCore

/// A local model's facts as a table, with its links in one row.
struct LocalModelInformation: View {
    let item: LocalModelDescriptor
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: FrogStyle.space16) {
            // A sheet is its own window, so its header keeps the title.
            FrogPageHeader(title: item.name, subtitle: item.kind == .audio ? "A speech model that runs on this Mac once downloaded" : "A text model that runs on this Mac once downloaded")
                .environment(\.frogToolbarTitle, false)
            // Every fact one row of one height; what the download size leaves out is the card's footer.
            FrogSection(footer: "Memory use while it runs can be higher than the download.") {
                fact("Languages", item.languages)
                fact("Runtime", item.runtimeName)
                fact("Download", item.downloadSize)
                fact("Source", item.repository, link: item.sourceURL)
                if let variant = item.variant { fact("Variant", variant) }
                if let original = item.originalRepository { fact("Based on", original, link: URL(string: "https://huggingface.co/\(original)")) }
                fact("License", item.license ?? "See the model card")
                if item.backend == .whisperKit {
                    FrogRowNote(text: "WhisperKit also installs the matching tokenizer from the upstream Hugging Face model.")
                }
            }
            FrogSheetButtons(padded: false) {
                // The model card and the original model open from their rows above; only the file list keeps a button.
                Link(destination: item.filesURL) { Label("Files", systemImage: "arrow.up.right") }
                    .help("Open the model's files on Hugging Face")
            } trailing: {
                FrogPrimaryButton("Done") { dismiss() }
            }.labelStyle(TrailingIconLabelStyle())
        }.padding(FrogStyle.sheetPadding).frame(width: 480).foregroundStyle(FrogStyle.ink).frogSheetSurface()
            .buttonStyle(.frog()).environment(\.locale, L10n.locale)
    }

    /// One fact: the label on the left, the value on the right. A repository opens its Hugging Face page, so its value
    /// is a link in the accent with an arrow after it.
    @ViewBuilder private func fact(_ label: String, _ value: String, link: URL? = nil) -> some View {
        FrogRow(label) {
            if let link {
                Link(destination: link) {
                    HStack(spacing: FrogStyle.space4) {
                        Text(value).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                    }.font(FrogType.body).foregroundStyle(FrogStyle.accent)
                }
                .buttonStyle(.plain).help(L10n.text("Open \(value) on Hugging Face"))
                .frame(maxWidth: 300, alignment: .trailing)
            } else {
                Text(value).font(FrogType.body).foregroundStyle(FrogStyle.ink).textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle).help(value)
                    .frame(maxWidth: 300, alignment: .trailing)
            }
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
            FrogPageHeader(title: "Add Hugging Face model", subtitle: "MLX text, WhisperKit speech, or supported Parakeet sources")
                .environment(\.frogToolbarTitle, false)
            VStack(alignment: .leading, spacing: FrogStyle.space6) {
                FrogTextField(placeholder: "https://huggingface.co/owner/model", text: $source)
                    .textFieldStyle(.plain).font(FrogType.body)
                    .padding(.horizontal, FrogStyle.space10).frogControlSurface(radius: FrogStyle.controlRadius)
                    .accessibilityLabel("Hugging Face link")
                    .disabled(loading).onSubmit { inspect() }
                    .onChange(of: source) { _, _ in candidates = []; issue = nil }
                // What the field takes, which is also why Check source waits, and a button that fills it with an example.
                HStack(spacing: FrogStyle.space8) {
                    Text("A link or an ID, such as mlx-community/Qwen3-0.6B-4bit").font(FrogType.small)
                        .foregroundStyle(FrogStyle.muted).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button("Use example") { source = "https://huggingface.co/mlx-community/Qwen3-0.6B-4bit" }
                        .buttonStyle(.frog()).disabled(loading)
                        .help("Put this model's link in the field")
                }
            }
            if let issue { InlineIssue(message: issue).textSelection(.enabled) }
            if !candidates.isEmpty {
                FrogSheetScroll(maxHeight: 250) {
                    FrogSection {
                        ForEach(candidates) { item in
                            FrogRow(item.name, caption: item.runtimeName) {
                                Button(model.configuration.modelCatalog.contains(where: { $0.id == item.id }) ? "Show model" : "Add model") {
                                    do { try model.addLocalModel(item); onAdded(item); dismiss() } catch { issue = error.localizedDescription }
                                }.buttonStyle(.frog())
                            }
                        }
                    }
                }
            }
            FrogSheetButtons(padded: false) {
                // Why Check source waits takes the footer's note, the leading side of the sheet's buttons.
                if loading {
                    FrogLoadingNote(text: "Reading the model's details…")
                } else if empty {
                    Text("Paste a link or a model ID first").font(FrogType.small).foregroundStyle(FrogStyle.muted)
                } else {
                    Text("Nothing downloads yet.").font(FrogType.small).foregroundStyle(FrogStyle.muted)
                        .help("Checking reads the model's details only.")
                }
            } trailing: {
                FrogCancelButton { inspection?.cancel(); dismiss() }
                FrogPrimaryButton("Check source", disabledReason: loading ? "Reading the model's details…"
                                  : empty ? "Paste a link or a model ID first" : nil) { inspect() }
            }
        }.padding(FrogStyle.sheetPadding).frame(width: 540).foregroundStyle(FrogStyle.ink).frogSheetSurface()
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
