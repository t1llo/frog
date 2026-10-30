import Combine
import FrogCore

/// The selection bubble, owned by the Writing plugin: it watches while the plugin runs, its bubble is on and
/// Accessibility is allowed, and offers the Writing rules plus Explain while Explain is on.
@MainActor
final class WritingBubble {
    private(set) var settings: WritingConfig.Bubble
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
        model.selectionBubble = self
        // `$accessibilityGranted` publishes before the property changes, so the value comes along.
        accessibility = model.$accessibilityGranted.removeDuplicates().sink { [weak self] granted in
            self?.configure(accessibility: granted)
        }
    }

    func stop() {
        accessibility = nil
        if watcher.isRunning { watcher.stop() }
        if model?.selectionBubble === self { model?.selectionBubble = nil }
    }

    func update(_ settings: WritingConfig.Bubble) {
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
        return SelectionBubbleItems.items(rules: model.configuration.rules,
                                          explainEnabled: model.configuration.preferences.featureEnabled(.explain),
                                          writingEnabled: true, editable: snapshot.isEditable,
                                          configured: { (try? model.resolved($0)) != nil })
    }

    var state: BubbleState {
        guard let model else {
            return BubbleState(explainEnabled: false, bubbleEnabled: false, writingEnabled: false, accessibilityTrusted: false, busy: true)
        }
        return BubbleState(explainEnabled: model.configuration.preferences.featureEnabled(.explain), bubbleEnabled: settings.on,
                           writingEnabled: true, accessibilityTrusted: model.accessibilityGranted, busy: model.bubbleBusy)
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
