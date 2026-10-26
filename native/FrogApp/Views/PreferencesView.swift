import SwiftUI
import AppKit
import FrogCore
import UniformTypeIdentifiers

struct PreferencesView: View {
    @Binding var permissionsRequest: ScrollRequest
    @EnvironmentObject private var model: AppModel
    @State private var pendingConfiguration: Configuration?
    @State private var confirmingImport = false
    @State private var legalDocument: LegalDocument?
    private var prefs: WorkflowPreferences { model.configuration.preferences.workflowSettings }
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Settings")
                SettingsSection(title: "General") {
                    CompactRow(title: "Setup assistant") {
                        Button("Open setup…") { model.showSetup() }
                    }
                    Divider()
                    CompactRow(title: "Start at login") { Toggle("Start at login", isOn: Binding(get: { model.startAtLogin }, set: model.setStartAtLogin)).labelsHidden() }
                    if model.loginNeedsAttention {
                        HStack(spacing: 8) {
                            Text(model.loginStatus).font(.caption).foregroundStyle(FrogStyle.warning).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Button("Open Login Items") { LoginService.openLoginItems() }
                        }
                    }
                    Divider()
                    CompactRow(title: "Writing indicator") { Toggle("Writing indicator", isOn: preference(\.showProcessingIndicator)).labelsHidden() }
                    Divider()
                    CompactRow(title: "Show rule shortcuts", detail: "Hold to see your rules.") {
                        HotkeyRecorder(hotkey: Binding(get: { prefs.shortcutPanelHotkey }, set: { value in update { $0.shortcutPanelHotkey = value } }))
                    }
                    if let issue = model.hotkeyErrors[AppModel.shortcutPanelID] { Text(issue).font(.caption).foregroundStyle(FrogStyle.warning) }
                    Divider()
                    CompactRow(title: "Statistics") {
                        Button("View statistics") { model.toolkit.select(.statistics) }
                    }
                }
                SettingsSection(title: "Appearance") { AppearanceSettingsView(model: model) }
                SettingsSection(title: "Permissions") {
                    permission("Accessibility", allowed: model.accessibilityGranted) { SelectionService.requestAccess(); SelectionService.openAccessibilitySettings() }
                    Divider()
                    permission("Microphone", allowed: DictationController.microphoneGranted) {
                        Task { if !DictationController.microphoneGranted { _ = await DictationController.requestMicrophone() }; DictationController.openMicrophoneSettings(); model.objectWillChange.send() }
                    }
                }.id("permissions")
                AgentSettingsView(server: model.agentServer)
                SettingsSection(title: "History") {
                    CompactRow(title: "Save history on this Mac") { Toggle("Save history on this Mac", isOn: preference(\.historyEnabled)).labelsHidden() }
                    Divider()
                    CompactRow(title: "Hide history text", detail: "Masked until you reveal it.") {
                        Toggle("Hide history text", isOn: preference(\.hideHistoryText)).labelsHidden()
                    }
                    Divider()
                    HistoryLimitsView(model: model)
                    Divider()
                    Text(model.historyFileURL.path).font(.system(size: 10)).foregroundStyle(FrogStyle.muted).textSelection(.enabled)
                }
                SettingsSection(title: "Configuration") {
                    CompactRow(title: "Configuration file", detail: "Edit, save, then Reload.") {
                        HStack {
                            Button("Open config") { model.openConfiguration() }
                            Button("Reload") { do { try model.reloadConfiguration() } catch { model.report(error) } }
                                .disabled(model.isProcessing || model.isTestingProvider || model.dictation.active)
                        }
                    }
                    Text(model.configurationFileURL.path).font(.system(size: 10)).foregroundStyle(FrogStyle.muted).textSelection(.enabled)
                    Button("Show configuration folder") { NSWorkspace.shared.activateFileViewerSelecting([model.configurationFileURL]) }
                    Divider()
                    CompactRow(title: "Import / export", detail: "API keys stay in Keychain.") {
                        HStack {
                            Button("Import…") { chooseConfiguration() }.disabled(model.isProcessing || model.isTestingProvider || model.dictation.active)
                            Button("Export…") { exportConfiguration() }
                        }
                    }
                }
                SettingsSection(title: "Updates") { UpdateSettingsView() }
                SettingsSection(title: "Logs") {
                    HStack {
                        Button("Copy log", systemImage: "doc.on.doc") {
                            ViewActions.copy(model.recentErrors.map { "\($0.timestamp.ISO8601Format())  \($0.message)" }.joined(separator: "\n"))
                        }
                        Spacer()
                        Button("Clear log") { model.clearRecentErrors() }
                    }.disabled(model.recentErrors.isEmpty)
                    DisclosureGroup("Recent errors (\(model.recentErrors.count))") {
                        if model.recentErrors.isEmpty {
                            Text("No errors recorded.").font(.system(size: 11)).foregroundStyle(FrogStyle.muted).padding(.vertical, 8)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    ForEach(model.recentErrors) { issue in
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack {
                                                Text(issue.timestamp.formatted(date: .omitted, time: .standard))
                                                    .font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                                                Spacer()
                                                IconAction(title: "Copy error", symbol: "doc.on.doc") { ViewActions.copy("\(issue.timestamp.ISO8601Format())  \(issue.message)") }
                                            }
                                            Text(issue.message).font(.system(size: 11)).textSelection(.enabled)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }.padding(.vertical, 8).minimalScrollbars()
                            }.frame(maxHeight: 200)
                        }
                    }.font(.system(size: 12))
                }
                SettingsSection(title: "About") {
                    CompactRow(title: "Frog") { Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")").foregroundStyle(FrogStyle.muted) }
                    CompactRow(title: "Source code") { Link("GitHub ↗", destination: URL(string: "https://github.com/t1llo/frog")!) }
                    ForEach(LegalDocument.allCases.filter { $0.url() != nil }) { document in
                        CompactRow(title: document.title, detail: document.summary) { Button("View") { legalDocument = document } }
                    }
                    CompactRow(title: "Made by Tillo") { Link("beffa.xyz ↗", destination: URL(string: "https://beffa.xyz")!) }
                    CompactRow(title: "Contact") { Link("frog@beffa.xyz", destination: URL(string: "mailto:frog@beffa.xyz")!) }
                    Text("Build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")").font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                }.sheet(item: $legalDocument) { LegalDocumentView(document: $0) }
            }.toggleStyle(.switch).controlSize(.small).padding(20).frame(maxWidth: 630).frame(maxWidth: .infinity).minimalScrollbars()
        }.onAppear { model.refreshSystemStatus(forceLoginStatus: true) }
            .task(id: permissionsRequest.id) {
                guard permissionsRequest.id != nil else { return }
                await Task.yield()
                guard !Task.isCancelled, permissionsRequest.take() else { return }
                withAnimation { proxy.scrollTo("permissions", anchor: .top) }
            }
            .confirmationDialog("Replace configuration?", isPresented: $confirmingImport) {
                Button("Replace configuration") { if let pendingConfiguration { do { try model.importConfiguration(pendingConfiguration) } catch { model.report(error) } }; pendingConfiguration = nil }
                Button("Cancel", role: .cancel) { pendingConfiguration = nil }
            } message: { Text("The current settings are backed up. Provider keys may need to be re-entered.") }
        }
    }
    private func permission(_ title: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        CompactRow(title: title) {
            HStack(spacing: 10) {
                Label(allowed ? "Allowed" : "Permission needed", systemImage: allowed ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(allowed ? FrogStyle.accent : FrogStyle.warning)
                Button(allowed ? "Manage…" : "Allow…", action: action)
            }
        }
    }
    private func update(_ body: (inout WorkflowPreferences) -> Void) { var value = prefs; body(&value); do { try model.saveWorkflowPreferences(value) } catch { model.report(error) } }
    private func preference<T>(_ key: WritableKeyPath<Preferences, T>) -> Binding<T> { Binding(get: { model.configuration.preferences[keyPath: key] }, set: { value in var preferences = model.configuration.preferences; preferences[keyPath: key] = value; do { try model.savePreferences(preferences) } catch { model.report(error) } }) }
    private func exportConfiguration() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "config.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.exportConfiguration(to: url) } catch { model.report(error) }
    }
    private func chooseConfiguration() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { pendingConfiguration = try ConfigurationFile.read(from: url); confirmingImport = true } catch { model.report(error) }
    }
}

