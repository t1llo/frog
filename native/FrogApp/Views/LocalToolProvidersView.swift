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
                // While it looks, a spinner and the word for it take the button's place, so it never spins unexplained.
                if refreshing {
                    HStack(spacing: FrogStyle.space6) {
                        FrogSpinner(size: .mini, label: "Looking for coding tools")
                        Text("Looking…")
                    }.accessibilityElement(children: .combine)
                }
                else { Button("Refresh") { Task { await refresh() } }.buttonStyle(.frog(.ghost, compact: true)) }
            }) {
                ForEach(statuses) { status in
                    // The tool's own tile; whether it is installed or chosen is said at the row's end.
                    FrogRow(status.kind.title, caption: status.detail, icon: {
                        PluginIconTile(mark: .tool(status.kind)).opacity(status.installed ? 1 : FrogStyle.disabledOpacity)
                    }) {
                        if status.installed, selected == status.kind {
                            FrogBadge(text: "Chosen", active: true)
                        } else if status.installed {
                            Button("Choose") { selected = status.kind }.buttonStyle(.frog(compact: true))
                        } else {
                            Text("Not installed").font(FrogType.small).foregroundStyle(FrogStyle.muted)
                        }
                    }
                }
                if statuses.isEmpty, refreshing { FrogLoadingNote(text: "Looking for coding tools…") }
            }
            // Which tool and model Frog's rules use; the tool is named here so the model below is clearly its.
            FrogSection("Use with Frog's rules",
                        footer: "Coding tools use their own sign-in and your plan's limits; change accounts in the tool itself.") {
                FrogRow("Tool") {
                    FrogDropdown(selection: $selected, options: LocalToolKind.allCases, title: { $0.title })
                }
                // The suggestions and a typed ID are one choice in two rows, so neither control is squeezed.
                FrogRow("Model") {
                    FrogDropdown(selection: $model, options: [""] + models.map(\.id),
                                 searchPrompt: models.count > 8 ? "Find a model" : nil, placeholder: "Other model",
                                 title: { id in id.isEmpty ? "\(selected.title)'s default" : models.first { $0.id == id }?.name ?? id })
                }
                FrogRow("Model ID", caption: "For a model that is not in the list") {
                    FrogTextField(placeholder: "Model ID", text: $model)
                        .textFieldStyle(.plain).font(FrogType.body).padding(.horizontal, FrogStyle.space10).frame(width: 220).frogControlSurface()
                        .accessibilityLabel("\(selected.title) model ID")
                }
                if let modelError { FrogRowNote(text: modelError) }
                if selected == .opencode {
                    FrogRowNote(text: "OpenCode keeps its own CLI history, independently of Frog's history setting.")
                }
                FrogRow("Add \(selected.title) as a provider", caption: selectReason) {
                    Button("Add") { onSelect(selected, model.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        .buttonStyle(.frog(.primary)).frogDisabled(canSelect ? nil : selectReason)
                        .accessibilityLabel("Add \(selected.title) as a provider")
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
