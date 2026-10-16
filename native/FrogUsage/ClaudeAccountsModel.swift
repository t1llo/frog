// Several Claude accounts: which there are on this Mac, and one reading store for each while
// Frog shows them.
import Foundation
import Combine

/// While Frog shows one Claude account, it only looks for others: folder names and whether files
/// exist, for the notice that offers to show them. Once it shows each, every account has a store
/// of its own, with its own request gate, so throttling of one account never slows another.
@MainActor
final class ClaudeAccountsModel: ObservableObject {
    static let noticeDismissedKey = "claudeAccountsNoticeDismissed"
    /// Folders added on the page, kept beside the labels and never exported.
    static let extraFoldersKey = ClaudeAccountLabels.defaultsKey + ".extraFolders"
    /// Each further account's store starts this much after the one before it.
    static let stagger: TimeInterval = 30

    @Published private(set) var accounts: [ClaudeAccount] = []
    /// By slot path.
    @Published private(set) var stores: [String: Store] = [:]
    /// Accounts found by the last detection. While the switch is off, folders are not opened, so
    /// this is the larger of the Claude app folders and the Claude Code profiles found.
    @Published private(set) var detectedCount = 0
    /// The folders the notice names, with whether they are the Claude app's.
    @Published private(set) var detectedFolders: (names: [String], app: Bool) = ([], true)
    @Published private(set) var enabled = false
    @Published private(set) var noticeDismissed: Bool
    /// Claude Code, when installed, as of the last detection.
    @Published private(set) var claudeExecutable: URL?
    /// A detection is under way, so an empty list means "still looking", not "none found".
    @Published private(set) var searching = false

    let home: URL
    let labels: ClaudeAccountLabels
    private let defaults: UserDefaults
    private let environment: [String: String]
    private let makeStore: @MainActor (ClaudeAccount, TimeInterval) -> Store
    private let discover: @Sendable (URL, [URL]) -> [ClaudeAccountSource]
    private let readOrganization: @Sendable (ClaudeAccountSource) -> String?
    private var running = false
    /// Detection runs once per launch on its own; Refresh runs it again.
    private var detected = false
    private var detection: Task<Void, Never>?
    private var generation = 0
    private var observations: [String: AnyCancellable] = [:]

    /// `discover` is handed the home folder and the Claude Code folders added on the page.
    init(defaults: UserDefaults, home: URL, environment: [String: String],
         makeStore: @escaping @MainActor (ClaudeAccount, TimeInterval) -> Store,
         discover: (@Sendable (URL, [URL]) -> [ClaudeAccountSource])? = nil,
         readOrganization: @escaping @Sendable (ClaudeAccountSource) -> String? = { ClaudeAccountsModel.organization(of: $0) }) {
        self.defaults = defaults
        self.home = home
        self.environment = environment
        self.makeStore = makeStore
        // Only the folder chosen with "Choose folder…" is read from it, and UserDefaults may be read from any thread.
        nonisolated(unsafe) let suite = defaults
        self.discover = discover ?? { [environment] home, extra in
            ClaudeAccountDiscovery.sources(home: home, extraFolders: extra, environment: environment, defaults: suite)
        }
        self.readOrganization = readOrganization
        labels = ClaudeAccountLabels(defaults: defaults)
        noticeDismissed = defaults.bool(forKey: Self.noticeDismissedKey)
    }

    // MARK: Lifecycle

    /// Mr. Usage is on: start the stores, and look for accounts once.
    func start() {
        guard !running else { return }; running = true
        for store in stores.values { store.start() }
        if !detected { detect() }
    }

    func stop() {
        running = false
        detection?.cancel(); detection = nil; generation += 1; searching = false
        for store in stores.values { store.stop() }
    }

    func tick() { for store in stores.values { store.tick() } }

