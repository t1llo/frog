import AppKit
import SwiftUI
import FrogCore

/// `[app-cleaner]` in config.toml.
struct AppCleanerSettings: ConfigSection {
    var possibleMatches = false

    static let comments = ["possible-matches": "Also list files whose names only resemble the app; never ticked"]

    init() {}
    init(legacy: CleanerPreferences) { possibleMatches = legacy.possibleMatches }
}

/// Uninstalls apps with their leftovers, always into the Trash. Nothing is read until the page opens or an
/// action runs, and turning the plugin off drops everything it read.
final class AppCleanerPlugin: LegacyPlugin, FrogPlugin, ObservableObject {
    static let info = PluginInfo(id: "app-cleaner", name: "App cleaner", symbol: "trash", tint: .red, category: .system,
                                 summary: "Remove apps with what they leave behind")
    @Published private(set) var settings = AppCleanerSettings()
    private var model_: CleanerModel?

    /// Made on first use.
    var cleaner: CleanerModel {
        if let model_ { return model_ }
        let made = CleanerModel(dependencies: model.makeCleanerDependencies())
        made.showPossibleMatches = settings.possibleMatches
        model_ = made
        return made
    }

    func start() async {
        settings = MacPluginSettings.load(context, legacy: { AppCleanerSettings(legacy: $0.preferences.cleanerSettings) })
    }

    func stop() async {
        model_?.stop()
        model_ = nil
    }

    func settingsChanged() {
        settings = context.settings(AppCleanerSettings.self)
        model_?.showPossibleMatches = settings.possibleMatches
    }

    func update(_ change: (inout AppCleanerSettings) -> Void) {
        var value = settings
        change(&value)
        guard value != settings else { return }
        settings = value
        do { try context.save(value) } catch { context.report(error) }
        model_?.showPossibleMatches = value.possibleMatches
    }

    func page() -> AnyView? {
        legacyPage(CleanerView(cleaner: cleaner) { [weak self] on in self?.update { $0.possibleMatches = on } })
    }

    struct Leftovers: Encodable {
        struct Item: Encodable {
            let path: String
            let kind: String
            let confidence: String
            let reason: String
            let bytes: Int64?
            let ticked: Bool
            let sharedWith: [String]
        }
        let app: String
        let bundleID: String
        let path: String
        let items: [Item]
        let tickedBytes: Int64
    }

    struct Uninstalled: Encodable {
        let moved: [String]
        let bytes: Int64
        let failures: [String: String]
        let notes: [String]
    }

    private static let appParameter = ActionParameter(name: "app", required: true, help: "The app's name, bundle ID or path")

    var actions: [PluginAction] {
        [PluginAction(id: "app-cleaner.scan", title: "Find an app's leftovers", symbol: "magnifyingglass",
                      keywords: "uninstall leftovers files", parameters: [Self.appParameter], surfaces: [.agent]) { [weak self] input in
            guard let self else { return .done() }
            let cleaner = self.cleaner
            let app = try await cleaner.findApp(try input.required("app"))
            let review = try await cleaner.scanReport(app)
            let shown = review.items.filter { CleanerGroupKind.of($0, showPossible: cleaner.showPossibleMatches) != nil }
            let items = shown.map { item in
                Leftovers.Item(path: item.id, kind: item.kind.rawValue, confidence: "\(item.confidence)", reason: item.reason,
                               bytes: review.sizes[item.id]?.bytes ?? item.size, ticked: review.selected.contains(item.id),
                               sharedWith: item.sharedWith)
            }
            let report = Leftovers(app: app.name, bundleID: app.bundleID, path: app.path, items: items, tickedBytes: review.selectedBytes)
            let lines = shown.map { (review.selected.contains($0.id) ? "[x] " : "[ ] ") + cleaner.dependencies.roots.displayPath($0.url) }
            return ActionResult(report, text: (["\(app.name): \(review.selectionSummary()) would move to the Trash."] + lines).joined(separator: "\n"))
         },
         PluginAction(id: "app-cleaner.uninstall", title: "Uninstall an app", symbol: "trash",
                      keywords: "uninstall remove delete app",
                      parameters: [Self.appParameter,
                                   ActionParameter(name: "confirm", kind: .boolean, help: "Required: moves the app and its ticked leftovers to the Trash")],
                      surfaces: [.agent]) { [weak self] input in
            guard let self else { return .done() }
            guard try input.boolean("confirm") == true else {
                throw ActionError.failed("Uninstalling moves files to the Trash. Run `frog run app-cleaner.scan` to see what, then add --confirm true.")
            }
            let cleaner = self.cleaner
            let app = try await cleaner.findApp(try input.required("app"))
            let outcome = try await cleaner.uninstall(app)
            let summary = RemovalSummary(outcome)
            let failures = Dictionary(outcome.failures.map { ($0.path, $0.message) }, uniquingKeysWith: { first, _ in first })
            let result = Uninstalled(moved: outcome.moved.map(\.original), bytes: outcome.movedBytes, failures: failures, notes: summary.notes)
            let text = ([summary.title] + outcome.failures.map { "\($0.path): \($0.message)" } + summary.notes).joined(separator: "\n")
            guard !outcome.moved.isEmpty else { throw ActionError.failed(text) }
            return ActionResult(result, text: text)
         }]
    }
}
