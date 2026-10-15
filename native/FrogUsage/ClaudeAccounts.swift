// Several Claude accounts on one Mac: where they are, which folders belong together, and their names.
import Foundation
import CryptoKit

/// A place on this Mac that can hold a Claude account. Only names and the existence of files
/// decide that a place is one; its contents are read later, by whoever shows its usage.
enum ClaudeAccountSource: Hashable {
    /// A Claude app folder under Application Support.
    case app(URL)
    /// A Claude Code configuration folder and the profile file that names its account.
    case code(URL, profile: URL)

    var folder: URL {
        switch self {
        case .app(let folder), .code(let folder, _): folder
        }
    }
}

/// Finds the Claude app folders and Claude Code profiles on this Mac. Names are listed and files
/// checked for existence; the only contents read are each profile's `.claude.json`, for whether it
/// holds a login. The Claude app's `config.json`, cookies and storage are never opened, and no
/// other process is looked at.
enum ClaudeAccountDiscovery {
    static let appMarkers = (history: ClaudeDesktopUsage.historyFileName, sessions: "claude-code-sessions")
    /// A profile file is a few kilobytes; one far larger is not Claude Code's.
    static let maximumProfileSize = 4 << 20

    /// The Claude app folders by name, then the Claude Code profiles: the default one, the
    /// `.claude-*` folders by name, `.config/claude`, the folder chosen in Frog, `CLAUDE_CONFIG_DIR`
    /// and `extraFolders`. A folder reached twice, also through a symbolic link, counts once.
    static func sources(home: URL, extraFolders: [URL] = [],
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        defaults: UserDefaults = UsagePreferences.defaults,
                        fileManager: FileManager = .default,
                        read: (URL) -> Data? = { try? Data(contentsOf: $0) }) -> [ClaudeAccountSource] {
        var seen = Set<String>()
        func unseen(_ url: URL) -> Bool { seen.insert(url.resolvingSymlinksInPath().path).inserted }
        let apps = appFolders(home: home, fileManager: fileManager).filter(unseen).map(ClaudeAccountSource.app)
        let profiles = profileFolders(home: home, extraFolders: extraFolders, environment: environment, defaults: defaults,
                                      fileManager: fileManager).compactMap { folder -> ClaudeAccountSource? in
            let profile = claudeProfileURL(directory: folder, home: home)
            guard isDirectory(folder, fileManager), unseen(folder),
                  hasLogin(profile, fileManager: fileManager, read: read) else { return nil }
            return .code(folder, profile: profile)
        }
        return apps + profiles
    }

    /// `Claude`, `Claude-…` and `Claude …` directly under Application Support, when they hold the
    /// app's usage history or its Claude Code sessions. This leaves out other apps such as
    /// `ClaudeUsageBar`.
    static func appFolders(home: URL, fileManager: FileManager = .default) -> [URL] {
        let support = home.appendingPathComponent("Library/Application Support")
        let names = (try? fileManager.contentsOfDirectory(atPath: support.path)) ?? []
        return names.filter(isAppFolderName).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { support.appendingPathComponent($0) }
            .filter { folder in
                isRegularFile(folder.appendingPathComponent(appMarkers.history), fileManager)
                    || isDirectory(folder.appendingPathComponent(appMarkers.sessions), fileManager)
            }
    }