    /// On: find the accounts, then give each a store, 30 s apart. Off: stop and drop them.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            if running { detect() }
        } else {
            detection?.cancel(); detection = nil; generation += 1; searching = false
            for store in stores.values { store.stop() }
            stores = [:]; observations = [:]; accounts = []
            // The count shown in the notice is made without opening files again.
            if running { detect() }
        }
    }

    /// In the background. While the switch is off only names and files' existence are looked at;
    /// while it is on, each folder's newest organization decides which folders are one account.
    func detect() {
        detection?.cancel(); generation += 1; searching = true
        let generation = generation, enabled = enabled, home = home, extras = extraFolders, environment = environment
        let discover = discover, readOrganization = readOrganization
        detection = Task {
            let found = try? await usageWork({ () -> Detection in
                let sources = Self.sources(discover(home, extras), adding: extras)
                let executable = ClaudeCodeCLI.executable(home: home, environment: environment)
                guard enabled else { return Detection(sources: sources, accounts: nil, executable: executable) }
                var apps: [ClaudeAccountMatching.App] = [], profiles: [ClaudeAccountMatching.Profile] = []
                for source in sources {
                    switch source {
                    case .app(let folder): apps.append(.init(folder: folder, organization: readOrganization(source)))
                    case .code(let folder, let file): profiles.append(.init(folder: folder, file: file, organization: readOrganization(source)))
                    }
                }
                return Detection(sources: sources, accounts: ClaudeAccountMatching.accounts(apps: apps, profiles: profiles),
                                 executable: executable)
            })
            guard !Task.isCancelled, generation == self.generation else { return }
            detection = nil; searching = false
            if let found { apply(found) }
        }
    }

    private struct Detection: @unchecked Sendable {
        let sources: [ClaudeAccountSource]
        let accounts: [ClaudeAccount]?
        let executable: URL?
    }

    private func apply(_ found: Detection) {
        detected = true
        if claudeExecutable != found.executable { claudeExecutable = found.executable }
        if let accounts = found.accounts {
            detectedCount = accounts.count
            let apps = accounts.compactMap(\.appFolder)
            detectedFolders = apps.isEmpty ? (accounts.map { URL(fileURLWithPath: $0.slotPath).lastPathComponent }, false)
                : (apps.map(\.lastPathComponent), true)
            update(accounts)
        } else {
            let apps = found.sources.filter { if case .app = $0 { true } else { false } }.map(\.folder.lastPathComponent)
            let profiles = found.sources.filter { if case .code = $0 { true } else { false } }.map(\.folder.lastPathComponent)
            detectedCount = max(apps.count, profiles.count)
            detectedFolders = apps.count >= profiles.count ? (apps, true) : (profiles, false)
        }
    }

    /// Keeps the store of an account whose folders and login are unchanged, so a detection does
    /// not start its readings over; makes one for each new or changed account.
    private func update(_ found: [ClaudeAccount]) {
        guard enabled else { return }
        var next: [String: Store] = [:]
        for (index, account) in found.enumerated() {
            if let store = stores[account.id], let current = store.account, Self.sameReading(current, account) {
                next[account.id] = store
                continue
            }
            stores[account.id]?.stop()
            let store = makeStore(account, Double(index) * Self.stagger)
            store.onOrganizationChange = { [weak self] in self?.detect() }
            observations[account.id] = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            next[account.id] = store
            if running { store.start() }
        }
        for (id, store) in stores where next[id] == nil {
            store.stop(); observations[id] = nil
        }
        stores = next
        if accounts != found { accounts = found }
    }

    private static func sameReading(_ a: ClaudeAccount, _ b: ClaudeAccount) -> Bool {
        a.appFolder == b.appFolder && a.codeFolder == b.codeFolder && a.profileFile == b.profileFile && a.pollingKey == b.pollingKey
    }

    // MARK: Labels and the notice

    func label(_ account: ClaudeAccount) -> String { labels.label(for: account) }

    func isIncluded(_ account: ClaudeAccount) -> Bool { labels.isIncluded(account) }

    func rename(_ slot: String, to label: String) {
        guard let account = accounts.first(where: { $0.id == slot }) else { return }
        objectWillChange.send()
        labels.rename(account, to: label, among: accounts)
    }

    func setIncluded(_ slot: String, _ on: Bool) {
        guard let account = accounts.first(where: { $0.id == slot }) else { return }
        objectWillChange.send()
        labels.setIncluded(on, for: account)
    }

    var noticeVisible: Bool { !enabled && !noticeDismissed && detectedCount >= 2 }

    func dismissNotice() {
        defaults.set(true, forKey: Self.noticeDismissedKey)
        noticeDismissed = true
    }

    // MARK: Folders

    var extraFolders: [URL] {
        (defaults.stringArray(forKey: Self.extraFoldersKey) ?? []).map { URL(fileURLWithPath: $0) }
    }

    /// A Claude app data folder or a Claude Code folder somewhere the search does not look.
    func addFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        var paths = defaults.stringArray(forKey: Self.extraFoldersKey) ?? []
        guard !paths.contains(path) else { return }
        paths.append(path)
        defaults.set(paths, forKey: Self.extraFoldersKey)
        detect()
    }

    /// An added folder holding the Claude app's history is an app folder; the others are looked
    /// at as Claude Code folders by the discovery itself.
    nonisolated static func sources(_ found: [ClaudeAccountSource], adding extras: [URL],
                                    fileManager: FileManager = .default) -> [ClaudeAccountSource] {
        var seen = Set(found.map { $0.folder.resolvingSymlinksInPath().path })
        let apps = extras.filter { folder in
            fileManager.fileExists(atPath: ClaudeDesktopUsage.historyURL(folder: folder).path)
                || fileManager.fileExists(atPath: folder.appendingPathComponent(ClaudeAccountDiscovery.appMarkers.sessions).path)
        }.filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }.map(ClaudeAccountSource.app)
        let firstProfile = found.firstIndex { if case .code = $0 { true } else { false } } ?? found.endIndex
        var result = found
        result.insert(contentsOf: apps, at: firstProfile)
        return result
    }

    // MARK: Live readings

    /// An account known only from the Claude app, whose app has saved nothing recent, while
    /// Claude Code is installed to sign in with.
    func needsLiveSetup(_ account: ClaudeAccount, now: Date) -> Bool {
        guard account.codeFolder == nil, account.appFolder != nil, claudeExecutable != nil else { return false }
        guard let at = stores[account.id]?.desktop?.observedAt else { return true }
        return now.timeIntervalSince(at) > ClaudeDesktopUsage.freshness
    }

    /// Claude Code's sign-in for a new profile named after the app folder, which Claude Code
    /// creates when signing in. The next detection links it to the folder by organization.
    func liveSetupCommand(for slot: String) -> String? {
        guard let account = accounts.first(where: { $0.id == slot }), account.codeFolder == nil,
              let folder = account.appFolder, let executable = claudeExecutable else { return nil }
        return ClaudeCodeCLI.signInCommand(executable: executable, directory: Self.liveSetupFolder(for: folder, home: home))
    }

    /// `Claude-Account-B` → `~/.claude-account-b`, `Work` → `~/.claude-work`.
    nonisolated static func liveSetupFolder(for appFolder: URL, home: URL) -> URL {
        let name = appFolder.lastPathComponent.lowercased().replacingOccurrences(of: " ", with: "-")
        return home.appendingPathComponent(name.hasPrefix("claude") ? "." + name : ".claude-" + name)
    }

    // MARK: Reading organizations

    /// The organization a folder is signed in to now: the newest sample of a Claude app folder's
    /// history, or a Claude Code profile's `oauthAccount`. Blocking, read-only; held in memory only.
    nonisolated static func organization(of source: ClaudeAccountSource) -> String? {
        switch source {
        case .app(let folder):
            let url = ClaudeDesktopUsage.historyURL(folder: folder)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= ClaudeDesktopUsage.maximumSize, let data = try? Data(contentsOf: url) else { return nil }
            return ClaudeDesktopUsage.reading(from: data)?.organization
        case .code(_, let profile):
            return claudeProfile(at: profile)["organizationUuid"] as? String
        }
    }
}
