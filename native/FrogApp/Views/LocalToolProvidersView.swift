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
        VStack(alignment: .leading, spacing: FrogStyle.sectionSpacing) {
            FrogSection("On this Mac", accessory: {
                HStack(spacing: 8) {
                    if refreshing { FrogSpinner() }
                    Button("Refresh") { Task { await refresh() } }.buttonStyle(.frog(.ghost, compact: true)).disabled(refreshing)
                }
            }) {
                ForEach(statuses) { status in
                    FrogRow(status.kind.title, caption: status.detail, icon: {
                        Image(systemName: status.installed ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(status.installed ? FrogStyle.good : FrogStyle.muted).frame(width: 20)
                    }) {
                        if status.installed {
                            Button(selected == status.kind ? "Chosen" : "Choose") { selected = status.kind }
                                .buttonStyle(.frog(.ghost, compact: true)).disabled(selected == status.kind)
                        } else {
                            Text("Not installed").font(FrogType.small).foregroundStyle(FrogStyle.muted)
                        }
                    }
                }
                if statuses.isEmpty, refreshing { FrogLoadingNote(text: "Looking for coding tools…") }
            }
            // Which tool and model Frog's rules use; the tool is named here so the model below is clearly its.
            FrogSection("Use with Frog's rules",
                        footer: "Uses the tool's own login and your plan's limits. Sign in or change accounts in the tool itself.") {
                FrogRow("Tool") {
                    FrogDropdown(selection: $selected, options: LocalToolKind.allCases, title: { $0.title })
                }
                FrogRow("Model", caption: "Leave empty for \(selected.title)'s default.") {
                    HStack(spacing: FrogStyle.space8) {
                        FrogTextField(placeholder: "Model ID", text: $model)
                            .textFieldStyle(.plain).font(FrogType.body).padding(.horizontal, 8).frame(width: 180).frogControlSurface()
                            .accessibilityLabel("\(selected.title) model")
                        FrogDropdown(selection: $model, options: models.map(\.id), width: 124, searchPrompt: "Find a model",
                                     title: { id in models.first { $0.id == id }?.name ?? id }).buttonTitle { _ in "Suggested" }
                    }
                }
                if let modelError { FrogRowNote(text: modelError) }
                if selected == .opencode {
                    FrogRowNote(text: "OpenCode keeps its own CLI history, independently of Frog's history setting.")
                }
                FrogRow("Add as a provider", caption: selectReason) {
                    Button("Use \(selected.title)") { onSelect(selected, model.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        .buttonStyle(.frog(.primary)).frogDisabled(canSelect ? nil : selectReason)
                }
            }
        }
        .task { await refresh() }
        .task(id: selected) {
            model = ""; models = selected.suggestedModels; modelError = nil
            do { models = try await client.models(for: selected) }
            catch is CancellationError { }
            catch { modelError = error.localizedDescription }
        }
        // Start on a tool that is installed, rather than on the first one in the list.
        .onChange(of: statuses.map(\.installed)) { _, _ in
            if statuses.first(where: { $0.kind == selected })?.installed != true,
               let installed = statuses.first(where: { $0.installed && $0.supportsTextTransforms }) { selected = installed.kind }
        }
    }

    /// Why Use is not available yet, or what it does.
    private var selectReason: String {
        guard let status = statuses.first(where: { $0.kind == selected }) else { return "Checking \(selected.title)…" }
        if !status.installed { return "\(selected.title) is not installed on this Mac." }
        if !status.supportsTextTransforms { return "This version of \(selected.title) cannot rewrite text." }
        if status.authentication == .signedOut { return "Sign in to \(selected.title) first." }
        if !LocalToolRequest.isValidModel(model.trimmingCharacters(in: .whitespacesAndNewlines)) { return "Check the model ID." }
        return "Rules can then choose its models."
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
