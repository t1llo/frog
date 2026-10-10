import Foundation

/// Search metadata and navigation only: selecting a destination never changes a setting.
public struct SystemSetting: Equatable, Sendable {
    public let paneID: String
    public let anchor: String?
    public private(set) var record: SearchRecord
    public let destinations: [URL]
    private let aliases: [String]

    public init(paneID: String, title: String, keywords: String = "", aliases: [String] = [], symbol: String = "gearshape", anchor: String? = nil, legacyPaneID: String? = nil) {
        self.paneID = paneID; self.anchor = anchor
        self.aliases = aliases
        let suffix = anchor.map { "?" + $0 } ?? ""
        record = SearchRecord(id: "mac-setting:\(paneID)\(suffix)", title: title, subtitle: "System Settings", keywords: "mac macos system settings preferences " + keywords, symbol: symbol, aliases: aliases, queryStyle: .command)
        // The legacy security pane owns the stable Privacy_* anchors on macOS 14+.
        let route = anchor == nil ? paneID : legacyPaneID ?? paneID
        var paths = [route + suffix]
        if route != paneID || anchor != nil { paths.append(paneID) }
        else if let legacyPaneID { paths.append(legacyPaneID) }
        paths.append("")
        destinations = paths.compactMap { URL(string: "x-apple.systempreferences:" + $0) }
    }

    public func includingSearchTerms(_ words: String, localizedTitle: String) -> Self {
        var enriched = self
        enriched.record = SearchRecord(id: record.id, title: record.title, subtitle: record.subtitle,
            keywords: record.keywords + " " + words, symbol: record.symbol,
            aliases: aliases + [localizedTitle], queryStyle: .command)
        return enriched
    }
}

