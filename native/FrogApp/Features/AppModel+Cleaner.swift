import FrogCore

extension AppModel {
    /// Saves a change to the cleaner's portable switches through `updateToolkit`, so the cleaner never builds
    /// `toolkit` by hand.
    func updateCleanerSettings(_ change: (inout CleanerPreferences) -> Void) throws {
        try updateToolkit { toolkit in
            var settings = toolkit.cleaner ?? CleanerPreferences()
            change(&settings)
            toolkit.cleaner = settings.normalized
        }
    }
}
