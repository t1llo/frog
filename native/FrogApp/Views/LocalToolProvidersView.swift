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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Coding tools").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Refresh") { Task { await refresh() } }.disabled(refreshing)
                if refreshing { ProgressView().controlSize(.small) }
            }
            Text("Reuse your CLI login for writing, translation and dictation cleanup. Requests run in the background; your plan's limits and network latency still apply.")
                .font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
            ForEach(statuses) { status in
                HStack(alignment: .top) {
                    Image(systemName: status.installed ? "checkmark.circle" : "circle.dashed")
                        .foregroundStyle(status.installed ? FrogStyle.accent : FrogStyle.muted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status.kind.title).font(.system(size: 12, weight: .medium))
                        Text(status.detail).font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                    }
                    Spacer()
                }
            }
            CompactRow(title: "Tool") {
                CompactMenu(value: selected.title, width: 180) {
                    ForEach(LocalToolKind.allCases) { kind in Button(kind.title) { selected = kind } }
                }
            }
            HStack {
                TextField("Tool default, or model ID", text: $model)
                    .textFieldStyle(.plain).font(.system(size: 12)).padding(8)
                    .background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: FrogStyle.corner))
                    .overlay(RoundedRectangle(cornerRadius: FrogStyle.corner).strokeBorder(FrogStyle.border.opacity(0.6)))
                    .accessibilityLabel("Coding-tool model")
                CompactMenu(value: "Models", width: 105) {
                    ForEach(models) { item in Button(item.name) { model = item.id } }
                }
                Button("Use model") { onSelect(selected, model.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .disabled(!canSelect)
            }
            if let modelError { Text(modelError).font(.caption).foregroundStyle(.secondary) }
            if selected == .opencode {
                Text("OpenCode keeps its own CLI history, independently of Frog's history setting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Claude Desktop alone has no supported headless interface. Sign in or change accounts in the tool itself.")
                .font(.caption).foregroundStyle(.secondary)
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
        statuses = await client.statuses()
    }
}