    static func isAppFolderName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "claude" || lower.hasPrefix("claude-") || lower.hasPrefix("claude ")
    }

    /// Every folder that may be a Claude Code profile, in the order slots are listed.
    private static func profileFolders(home: URL, extraFolders: [URL], environment: [String: String],
                                       defaults: UserDefaults, fileManager: FileManager) -> [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: home.path)) ?? []
        let named = names.filter { $0.hasPrefix(".claude-") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { home.appendingPathComponent($0) }
        let chosen = [defaults.string(forKey: ClaudePaths.directoryPreference), environment["CLAUDE_CONFIG_DIR"]]
            .compactMap { path -> URL? in
                guard let path, !path.isEmpty else { return nil }
                return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            }
        return ([ClaudePaths.defaultDirectory(home: home)] + named + [home.appendingPathComponent(".config/claude")]
                + chosen + extraFolders).map(\.standardizedFileURL)
    }

    /// The profile file holds an `oauthAccount` object once Claude Code signed in there.
    private static func hasLogin(_ profile: URL, fileManager: FileManager, read: (URL) -> Data?) -> Bool {
        guard isRegularFile(profile, fileManager),
              let size = (try? fileManager.attributesOfItem(atPath: profile.path))?[.size] as? NSNumber,
              size.intValue <= maximumProfileSize,
              let data = read(profile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return root["oauthAccount"] is [String: Any]
    }

    private static func isDirectory(_ url: URL, _ fileManager: FileManager) -> Bool {
        var directory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    private static func isRegularFile(_ url: URL, _ fileManager: FileManager) -> Bool {
        var directory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue
    }
}

/// One Claude account, anchored to a slot: a Claude app folder, or a Claude Code profile that
/// belongs to no app folder. The organization is only held in memory to tell accounts apart; it
/// is never shown, saved or exported.
struct ClaudeAccount: Equatable, Identifiable {
    /// The anchoring folder's path. It names the slot in saved labels and polling state.
    let slotPath: String
    var defaultLabel: String
    let appFolder: URL?
    let codeFolder: URL?
    let profileFile: URL?
    let organization: String?
    /// Further app folders signed in to the same organization, shown as this one account.
    var mergedFolders: [URL] = []
    /// Where this slot's polling state is saved. The default slot keeps the key Frog used before
    /// it knew several accounts, so updating loses no cooldowns.
    let pollingKey: String

    var id: String { slotPath }

    /// "Claude and Claude-2 are signed in to the same account", or nil with nothing merged.
    var mergedDescription: String? {
        guard let first = appFolder, !mergedFolders.isEmpty else { return nil }
        let names = ([first] + mergedFolders).map(\.lastPathComponent)
        let list = names.count == 2 ? names.joined(separator: " and ")
            : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        return "\(list) are signed in to the same account"
    }

    static func pollingKey(slotPath: String, isDefault: Bool) -> String {
        guard !isDefault else { return ClaudePollingState.defaultsKey }
        let digest = SHA256.hash(data: Data(slotPath.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return ClaudePollingState.defaultsKey + "." + digest
    }
}

/// Decides which app folders and profiles are the same account, from the organization each one
/// names now: the newest sample of a folder's history, and a profile's `oauthAccount`.
enum ClaudeAccountMatching {
    struct App: Equatable {
        let folder: URL
        /// `ClaudeDesktopReading.organization` of the folder's newest sample.
        let organization: String?
    }

    struct Profile: Equatable {
        let folder: URL
        let file: URL
        /// `oauthAccount.organizationUuid` of the profile file.
        let organization: String?

        /// The default profile is the one whose file lies beside its folder, in the home folder.
        var isDefault: Bool {
            folder.lastPathComponent == ".claude"
                && file.standardizedFileURL == folder.deletingLastPathComponent().appendingPathComponent(".claude.json").standardizedFileURL
        }
    }

    /// App slots by folder, then the profiles that joined none. A profile joins the app folder
    /// when exactly one app folder names its organization, the rule the plan badge follows. App
    /// folders naming one organization are one account, so combined totals never count it twice.
    static func accounts(apps: [App], profiles: [Profile]) -> [ClaudeAccount] {
        struct Slot { var app: App?; var profile: Profile?; var merged: [URL] = [] }
        var slots: [Slot] = []
        for app in apps {
            if let organization = app.organization,
               let index = slots.firstIndex(where: { $0.app?.organization == organization }) {
                slots[index].merged.append(app.folder)
            } else {
                slots.append(Slot(app: app))
            }
        }
        for profile in profiles {
            let owners = apps.filter { $0.organization != nil && $0.organization == profile.organization }
            if owners.count == 1, let index = slots.firstIndex(where: { $0.app?.folder == owners[0].folder }) {
                if slots[index].profile == nil { slots[index].profile = profile } else { slots[index].merged.append(profile.folder) }
            } else {
                slots.append(Slot(profile: profile))
            }
        }
        let defaultSlot = slots.firstIndex { $0.app.map { $0.folder.lastPathComponent == "Claude" } ?? false }
            ?? slots.firstIndex { $0.profile?.isDefault == true }
        let anchors = slots.map { ($0.app?.folder ?? $0.profile!.folder).standardizedFileURL }
        let labels = ClaudeAccountLabels.defaultLabels(for: slots.map { $0.app.map { ClaudeAccountSource.app($0.folder) }
            ?? .code($0.profile!.folder, profile: $0.profile!.file) })
        return slots.indices.map { index in
            let slot = slots[index], path = anchors[index].path
            return ClaudeAccount(slotPath: path, defaultLabel: labels[index], appFolder: slot.app?.folder,
                                 codeFolder: slot.profile?.folder, profileFile: slot.profile?.file,
                                 organization: slot.app?.organization ?? slot.profile?.organization,
                                 mergedFolders: slot.merged,
                                 pollingKey: ClaudeAccount.pollingKey(slotPath: path, isDefault: index == defaultSlot))
        }
    }
}

/// The names people see for their Claude accounts, and whether each counts in the menu bar and
/// combined totals. Saved on this Mac only, by slot path; never in the configuration file and
/// never exported.
final class ClaudeAccountLabels {
    static let defaultsKey = "claudeAccounts.v1"
    static let maximumLength = 16
    static let shortLength = 6

    struct Entry: Codable, Equatable {
        /// Nil keeps the default label.
        var label: String?
        var included = true
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = UsagePreferences.defaults) { self.defaults = defaults }

    private var entries: [String: Entry] {
        get { defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.defaultsKey) }
    }

    func label(for account: ClaudeAccount) -> String { entries[account.slotPath]?.label ?? account.defaultLabel }

    func isIncluded(_ account: ClaudeAccount) -> Bool { entries[account.slotPath]?.included ?? true }

    func setIncluded(_ included: Bool, for account: ClaudeAccount) {
        var entries = entries
        entries[account.slotPath, default: Entry()].included = included
        self.entries = entries
    }

    /// Spaces trimmed and at most 16 characters; empty returns to the default label. A label
    /// another account already has gets " 2", then " 3", added. Returns the label kept.
    @discardableResult
    func rename(_ account: ClaudeAccount, to name: String, among accounts: [ClaudeAccount]) -> String {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let taken = Set(accounts.filter { $0.slotPath != account.slotPath }.map { label(for: $0).lowercased() })
        let label = Self.unique(trimmed.isEmpty ? account.defaultLabel : trimmed, taken: taken)
        var entries = entries
        entries[account.slotPath, default: Entry()].label = label == account.defaultLabel ? nil : label
        self.entries = entries
        return label
    }

    /// The menu bar has room for the first six characters.
    static func shortLabel(_ label: String) -> String { String(label.prefix(shortLength)) }

    private static func unique(_ label: String, taken: Set<String>) -> String {
        guard taken.contains(label.lowercased()) else { return label }
        var number = 2
        while true {
            let suffix = " \(number)"
            let candidate = String(label.prefix(maximumLength - suffix.count)).trimmingCharacters(in: .whitespaces) + suffix
            if !taken.contains(candidate.lowercased()) { return candidate }
            number += 1
        }
    }

    // MARK: Default labels

    /// The default Claude app folder is A; a folder or profile named for one letter keeps that
    /// letter; `.claude-work` is "Work". Every other slot gets the next letter nobody has, in slot
    /// order: app folders by name, then profiles.
    static func defaultLabels(for sources: [ClaudeAccountSource]) -> [String] {
        var labels = sources.map(namedLabel)
        var taken = Set<String>()
        for index in labels.indices {
            guard let label = labels[index] else { continue }
            if !taken.insert(label.lowercased()).inserted { labels[index] = nil }
        }
        var letters = (UInt8(ascii: "A")...UInt8(ascii: "Z")).map { String(UnicodeScalar($0)) }
            .filter { !taken.contains($0.lowercased()) }.makeIterator()
        return labels.indices.map { index in labels[index] ?? letters.next() ?? "Account \(index + 1)" }
    }

    /// The label a slot's own name gives it, or nil when it names none.
    static func namedLabel(_ source: ClaudeAccountSource) -> String? {
        switch source {
        case .app(let folder):
            let name = folder.lastPathComponent
            if name.lowercased() == "claude" { return "A" }
            return letter(in: String(name.dropFirst("claude".count)))
        case .code(let folder, _):
            let name = folder.lastPathComponent
            guard name.lowercased().hasPrefix(".claude-") else { return nil }
            let rest = String(name.dropFirst(".claude-".count))
            if let letter = letter(in: "-" + rest) { return letter }
            guard let first = rest.first else { return nil }
            return String((first.uppercased() + rest.dropFirst()).prefix(maximumLength))
        }
    }

    /// "-Account-B", " B" and "-B" name the letter B, in either case.
    private static func letter(in suffix: String) -> String? {
        var rest = Substring(suffix)
        guard let separator = rest.first, separator == "-" || separator == " " else { return nil }
        rest = rest.dropFirst()
        if rest.lowercased().hasPrefix("account"), rest.count == "account".count + 2,
           let next = rest.dropFirst("account".count).first, next == "-" || next == " " {
            rest = rest.dropFirst("account".count + 1)
        }
        guard rest.count == 1, let character = rest.first, character.isLetter, character.isASCII else { return nil }
        return character.uppercased()
    }
}
