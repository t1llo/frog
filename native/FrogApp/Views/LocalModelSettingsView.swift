import SwiftUI
import AppKit
import FrogCore

/// Memory and storage of the models that run inside Frog, below the Local models list.
struct LocalModelSettingsView: View {
    @EnvironmentObject private var model: AppModel
    /// A model folder chosen while models are downloaded in the current one, until it is confirmed.
    @State private var pendingModelFolder: URL?
    /// Seconds a local model stays loaded after its last use, besides unloading at once.
    static let idleUnloadChoices = [120, 300, 900, 1800, 3600]
    private var prefs: WorkflowPreferences { model.configuration.preferences.workflowSettings }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSection(title: "Memory") {
                CompactRow(title: "Unload idle models") {
                    CompactMenu(value: LocalModelSettings.idleTitle(seconds: prefs.idleUnloadSeconds)) {
                        Button("Immediately") { update { $0.idleUnloadSeconds = 0 } }.accessibilityAddTraits(prefs.idleUnloadSeconds == 0 ? .isSelected : [])
                        ForEach(LocalModelSettingsView.idleUnloadChoices, id: \.self) { seconds in
                            Button(LocalModelSettings.idleTitle(seconds: seconds)) { update { $0.idleUnloadSeconds = seconds } }.accessibilityAddTraits(prefs.idleUnloadSeconds == seconds ? .isSelected : [])
                        }
                    }
                }
                Divider()
                CompactRow(title: model.localModels.loaded.isEmpty ? "No models loaded" : "Models in memory", detail: LocalModelSettings.inMemory(model.localModels.loaded, catalog: model.configuration.modelCatalog)) {
                    Button("Unload now") { Task { await model.localModels.unload() } }.disabled(model.localModels.loaded.isEmpty || model.localModels.busy || model.dictation.active)
                }
            }
            SettingsSection(title: "Storage") {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.localModels.root.path).font(.system(size: 11)).foregroundStyle(FrogStyle.muted).textSelection(.enabled)
                    Spacer(minLength: 8)
                    if let use = LocalModelSettings.diskUse(model.localModels.totalDiskUse(of: model.localModels.installed)) {
                        Text(use).font(.system(size: 11)).foregroundStyle(FrogStyle.muted).fixedSize()
                    }
                }
                HStack {
                    Button("Choose folder…") { chooseModelFolder() }
                    Button("Use default") { setModelFolder(model.localModels.defaultDirectory) }.disabled(model.localModels.root == model.localModels.defaultDirectory)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: model.localModels.root.path) }
                }.disabled(model.localModels.busy || !model.localModels.progress.isEmpty || model.dictation.active)
            }
        }
        .toggleStyle(.switch).controlSize(.small)
        .confirmationDialog(modelFolderChange?.title ?? "Use another model folder?", isPresented: Binding(get: { pendingModelFolder != nil }, set: { if !$0 { pendingModelFolder = nil } }), titleVisibility: .visible) {
            Button("Use new folder") { if let url = pendingModelFolder { pendingModelFolder = nil; applyModelFolder(url) } }
            Button("Cancel", role: .cancel) { pendingModelFolder = nil }
        } message: { Text(modelFolderChange?.message ?? "") }
    }

    private func update(_ body: (inout WorkflowPreferences) -> Void) { var value = prefs; body(&value); do { try model.saveWorkflowPreferences(value) } catch { model.report(error) } }
    private func chooseModelFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false; panel.directoryURL = model.localModels.root; panel.title = "Model download folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }; setModelFolder(url)
    }
    private var modelFolderChange: LocalModelSettings.FolderChange? {
        pendingModelFolder.flatMap { folderChange(to: $0) }
    }
    private func folderChange(to url: URL) -> LocalModelSettings.FolderChange? {
        let models = model.localModels
        return LocalModelSettings.folderChange(from: models.root, to: url, installed: models.installed.count, bytes: models.totalDiskUse(of: models.installed))
    }
    /// Asks first when the downloaded models would stay behind in the current folder.
    private func setModelFolder(_ url: URL) {
        guard !model.dictation.active else { return }
        if folderChange(to: url) != nil { pendingModelFolder = url } else { applyModelFolder(url) }
    }
    private func applyModelFolder(_ url: URL) { guard !model.dictation.active else { return }; Task { do { try await model.localModels.changeDirectory(to: url) } catch { model.report(error) } } }
}

/// What the Local models section says about the idle time and about the models in memory.
enum LocalModelSettings {
    /// The idle time as it is saved. The configuration file takes any number of seconds, not only the menu's choices.
    static func idleTitle(seconds: Int) -> String {
        guard seconds > 0 else { return "Immediately" }
        let minutes = seconds / 60, rest = seconds % 60
        if minutes == 0 { return "\(rest) sec" }
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) sec"
    }
    /// The names of the models in memory, in the order of the catalog.
    static func inMemory(_ loaded: Set<String>, catalog: [LocalModelDescriptor]) -> String? {
        guard !loaded.isEmpty else { return nil }
        let known = catalog.filter { loaded.contains($0.id) }
        return (known.map(\.name) + loaded.subtracting(known.map(\.id)).sorted()).joined(separator: ", ")
    }
    /// What the downloaded models take on the disk of the model folder.
    static func diskUse(_ bytes: Int64?) -> String? {
        bytes.map { "Models use " + LocalModelDescriptor.byteCount($0) }
    }
    struct FolderChange: Equatable { let title: String; let message: String }
    /// What Frog asks before it uses another model folder while models are downloaded
    /// in this one. It does not move them, so they stay where they are and take their space.
    static func folderChange(from root: URL, to location: URL, installed: Int, bytes: Int64?) -> FolderChange? {
        guard installed > 0, root.standardizedFileURL.path != location.standardizedFileURL.path else { return nil }
        let one = installed == 1, folder = "“\(root.lastPathComponent)”"
        let use = bytes.map { " and keep\(one ? "s" : "") using " + LocalModelDescriptor.byteCount($0) } ?? ""
        let models = one ? "The model downloaded in \(folder) stays there" : "The \(installed) models downloaded in \(folder) stay there"
        return FolderChange(title: "Use another model folder?",
                            message: "\(models)\(use); Frog does not move \(one ? "it" : "them"). Frog will list only the models in the new folder. Choose this folder again to use \(one ? "it" : "them").")
    }
}
