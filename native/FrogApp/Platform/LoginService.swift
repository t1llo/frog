import ServiceManagement

@MainActor
enum LoginService {
    static var isEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }
    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "Frog starts at login."
        case .notRegistered: return "Start at login is off."
        case .requiresApproval: return "Allow Frog in System Settings → General → Login Items."
        case .notFound: return "Install Frog in Applications to enable start at login."
        @unknown default: return "Login item status is unavailable."
        }
    }
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else if SMAppService.mainApp.status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
    }
}