/// The two history limits while their steppers move. Saving a lower limit deletes the saved
/// entries that no longer fit, so such a change waits here until it has been asked about. Any
/// other change is saved at once.
@MainActor
final class HistoryLimitsDraft: ObservableObject {
    struct Limits: Equatable { var entries: Int; var days: Int }
    struct Question: Equatable {
        let limits: Limits
        /// How many saved entries the limits delete.
        let dropped: Int
        var title: String { dropped == 1 ? "Delete 1 history entry?" : "Delete \(dropped) history entries?" }
        var action: String { dropped == 1 ? "Delete entry" : "Delete \(dropped) entries" }
        var message: String {
            "History would keep at most \(limits.entries) \(limits.entries == 1 ? "entry" : "entries") from the last \(limits.days) \(limits.days == 1 ? "day" : "days"). The saved originals and results that no longer fit will be permanently deleted from this Mac."
        }
    }
    /// What the steppers show while it is not saved.
    @Published private(set) var value: Limits?
    /// The change that waits for an answer.
    @Published private(set) var question: Question?
    private let delay: Duration
    private let stored: () -> Limits
    private let dropped: (Limits) -> Int
    private let save: (Limits) -> Void
    private var pause: Task<Void, Never>?

    /// A held stepper waits half a second and then steps ten times a second; the delay is longer than both.
    init(delay: Duration = .milliseconds(800), stored: @escaping () -> Limits, dropped: @escaping (Limits) -> Int, save: @escaping (Limits) -> Void) {
        self.delay = delay; self.stored = stored; self.dropped = dropped; self.save = save
    }

