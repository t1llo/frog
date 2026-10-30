import Foundation
import FrogCore

/// An installed app the command bar knows, with what the cleaner needs to decide whether to offer it.
struct CleanerCommandApp {
    var record: SearchRecord
    var path: String
    var bundleID: String?
}

/// "Uninstall <App>" rows. Choosing one opens the review; nothing moves from the command bar.
@MainActor final class CleanerCommandRows: CommandBarRowProviding {
    private let applications: @MainActor () -> [CleanerCommandApp]
    private let ownBundlePath: String
    private let applicationFolders: [URL]

    init(applications: @escaping @MainActor () -> [CleanerCommandApp],
         ownBundlePath: String = Bundle.main.bundlePath,
         applicationFolders: [URL] = CleanerRoots().applicationFolders) {
        self.applications = applications
        self.ownBundlePath = ownBundlePath
        self.applicationFolders = applicationFolders
    }

    func queryRows(for query: String, in context: CommandBarContext) -> [CommandBarRow] {
        guard context.model.configuration.preferences.featureEnabled(.cleaner),
              let term = CleanerCommand.appQuery(query) else { return [] }
        let kept = applications().filter {
            CleanerCommand.offers(path: $0.path, bundleID: $0.bundleID, ownBundlePath: ownBundlePath,
                                  applicationFolders: applicationFolders)
        }
        let paths = Dictionary(kept.map { ($0.record.id, $0.path) }, uniquingKeysWith: { first, _ in first })
        return CommandSearch.results(kept.map(\.record), query: term, limit: 3).compactMap { app in
            guard let path = paths[app.id] else { return nil }
            return CommandBarRow(
                record: SearchRecord(id: CleanerCommand.rowID(path: path), title: "Uninstall \(app.title)",
                                     subtitle: "App cleaner · Review before anything moves", symbol: "trash.circle"),
                placement: .leading,
                primary: CommandRowAction(title: "Open review") { @MainActor [weak model = context.model] in
                    guard let model, let cleaner = model.cleanerPlugin?.cleaner else { return }
                    model.openFeature(.cleaner)
                    await cleaner.open(URL(fileURLWithPath: path))
                })
        }
    }
}
