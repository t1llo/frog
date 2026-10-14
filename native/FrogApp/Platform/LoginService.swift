import ServiceManagement

enum LoginService {
    struct Snapshot: Sendable, Equatable {
        let enabled: Bool
        let text: String
        /// macOS will not start Frog at login until the person acts on `text`.
        var needsAttention = false
    }
    static func readStatus() -> Snapshot { snapshot(for: SMAppService.mainApp.status) }
    static func snapshot(for status: SMAppService.Status) -> Snapshot {
        let text: String
        switch status {
        case .enabled: text = "Frog starts at login."
        case .notRegistered: text = "Start at login is off."
        case .requiresApproval: text = "Allow Frog in System Settings → General → Login Items."
        case .notFound: text = "Install Frog in Applications to enable start at login."
        @unknown default: text = "Login item status is unavailable."
        }
        // An item awaiting approval stays on, so switching the toggle off still unregisters it.
        return Snapshot(enabled: status == .enabled || status == .requiresApproval, text: text, needsAttention: status == .requiresApproval)
    }
    static func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
    /// Talks to ServiceManagement like `readStatus`, so it may take hundreds of milliseconds.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else if SMAppService.mainApp.status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
    }
}
