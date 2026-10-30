import AppKit
import FrogCore

/// The installed applications. The list from the last scan is listed at once; opening the bar scans again in
/// the background and replaces the rows only when something was installed, removed or renamed.
@MainActor final class ApplicationCommandRows: CommandBarRowProviding {
    private let load: @MainActor () async -> [Rule]
    private let alternativeNames: @MainActor (String) -> [String]
    private(set) var installed: [Rule] = []
    /// By application path.
    private var records: [String: SearchRecord] = [:]
    private var scan: Task<Void, Never>?
    private var changed: (@MainActor () -> Void)?

    init(load: @escaping @MainActor () async -> [Rule], alternativeNames: @escaping @MainActor (String) -> [String]) {
        self.load = load; self.alternativeNames = alternativeNames
    }

    /// Reads the list once, for a first open that has its rows and icons.
    func warm() async { cache(await load()) }

    /// An application is found under the name Finder shows, under its bundle and file names and under the last part
    /// of its identifier. The rest of the identifier, `com.` and the like, would match every application.
    @discardableResult func cache(_ rules: [Rule]) -> Bool {
        guard rules != installed else { return false }
        installed = rules
        records = [:]
        for rule in rules {
            guard let path = rule.action?.applicationPath else { continue }
            let identifier = rule.action?.applicationBundleID?.split(separator: ".").last.map(String.init) ?? ""
            records[path] = SearchRecord(id: "app:\(path)", title: rule.name, subtitle: "App", keywords: identifier, symbol: "app",
                                         aliases: alternativeNames(path), prominent: true)
        }
        return true
    }

    /// The applications listed before anything is typed.
    var suggested: [SearchRecord] {
        installed.prefix(8).compactMap { $0.action?.applicationPath.flatMap { records[$0] } }
    }

    /// The listed applications, for the App cleaner's "Uninstall" rows.
    var cleanerApplications: [CleanerCommandApp] {
        installed.compactMap { rule in
            guard let path = rule.action?.applicationPath, let record = records[path] else { return nil }
            return CleanerCommandApp(record: record, path: path, bundleID: rule.action?.applicationBundleID)
        }
    }

    func rows(in context: CommandBarContext) -> [CommandBarRow] {
        installed.compactMap { rule in
            guard let path = rule.action?.applicationPath, let record = records[path] else { return nil }
            let toolUse = context.toolUse
            return CommandBarRow(record: record, primary: CommandRowAction(title: "Open") {
                try await ApplicationLauncher().launch(rule)
                try Task.checkCancellation()
                toolUse(.applicationCommand)
            }, iconPath: path)
        }
    }

    func open(in context: CommandBarContext, changed: @escaping @MainActor () -> Void) { self.changed = changed }

    /// Scans again while the bar is shown; apps installed or removed since replace the listed ones.
    func rescan() {
        guard let changed else { return }
        scan?.cancel()
        scan = Task { [weak self] in
            guard let self else { return }
            let rules = await self.load()
            guard !Task.isCancelled, self.cache(rules) else { return }
            changed()
        }
    }

    func close() { scan?.cancel(); scan = nil; changed = nil }

    func clear() { close(); installed = []; records = [:] }
}