public enum SystemSettingsCatalog {
    /// Ready without disk access. Installed extension metadata enriches this baseline later.
    public static let defaults: [SystemSetting] = {
        func pane(_ id: String, _ title: String, _ words: String, _ aliases: [String] = [], _ symbol: String = "gearshape", legacy: String? = nil) -> SystemSetting {
            SystemSetting(paneID: id, title: title, keywords: words, aliases: aliases, symbol: symbol, legacyPaneID: legacy)
        }
        let privacy = "com.apple.settings.PrivacySecurity.extension"
        func permission(_ anchor: String, _ title: String, _ words: String, _ aliases: [String]) -> SystemSetting {
            SystemSetting(paneID: privacy, title: title, keywords: "privacy security permission access allow apps " + words, aliases: aliases, symbol: "hand.raised", anchor: anchor, legacyPaneID: "com.apple.preference.security")
        }
        return [
            pane("com.apple.Wallpaper-Settings.extension", "Wallpaper", "desktop picture image photo background screensaver", ["desktop background", "desktop wallpaper", "desktop picture", "background"], "photo", legacy: "com.apple.preference.desktopscreeneffect"),
            pane("com.apple.Desktop-Settings.extension", "Desktop & Dock", "mission control spaces stage manager widgets icons hide size position minimize windows", ["desktop", "dock", "mission control", "stage manager", "desktop icons"], "dock.rectangle", legacy: "com.apple.preference.dock"),
            pane("com.apple.wifi-settings-extension", "Wi-Fi", "network internet wireless router hotspot ssid password connect connection", ["wifi", "wi fi", "wireless", "wireless network"], "wifi", legacy: "com.apple.preference.network"),
            pane("com.apple.Sound-Settings.extension", "Sound", "audio volume output input microphone speakers headphones alert effects mute", ["audio", "volume", "audio output", "audio input", "microphone input", "sound output", "sound input"], "speaker.wave.2", legacy: "com.apple.preference.sound"),
            pane(privacy, "Privacy & Security", "permissions access gatekeeper filevault firewall encryption apps location", ["privacy", "security", "app permissions"], "hand.raised", legacy: "com.apple.preference.security"),
            permission("Privacy_Accessibility", "Accessibility Permissions", "control computer assistive keyboard automation", ["accessibility permission", "accessibility permissions", "control my computer"]),
            permission("Privacy_ScreenCapture", "Screen Recording Permissions", "screen capture share sharing display recording audio", ["screen recording", "screen capture permission", "screen sharing permission"]),
            permission("Privacy_Microphone", "Microphone Permissions", "microphone mic recording audio input", ["microphone permission", "microphone permissions", "mic permission", "privacy microphone"]),
            permission("Privacy_Camera", "Camera Permissions", "camera webcam video facetime", ["camera", "webcam", "camera permission", "privacy camera"]),
            permission("Privacy_AllFiles", "Full Disk Access", "disk files folders drive filesystem", ["full disk access", "disk permission", "all files"]),
            permission("Privacy_FilesAndFolders", "Files & Folders Permissions", "documents downloads desktop files folders", ["files and folders", "file permissions", "folder permissions"]),
            permission("Privacy_LocationServices", "Location Services", "location gps maps find tracking", ["location", "location services", "location permission"]),
            permission("Privacy_Automation", "Automation Permissions", "apple events applescript control other apps", ["automation", "automation permission", "apple events"]),
            permission("Privacy_ListenEvent", "Input Monitoring", "keyboard mouse input monitoring listen event", ["input monitoring", "keyboard monitoring"]),
            permission("Privacy_Contacts", "Contacts Permissions", "contacts address book people", ["contacts permission", "contacts access"]),
            permission("Privacy_Calendars", "Calendars Permissions", "calendar events appointments", ["calendar permission", "calendar access"]),
            pane("com.apple.Displays-Settings.extension", "Displays", "monitor resolution brightness scaling refresh rate retina hdr night shift true tone color colour arrangement mirroring airplay", ["display", "screen brightness", "screen resolution", "night shift", "external monitor"], "display", legacy: "com.apple.preference.displays"),
            pane("com.apple.Appearance-Settings.extension", "Appearance", "dark light mode automatic accent highlight color colour theme sidebar icon size", ["dark mode", "light mode", "theme", "accent color"], "circle.lefthalf.filled", legacy: "com.apple.preference.general"),
            pane("com.apple.BluetoothSettings", "Bluetooth", "pair device connect wireless headphones keyboard mouse airpods", ["bluetooth devices", "pair headphones", "pair airpods"], "antenna.radiowaves.left.and.right", legacy: "com.apple.preferences.Bluetooth"),
            pane("com.apple.Network-Settings.extension", "Network", "internet ethernet connection ip address dns proxy proxies tcp dhcp firewall", ["internet", "ethernet", "dns", "ip address", "network connection"], "network", legacy: "com.apple.preference.network"),
            pane("com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension", "VPN", "virtual private network tunnel configuration connection", ["vpn connection", "virtual private network"], "network"),
            pane("com.apple.Notifications-Settings.extension", "Notifications", "notification alerts banners badges sounds preview permission", ["notification", "notification sounds", "notification previews"], "bell", legacy: "com.apple.preference.notifications"),
            pane("com.apple.Focus-Settings.extension", "Focus", "do not disturb dnd quiet sleep work notifications schedule", ["do not disturb", "dnd", "focus mode"], "moon"),
            pane("com.apple.Keyboard-Settings.extension", "Keyboard", "shortcuts key repeat delay function fn dictation input sources language text replacement backlight", ["keyboard shortcuts", "key repeat", "dictation", "keyboard language", "text replacement"], "keyboard", legacy: "com.apple.preference.keyboard"),
            pane("com.apple.Mouse-Settings.extension", "Mouse", "pointer cursor tracking speed acceleration scroll scrolling direction secondary right click", ["mouse speed", "mouse acceleration", "scroll direction", "right click"], "computermouse", legacy: "com.apple.preference.mouse"),
            pane("com.apple.Trackpad-Settings.extension", "Trackpad", "gestures tap click force touch tracking speed scroll scrolling direction swipe pinch", ["trackpad gestures", "tap to click", "three finger drag"], "hand.draw", legacy: "com.apple.preference.trackpad"),
            pane("com.apple.Accessibility-Settings.extension", "Accessibility", "vision voiceover zoom display contrast reduce motion spoken content hearing captions motor pointer control switch voice control", ["voiceover", "reduce motion", "increase contrast", "voice control"], "accessibility", legacy: "com.apple.preference.universalaccess"),
            pane("com.apple.ControlCenter-Settings.extension", "Control Center", "menu bar menubar icons clock battery percentage controls", ["control centre", "menu bar", "menu bar icons", "battery percentage"], "switch.2"),
            pane("com.apple.Lock-Screen-Settings.extension", "Lock Screen", "screensaver screen saver display sleep timeout password require idle inactivity", ["screen saver", "screensaver", "screen timeout", "lock screen password"], "lock"),
            pane("com.apple.Battery-Settings.extension", "Battery", "power energy low power mode charging health optimization sleep adapter", ["battery health", "low power mode", "energy saver", "charging"], "battery.75", legacy: "com.apple.preference.energysaver"),
            pane("com.apple.LoginItems-Settings.extension", "Login Items & Extensions", "startup background launch login open automatically extensions", ["login items", "startup apps", "background apps", "launch at login", "extensions"], "list.bullet", legacy: "com.apple.preferences.users"),
            pane("com.apple.Software-Update-Settings.extension", "Software Update", "macos update upgrade automatic beta security download install", ["updates", "macos update", "system update", "automatic updates"], "arrow.triangle.2.circlepath", legacy: "com.apple.preferences.softwareupdate"),
            pane("com.apple.settings.Storage", "Storage", "disk space free available drive capacity applications documents cleanup", ["disk space", "free space", "storage space", "disk usage"], "internaldrive"),
            pane("com.apple.Time-Machine-Settings.extension", "Time Machine", "backup backups restore disk automatic history", ["backup", "backups", "time machine backup"], "clock.arrow.circlepath", legacy: "com.apple.prefs.backup"),
            pane("com.apple.Sharing-Settings.extension", "Sharing", "file screen remote login ssh management printer internet computer name hostname", ["file sharing", "screen sharing", "remote login", "ssh", "computer name"], "square.and.arrow.up", legacy: "com.apple.preferences.sharing"),
            pane("com.apple.AirDrop-Handoff-Settings.extension", "AirDrop & Handoff", "continuity universal clipboard nearby iphone ipad receiving", ["airdrop", "handoff", "universal clipboard", "continuity"], "airplayaudio"),
            pane("com.apple.Date-Time-Settings.extension", "Date & Time", "clock timezone time zone automatic calendar format", ["date", "time zone", "timezone", "clock"], "clock", legacy: "com.apple.preference.datetime"),
            pane("com.apple.Localization-Settings.extension", "Language & Region", "language region locale translation temperature measurement units date format number format", ["language", "region", "language and region", "date format"], "globe", legacy: "com.apple.Localization"),
            pane("com.apple.SystemProfiler.AboutExtension", "About This Mac", "macos version serial model chip processor memory ram warranty", ["about", "mac version", "serial number", "memory", "processor"], "info.circle"),
            pane("com.apple.Startup-Disk-Settings.extension", "Startup Disk", "boot volume operating system disk", ["boot disk", "startup disk"], "internaldrive"),
            pane("com.apple.Transfer-Reset-Settings.extension", "Transfer or Reset", "migration assistant migrate transfer erase reset factory content", ["migration assistant", "factory reset", "erase mac"], "arrow.triangle.2.circlepath"),
            pane("com.apple.Users-Groups-Settings.extension", "Users & Groups", "account user administrator guest login password groups", ["users", "user accounts", "guest account", "login password"], "person.2", legacy: "com.apple.preferences.users"),
            pane("com.apple.Touch-ID-Settings.extension", "Touch ID & Password", "fingerprint biometric login unlock password watch", ["touch id", "fingerprint", "unlock with watch"], "touchid"),
            pane("com.apple.Internet-Accounts-Settings.extension", "Internet Accounts", "mail email contacts calendar google exchange icloud account", ["email accounts", "mail accounts", "internet accounts"], "at", legacy: "com.apple.preferences.internetaccounts"),
            pane("com.apple.systempreferences.AppleIDSettings", "Apple Account", "apple id icloud account sign in password subscriptions storage family", ["apple id", "icloud", "apple account"], "person.crop.circle"),
            pane("com.apple.Family-Settings.extension", "Family", "family sharing parental children child purchases", ["family sharing", "parental controls"], "person.2"),
            pane("com.apple.Screen-Time-Settings.extension", "Screen Time", "app limits downtime content privacy restrictions usage children", ["app limits", "downtime", "screen time limits"], "hourglass"),
            pane("com.apple.Siri-Settings.extension", "Siri & Apple Intelligence", "siri apple intelligence assistant voice ai writing tools", ["siri", "apple intelligence", "writing tools"], "sparkles"),
            pane("com.apple.Spotlight-Settings.extension", "Spotlight", "search indexing results privacy siri suggestions keyboard shortcut", ["spotlight search", "search indexing", "spotlight privacy"], "magnifyingglass", legacy: "com.apple.preference.spotlight"),
            pane("com.apple.Print-Scan-Settings.extension", "Printers & Scanners", "print scan printer scanner queue paper default airprint", ["printer", "scanner", "print queue", "add printer"], "printer", legacy: "com.apple.preference.printfax"),
            pane("com.apple.Profiles-Settings.extension", "Device Management", "profiles configuration mdm enterprise managed organization", ["profiles", "configuration profiles", "mdm"], "person.badge.shield.checkmark"),
            pane("com.apple.Game-Controller-Settings.extension", "Game Controllers", "gamepad controller joystick buttons games", ["game controller", "gamepad", "controller"], "gamecontroller"),
            pane("com.apple.Game-Center-Settings.extension", "Game Center", "games friends achievements multiplayer account", ["game center"], "gamecontroller"),
            pane("com.apple.WalletSettingsExtension", "Wallet & Apple Pay", "wallet payment card credit debit billing", ["apple pay", "wallet", "payment cards"], "creditcard"),
            pane("com.apple.Coverage-Settings.extension", "AppleCare & Warranty", "coverage warranty applecare support repairs service", ["applecare", "warranty", "coverage"], "checkmark.shield")
        ]
    }()
}
