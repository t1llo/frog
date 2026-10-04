import ServiceManagement

enum LoginService {
    struct Snapshot: Sendable, Equatable {
        let enabled: Bool
        let text: String
    }
    static func readStatus() -> Snapshot {
        let status = SMAppService.mainApp.status
        let text: String
        switch status {
        case .enabled: text = "Frog starts at login."
        case .notRegistered: text = "Start at login is off."
        case .requiresApproval: text = "Allow Frog in System Settings → General → Login Items."
        case .notFound: text = "Install Frog in Applications to enable start at login."
        @unknown default: text = "Login item status is unavailable."
        }
        return Snapshot(enabled: status == .enabled || status == .requiresApproval, text: text)
    }
    @MainActor
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else if SMAppService.mainApp.status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
    }
}
