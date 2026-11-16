import AppKit

/// Takes Frog's status items out of the menu bar without losing their places.
///
/// macOS keeps an item's place under `NSStatusItem Preferred Position <autosave name>` and deletes it when the item
/// is removed, and on macOS 26 again when the `NSStatusItem` deallocates (`dealloc` uninstalls it and clears its
/// saved state). Frog drops its items when features stop, also at every quit, so the next start put them at the far
/// left: the hidden bar's arrow and divider then hid nothing. Frog therefore never lets a status item deallocate,
/// leaves them in the bar while quitting (they go with the process and keep their places), and otherwise writes the
/// saved state back after removal.
@MainActor enum StatusItemRemoval {
    /// Set when Frog has decided to quit, before its features stop.
    static var appIsQuitting = false
    /// Items taken out of the bar. A few bytes each, once per feature switched off.
    private static var kept: [NSStatusItem] = []

    static func positionKey(_ autosaveName: String) -> String { "NSStatusItem Preferred Position \(autosaveName)" }

    static func remove(_ item: NSStatusItem) {
        kept.append(item)
        guard !appIsQuitting else {
            // The item stays until the process ends; it must not act for a feature that has stopped.
            item.button?.target = nil; item.button?.action = nil; item.menu = nil
            return
        }
        // Optional in newer SDKs.
        let name: String? = item.autosaveName
        let keys = name.map { [positionKey($0), "NSStatusItem Visible \($0)", "NSStatusItem VisibleCC \($0)"] } ?? []
        let saved = keys.compactMap { key in UserDefaults.standard.object(forKey: key).map { (key, $0) } }
        NSStatusBar.system.removeStatusItem(item)
        for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) }
    }
}
