import Combine
import FrogCore

/// The selection bubble. It runs while Writing or Explain runs, its switch in `[writing.bubble]` is on and
/// Accessibility is allowed, and offers the Writing rules while Writing is on and Explain while Explain is on.
@MainActor
final class WritingBubble: ObservableObject {
    @Published private(set) var settings: WritingConfig.Bubble
    /// The plugins that asked for the bubble; it stops when the last one lets go.
    fileprivate var users: Set<String> = []
    private weak var model: AppModel?
    private var accessibility: AnyCancellable?
    private lazy var watcher: any SelectionWatching = model?.injectedSelectionWatcher ?? makeWatcher()

    init(model: AppModel, settings: WritingConfig.Bubble) {
        self.model = model
        self.settings = settings
    }

    var isRunning: Bool { watcher.isRunning }

    func start() {
        guard let model else { return }
        // `$accessibilityGranted` publishes before the property changes, so the value comes along.
        accessibility = model.$accessibilityGranted.removeDuplicates().sink { [weak self] granted in
            self?.configure(accessibility: granted)
        }
    }

    func stop() {
        accessibility = nil
        if watcher.isRunning { watcher.stop() }
    }

    /// New settings, from the Writing page or an edit to config.toml. Pages that show them redraw.
    func update(_ settings: WritingConfig.Bubble) {
        guard settings != self.settings else { return }
        model?.objectWillChange.send()
        self.settings = settings
        configure(accessibility: model?.accessibilityGranted ?? false)
    }

    /// Hides the bubble because a rule just ran on the selection.
    func dismiss() { watcher.dismiss() }

    private func configure(accessibility granted: Bool) {
        let runs = settings.on && granted && model != nil
        if runs, !watcher.isRunning { watcher.start() }
        else if !runs, watcher.isRunning { watcher.stop() }
    }

    /// Built from the rules as they are when the bubble shows, so a rule changed since appears as it is now.
    func items(for snapshot: SelectionSnapshot) -> (visible: [BubbleItem], more: [BubbleItem]) {
        guard let model else { return ([], []) }
        let preferences = model.configuration.preferences
        return SelectionBubbleItems.items(rules: model.configuration.rules,
                                          explainEnabled: preferences.featureEnabled(.explain),
                                          writingEnabled: preferences.featureEnabled(.writing), editable: snapshot.isEditable,
                                          configured: { (try? model.resolved($0)) != nil })
    }

    var state: BubbleState {
        guard let model else {
            return BubbleState(explainEnabled: false, bubbleEnabled: false, writingEnabled: false, accessibilityTrusted: false, busy: true)
        }
        let preferences = model.configuration.preferences
        return BubbleState(explainEnabled: preferences.featureEnabled(.explain), bubbleEnabled: settings.on,
                           writingEnabled: preferences.featureEnabled(.writing), accessibilityTrusted: model.accessibilityGranted,
                           busy: model.bubbleBusy)
    }

    private func makeWatcher() -> any SelectionWatching {
        // Tests without a watcher of their own never install global monitors.
        guard let model, model.registerShortcuts else { return SilentSelectionWatcher() }
        return SelectionWatcher(reader: model.selectionReader ?? SelectionReader(), presenter: SelectionBubbleController(), hooks: .init(
            options: { [weak self] in self?.settings.options ?? SelectionBubbleOptions() },
            state: { [weak self] in
                self?.state ?? BubbleState(explainEnabled: false, bubbleEnabled: false, writingEnabled: false,
                                           accessibilityTrusted: false, busy: true)
            },
            items: { [weak self] in self?.items(for: $0) ?? ([], []) },
            run: { [weak self] item, snapshot in self?.model?.runBubbleItem(item, snapshot: snapshot) }))
    }
}

/// Where Writing and Explain share the bubble. Its settings live in `[writing.bubble]` whichever of them runs.
@MainActor
extension AppModel {
    /// Called from a plugin's `start`: the bubble runs from the first call until the last `releaseSelectionBubble`.
    func useSelectionBubble(by plugin: String) {
        seedWritingSettings()
        let bubble = selectionBubble ?? {
            let bubble = WritingBubble(model: self, settings: storedBubbleSettings())
            selectionBubble = bubble
            bubble.start()
            return bubble
        }()
        bubble.users.insert(plugin)
    }

    /// Called from a plugin's `stop`.
    func releaseSelectionBubble(by plugin: String) {
        guard let bubble = selectionBubble else { return }
        bubble.users.remove(plugin)
        guard bubble.users.isEmpty else { return }
        bubble.stop()
        selectionBubble = nil
    }

    /// Follows `[writing.bubble]` after config.toml changed.
    func reloadSelectionBubble() { selectionBubble?.update(storedBubbleSettings()) }

    private func storedBubbleSettings() -> WritingConfig.Bubble {
        (try? settingsFile.section(WritingPlugin.info.id, as: WritingConfig.self).value.bubble) ?? WritingConfig.Bubble()
    }

    /// Moves the bubble settings Explain kept into `[writing]`, once. Skipped while the settings could not be read,
    /// so defaults never stand in for them. Rules left out of the bubble say so first, so a failed table write
    /// repeats the move instead of losing it.
    func seedWritingSettings() {
        guard configurationLoaded, configuration.preferences.workflowSettings.writingSettingsMoved != true else { return }
        let legacy = configuration.preferences.explainSettings
        do {
            if settingsFile.document.value(at: [WritingPlugin.info.id]) == nil {
                let hidden = Set(legacy.bubbleHiddenRules)
                if !hidden.isEmpty {
                    try updateRules { rules in
                        for index in rules.indices where hidden.contains(rules[index].id) { rules[index].showsInBubble = false }
                    }
                }
                let explainOn = configuration.preferences.featureEnabled(.explain)
                try settingsFile.seedSection(WritingPlugin.info.id) { WritingConfig(legacy: legacy, explainOn: explainOn) }
            }
            try updateConfiguration { configuration in
                var workflow = configuration.preferences.workflowSettings
                workflow.writingSettingsMoved = true
                configuration.preferences.workflows = workflow
            }
        } catch { report(error) }
    }

    /// The same for `[explain]`.
    func seedExplainSettings() {
        guard configurationLoaded, configuration.preferences.workflowSettings.explainSettingsMoved != true else { return }
        let legacy = configuration.preferences.explainSettings
        do {
            try settingsFile.seedSection(ExplainPlugin.info.id) { ExplainConfig(legacy: legacy) }
            try updateConfiguration { configuration in
                var workflow = configuration.preferences.workflowSettings
                workflow.explainSettingsMoved = true
                configuration.preferences.workflows = workflow
            }
        } catch { report(error) }
    }
}
