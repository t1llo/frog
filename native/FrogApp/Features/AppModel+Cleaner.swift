extension AppModel {
    /// The App cleaner plugin while it is on.
    var cleanerPlugin: AppCleanerPlugin? { pluginHost.running[AppCleanerPlugin.info.id] as? AppCleanerPlugin }
}
