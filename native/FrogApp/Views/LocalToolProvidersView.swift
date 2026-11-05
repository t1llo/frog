import SwiftUI
import FrogCore

/// Embed in ProvidersView. The parent chooses how a portable tool/model selection is saved.
struct LocalToolProvidersView: View {
    let client: LocalToolClient
    var onSelect: (LocalToolKind, String) -> Void
    @State private var statuses: [LocalToolStatus] = []
    @State private var refreshing = false
    @State private var selected: LocalToolKind = .claudeCode
    @State private var model = ""
    @State private var models: [LocalToolModel] = LocalToolKind.claudeCode.suggestedModels
    @State private var modelError: String?

    var body: some View {
        FrogSection("Coding tools", footer: nil, accessory: {
            HStack(spacing: 8) {
                if refreshing { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await refresh() } }.buttonStyle(.frog(compact: true)).disabled(refreshing)
            }
        }) {
            ForEach(statuses) { status in
                FrogRow(status.kind.title, caption: status.detail, icon: {
                    Image(systemName: status.installed ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(status.installed ? FrogStyle.accent : FrogStyle.muted).frame(width: 20)
                }, control: { EmptyView() })
            }
            FrogRow("Tool") {
                FrogDropdown(selection: $selected, options: LocalToolKind.allCases, title: { $0.title })
            }
            HStack(spacing: FrogStyle.space8) {
                TextField("Tool default, or model ID", text: $model)
                    .textFieldStyle(.plain).font(FrogType.body).padding(.horizontal, 8).frogControlSurface()
                    .accessibilityLabel("Coding-tool model")
                FrogDropdown(selection: $model, options: models.map(\.id), width: 105, searchPrompt: "Find a model",
                             title: { id in models.first { $0.id == id }?.name ?? id }).buttonTitle { _ in "Models" }
                Button("Use model") { onSelect(selected, model.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .buttonStyle(.frog(.primary)).disabled(!canSelect)
            }.padding(.vertical, FrogStyle.space10)
            if let modelError { FrogRowNote(text: modelError) }
            if selected == .opencode {
                FrogRowNote(text: "OpenCode keeps its own CLI history, independently of Frog's history setting.")
            }
            FrogRowNote(text: "Uses your CLI login and your plan's limits. Claude Desktop alone has no supported headless interface; sign in or change accounts in the tool itself.")
        }
        .task { await refresh() }
        .task(id: selected) {
            model = ""; models = selected.suggestedModels; modelError = nil
            do { models = try await client.models(for: selected) }
            catch is CancellationError { }
            catch { modelError = error.localizedDescription }
        }
    }

    private var canSelect: Bool {
        LocalToolRequest.isValidModel(model.trimmingCharacters(in: .whitespacesAndNewlines)) &&
        statuses.contains { $0.kind == selected && $0.installed && $0.supportsTextTransforms && $0.authentication != .signedOut }
    }

    private func refresh() async {
        refreshing = true
        defer { refreshing = false }
        // Each row appears, or is replaced, as soon as its own tool has answered.
        statuses = await client.statuses { status in statuses = statuses.replacing(status) }
    }
}