    convenience init(model: AppModel, delay: Duration = .milliseconds(800)) {
        // Only the two limits are set, on the preferences of the moment: other settings may change while a question waits.
        let preferences: (Limits) -> Preferences = { limits in
            var preferences = model.configuration.preferences
            preferences.historyLimit = limits.entries; preferences.historyRetentionDays = limits.days
            return preferences
        }
        self.init(delay: delay,
                  stored: { Limits(entries: model.configuration.preferences.historyLimit, days: model.configuration.preferences.historyRetentionDays) },
                  dropped: { model.historyEntriesDropped(by: preferences($0)) },
                  save: { limits in do { try model.savePreferences(preferences(limits)) } catch { model.report(error) } })
    }

    /// One step of a stepper.
    func change(_ limits: Limits) {
        // The question on screen names a number of entries, which must stay true until it is answered.
        guard question == nil else { return }
        pause?.cancel(); pause = nil
        guard limits != stored() else { forget(); return }
        guard dropped(limits) > 0 else { forget(); save(limits); return }
        value = limits
        // Asked once, when the stepping has come to rest, for everything it would delete.
        pause = Task { [weak self, delay] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.ask()
        }
    }

    /// The stepping paused.
    func ask() {
        pause?.cancel(); pause = nil
        guard let value, question == nil else { return }
        let count = dropped(value)
        if count > 0 { question = Question(limits: value, dropped: count); return }
        // The history changed while the stepper moved, and nothing is left to ask about.
        forget()
        if value != stored() { save(value) }
    }

    /// The answer was to delete.
    func confirm(_ question: Question) {
        cancel()
        save(question.limits)
    }

    /// The answer was no, or the page went away: the steppers show the saved limits again.
    func cancel() {
        pause?.cancel(); pause = nil
        if question != nil { question = nil }
        forget()
    }

    private func forget() { if value != nil { value = nil } }
}

/// The Maximum entries and Retention rows of the History section.
struct HistoryLimitsView: View {
    @ObservedObject private var model: AppModel
    @StateObject private var draft: HistoryLimitsDraft
    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
        _draft = StateObject(wrappedValue: HistoryLimitsDraft(model: model))
    }
    var body: some View {
        CompactRow(title: "Maximum entries") {
            Stepper("\(limits.entries)", value: Binding(get: { limits.entries }, set: { value in var next = limits; next.entries = value; draft.change(next) }), in: 1...200).fixedSize()
        }
        Divider()
        CompactRow(title: "Retention") {
            Stepper("\(limits.days) days", value: Binding(get: { limits.days }, set: { value in var next = limits; next.days = value; draft.change(next) }), in: 1...30).fixedSize()
        }.onDisappear { draft.cancel() }
            // The window keeps this page when it closes. A step that was not asked about yet is dropped with it.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in if draft.question == nil { draft.cancel() } }
            .confirmationDialog(draft.question?.title ?? "Delete history entries?", isPresented: Binding(get: { draft.question != nil }, set: { if !$0 { draft.cancel() } }), titleVisibility: .visible) {
                // The button keeps the question it was shown with, whichever of its action and the dismissal comes first.
                if let question = draft.question { Button(question.action, role: .destructive) { draft.confirm(question) } }
                Button("Cancel", role: .cancel) { draft.cancel() }
            } message: { Text(draft.question?.message ?? "") }
    }
    private var limits: HistoryLimitsDraft.Limits {
        draft.value ?? .init(entries: model.configuration.preferences.historyLimit, days: model.configuration.preferences.historyRetentionDays)
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .semibold)).padding(.leading, 10)
            VStack(alignment: .leading, spacing: 7) { content }.padding(12).frame(maxWidth: .infinity).frogTableSurface()
        }
    }
}
