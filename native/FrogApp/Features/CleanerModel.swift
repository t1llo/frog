import Darwin
import Foundation
import FrogCore

/// Everything the App cleaner reads and changes, so the whole page runs against a fixture folder and fakes in tests.
struct CleanerDependencies {
    var roots: CleanerRoots
    var safety: CleanerSafety
    var inspector: AppBundleInspector
    var trash: any CleanerTrash
    var system: any CleanerSystemControl
    var store: CleanerStore
    /// Every app bundle the catalogue knows, system ones included (they still claim names and IDs).
    var applications: @MainActor () async -> [URL]
    var displayName: @Sendable (URL) -> String
    var ownBundleID: String
    // slot: cleaner-leftovers
    // slot: cleaner-junk
    // slot: cleaner-assist
    // slot: cleaner-disk
    // slot: cleaner-startup

    /// Only builds values: nothing is read until the page asks.
    @MainActor static func live(dataDirectory: URL, protectedPaths: [URL]) -> CleanerDependencies {
        let roots = CleanerRoots()
        var dependencies = CleanerDependencies(
            roots: roots, safety: CleanerSafety(roots: roots, protectedPaths: protectedPaths),
            inspector: AppBundleInspector(signatures: SecurityCodeSignatureReader()),
            trash: SystemCleanerTrash(), system: SystemCleanerControl(),
            store: CleanerStore(directory: dataDirectory.appendingPathComponent("Cleaner", isDirectory: true)),
            applications: {
                await ApplicationCatalogStore.shared.load().compactMap { $0.action?.applicationPath }
                    .map { URL(fileURLWithPath: $0, isDirectory: true) }
            },
            displayName: { FileManager.default.displayName(atPath: $0.path) },
            ownBundleID: "xyz.beffa.frog")
        // `swift run` has no Info.plist; a bundled Frog names itself.
        if let own = Bundle.main.bundleIdentifier { dependencies.ownBundleID = own }
        // slot: cleaner-leftovers
        // slot: cleaner-junk
        // slot: cleaner-assist
        // slot: cleaner-disk
        // slot: cleaner-startup
        return dependencies
    }
}

struct CleanerAppRow: Identifiable, Equatable {
    var identity: AppIdentity
    var size: CleanerSize?
    var id: String { identity.path }
}

enum CleanerGroupKind: String, CaseIterable, Identifiable {
    case application, sure, likely, possible, shared, suggested
    var id: String { rawValue }

    var title: String {
        switch self {
        case .application: "App"
        case .sure: "Sure matches"
        case .likely: "Likely matches"
        case .possible: "Possible matches"
        case .shared: "Used by other apps"
        case .suggested: "Suggested by AI"
        }
    }

    /// The group an item is listed in; nil for a possible match while those are hidden.
    static func of(_ item: CleanerItem, showPossible: Bool) -> CleanerGroupKind? {
        if item.kind == .application { return .application }
        if item.suggested { return .suggested }
        if item.confidence == .possible, !showPossible { return nil }
        if !item.sharedWith.isEmpty { return .shared }
        switch item.confidence {
        case .certain: return .sure
        case .likely: return .likely
        case .possible: return .possible
        }
    }
}

struct CleanerGroup: Identifiable, Equatable {
    var kind: CleanerGroupKind
    var items: [CleanerItem]
    var id: CleanerGroupKind { kind }
}

/// One app's bundle and leftovers, with what the user ticked.
struct CleanerReview: Equatable {
    var app: AppIdentity
    /// The bundle is already gone; only its leftovers are listed.
    var removedApp = false
    var items: [CleanerItem]
    var selected: Set<String>
    var sizes: [String: CleanerSize]
    var fullDiskAccess: Bool?

    /// application, sure (certain), likely, possible (only when shown), shared, suggested; empty groups dropped.
    func groups(showPossible: Bool) -> [CleanerGroup] {
        var found: [CleanerGroupKind: [CleanerItem]] = [:]
        for item in items {
            guard let kind = CleanerGroupKind.of(item, showPossible: showPossible) else { continue }
            found[kind, default: []].append(item)
        }
        return CleanerGroupKind.allCases.compactMap { kind in found[kind].map { CleanerGroup(kind: kind, items: $0) } }
    }

    /// The ticked items without those inside another ticked folder: they move with it (`RemovalPlan`), so they
    /// are neither counted nor measured twice.
    var tickedItems: [CleanerItem] {
        let chosen = items.filter { selected.contains($0.id) }
        let ids = chosen.map(\.id)
        return chosen.filter { item in !ids.contains { item.id.hasPrefix($0 + "/") } }
    }

    var selectedBytes: Int64 { tickedItems.reduce(0) { $0 + (sizes[$1.id]?.bytes ?? $1.size ?? 0) } }

    var selectedCount: Int { tickedItems.count }

    /// A ticked item has no size yet or only part of one, so `selectedBytes` is a lower bound.
    var selectedSizeIncomplete: Bool {
        tickedItems.contains { item in
            if let size = sizes[item.id] { return !size.complete }
            return item.size == nil
        }
    }

    /// "7 items · 4.9 MB", "7 items · at least 4.9 MB" while a size is unknown, "1 item" while none is known,
    /// or "Nothing ticked".
    func selectionSummary(formatBytes: (Int64) -> String = CleanerFormat.bytes) -> String {
        let ticked = tickedItems
        guard !ticked.isEmpty else { return "Nothing ticked" }
        let items = "\(ticked.count) \(ticked.count == 1 ? "item" : "items")"
        guard ticked.contains(where: { sizes[$0.id] != nil || $0.size != nil }) else { return items }
        let bytes = formatBytes(selectedBytes)
        return items + " · " + (selectedSizeIncomplete ? "at least \(bytes)" : bytes)
    }

    /// Containers are measured only with Full Disk Access: reading them could ask the user about other apps' data.
    func measures(_ item: CleanerItem) -> Bool {
        fullDiskAccess == true || !(item.needsFullDiskAccess || [.container, .groupContainer].contains(item.kind))
    }

    /// Some items can be measured or moved only with Full Disk Access, which Frog does not have.
    var needsFullDiskAccess: Bool { fullDiskAccess != true && items.contains { !measures($0) } }
}

/// What the page says once a removal has finished.
struct RemovalSummary: Equatable {
    /// "Moved 12 items to the Trash · 1.4 GB", "… · at least 1.4 GB" when a size is unknown, "Moved 1 item to the
    /// Trash" when none is known, or "Nothing was moved."
    let title: String
    /// "Could not move 1 item", "Could not move 2 items", or nil when nothing failed.
    let failureTitle: String?
    /// The outcome's notes, then a reminder that the space is freed only when the Trash is emptied.
    let notes: [String]

    static let emptyTheTrash = "Empty the Trash to free the space."

    init(_ outcome: RemovalOutcome, formatBytes: (Int64) -> String = CleanerFormat.bytes) {
        let moved = outcome.moved.count
        let known = outcome.moved.compactMap(\.bytes)
        let size = known.isEmpty ? ""
            : " · " + (known.count < moved ? "at least " : "") + formatBytes(known.reduce(0, +))
        title = moved == 0 ? "Nothing was moved." : "Moved \(moved) \(moved == 1 ? "item" : "items") to the Trash" + size
        let failed = outcome.failures.count
        failureTitle = failed == 0 ? nil : "Could not move \(failed) \(failed == 1 ? "item" : "items")"
        notes = outcome.notes + (moved > 0 ? [Self.emptyTheTrash] : [])
    }

    enum SettingsLink: Equatable {
        case automation, fullDiskAccess
        var title: String { self == .automation ? "Open Automation Settings" : "Open Full Disk Access Settings" }
        var url: URL {
            URL(string: "x-apple.systempreferences:com.apple.preference.security?"
                + (self == .automation ? "Privacy_Automation" : "Privacy_AllFiles"))!
        }
    }

    /// The System Settings pane that lets the next attempt succeed, for the failures that name one.
    static func settingsLink(for message: String) -> SettingsLink? {
        switch message {
        case CleanerRemover.automationDenied: .automation
        case CleanerRemover.needsFullDiskAccess: .fullDiskAccess
        default: nil
        }
    }
}

/// What the page says once items were put back from the Trash.
struct PutBackSummary: Equatable {
    /// "Put back 12 items.", "Put back 1 item." or "Nothing was put back."
    let title: String
    let failures: [RemovalFailure]
    /// How many items this Put Back moved out of the Trash.
    let restored: Int

    init(before: RemovalRecord, after: RemovalRecord, failures: [RemovalFailure]) {
        let earlier = Set(before.entries.filter(\.restored).map(\.original))
        restored = after.entries.filter { $0.restored && !earlier.contains($0.original) }.count
        title = restored == 0 ? "Nothing was put back." : "Put back \(restored) \(restored == 1 ? "item" : "items")."
        self.failures = failures
    }
}

/// What a tab asks to move to the Trash; the same confirmation sheet and remover serve every tab.
struct RemovalRequest: Equatable {
    var app: AppIdentity?
    var items: [CleanerItem]
    var selected: Set<String>
    var purpose: CleanerSafety.Purpose
    /// The record's title: the app's name or "12 items".
    var title: String
    var sizes: [String: CleanerSize]
}

struct PendingRemoval: Identifiable {
    let id = UUID()
    var request: RemovalRequest
    var plan: RemovalPlan
    var prompt: RemovalPrompt
    /// Runs once the removal finished, also when it was cancelled, so a tab can update its own list.
    var onFinish: @MainActor (RemovalOutcome) -> Void = { _ in }
}

struct ForceQuitQuestion: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
}

enum CleanerAppSort: String, CaseIterable {
    case name, size
    var title: String { self == .name ? "Name" : "Size" }
}

/// The App cleaner's page: the app list, the review of one app, the confirmation, the force-quit question,
/// the removal and its outcome. Later tabs reuse `prepare(_:)` for their own confirmation.
@MainActor
final class CleanerModel: ObservableObject {
    enum Phase: Equatable { case idle, scanning, reviewing, removing(done: Int, total: Int) }

    @Published private(set) var apps: [CleanerAppRow] = []
    @Published private(set) var loadingApps = false
    @Published var search = ""
    @Published var sort: CleanerAppSort = .name
    @Published private(set) var review: CleanerReview?
    @Published private(set) var phase: Phase = .idle
    /// The app whose files a scan is looking for; nil when no scan runs.
    @Published private(set) var scanningApp: AppIdentity?
    @Published var pending: PendingRemoval?
    @Published private(set) var forceQuit: ForceQuitQuestion?
    @Published private(set) var outcome: RemovalOutcome?
    @Published var issue: String?
    @Published private(set) var fullDiskAccess: Bool?
    var showPossibleMatches = false {
        didSet { if !showPossibleMatches { untickHidden() } }
    }
    /// Set for reviews of removed apps; nil otherwise.
    var isInstalledAgain: (@MainActor (AppIdentity) -> Bool)?

    let dependencies: CleanerDependencies

    nonisolated static let notAnApp = "Drop an app from Finder."
    nonisolated static let unreadable = "Frog cannot read this app."
    nonisolated static let appleApp = "Frog leaves Apple's apps alone. Remove them in Finder."
    nonisolated static let frogItself = "Frog cannot remove itself. Quit Frog, then move it to the Trash in Finder."
    nonisolated static let outsideApplications = "Frog removes apps from the Applications folders. Move this one to the Trash in Finder."
    nonisolated static let nothingTicked = "Tick at least one item."
    nonisolated static func installedAgain(_ name: String) -> String { "\(name) is installed again." }
    nonisolated static func didNotQuit(_ name: String) -> String { "\(name) did not quit. Force quit it?" }
    nonisolated static func unsavedChanges(_ name: String) -> String { "Unsaved changes in \(name) may be lost." }

    /// Every identity the last load inspected, Apple's and Frog's included.
    private var identities: [AppIdentity] = []
    private var identitiesLoaded = false
    private var identityCache: [String: CachedIdentity] = [:]
    /// Bundle sizes for this session, by resolved path.
    private var appSizes: [String: CleanerSize] = [:]
    private var loadTask: Task<Void, Never>?
    private var appSizeTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var sizeTask: Task<Void, Never>?
    private var forceQuitAnswer: CheckedContinuation<Bool, Never>?
    /// Changes with `stop`, so work that started before never publishes after it.
    private var generation = 0

    init(dependencies: CleanerDependencies) { self.dependencies = dependencies }

    // MARK: - Tabs

    @Published var tab: CleanerTab = .apps
    // One lazy sub-model per part, each below its own slot.
    // slot: cleaner-leftovers
    // slot: cleaner-junk
    // slot: cleaner-assist
    // slot: cleaner-disk
    // slot: cleaner-startup

    /// Called after every saved configuration. Keeps showPossibleMatches current, stops sub-models whose
    /// switch is off (each part adds its line below its slot), and falls back to .apps when the selected
    /// tab disappears.
    func apply(_ preferences: Preferences) {
        showPossibleMatches = preferences.featureEnabled(.cleaner) && preferences.cleanerSettings.possibleMatches
        // slot: cleaner-leftovers
        // slot: cleaner-junk
        // slot: cleaner-assist
        // slot: cleaner-disk
        // slot: cleaner-startup
        if !CleanerTab.available(preferences).contains(tab) { tab = .apps }
    }

    private var isRemoving: Bool {
        if case .removing = phase { return true }
        return false
    }

    // MARK: - App list

    var visibleApps: [CleanerAppRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty ? apps : apps.filter { row in
            let identity = row.identity
            return [identity.name, identity.bundleName, identity.displayName, identity.bundleID].compactMap { $0 }
                .contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        return matching.sorted { first, second in
            if sort == .size, first.size?.bytes != second.size?.bytes {
                guard let one = first.size?.bytes else { return false }
                guard let other = second.size?.bytes else { return true }
                return one > other
            }
            return first.identity.name.localizedStandardCompare(second.identity.name) == .orderedAscending
        }
    }

    /// Callers that arrive during a load share it.
    func loadApps() async {
        if let loadTask { return await loadTask.value }
        loadingApps = true
        let task = Task { await reloadApps() }
        loadTask = task
        await task.value
    }

    /// Every identity `loadApps` inspected, system apps included (they still claim IDs and names),
    /// loading them first when needed. Leftovers, the removed-app notice and the AI assist use it.
    func allIdentities() async -> [AppIdentity] {
        if !identitiesLoaded { await loadApps() }
        return identities
    }

    /// Measures the listed bundles once per session and publishes them together.
    func measureAppSizes() async {
        if let appSizeTask { return await appSizeTask.value }
        let urls = apps.filter { appSizes[key($0.identity.path)] == nil }.map(\.identity.url)
        guard !urls.isEmpty else { return }
        let task = Task {
            guard let sizes = try? await Self.offMain(.utility, { CleanerSizer().measure(urls) }),
                  !Task.isCancelled else { return }
            for url in urls { appSizes[key(url.path)] = sizes[url.path] }
            apps = apps.map { row in
                var row = row
                row.size = appSizes[key(row.identity.path)]
                return row
            }
            appSizeTask = nil
        }
        appSizeTask = task
        await task.value
    }

    private func reloadApps() async {
        let urls = await dependencies.applications()
        guard !Task.isCancelled else { return }
        let context = ListContext(roots: dependencies.roots, safety: dependencies.safety, inspector: dependencies.inspector,
                                  displayName: dependencies.displayName, ownBundleID: dependencies.ownBundleID)
        let cache = identityCache
        guard let found = try? await Self.offMain(.utility, { try Self.inspect(urls, context: context, cache: cache) }),
              !Task.isCancelled else { return }
        identityCache = found.cache
        identities = found.identities
        identitiesLoaded = true
        apps = found.listed.map { CleanerAppRow(identity: $0, size: appSizes[key($0.path)]) }
        loadingApps = false
        loadTask = nil
    }

    // MARK: - Review

    /// For list clicks, drops and the command bar. Refused apps leave the open review as it is.
    func open(_ url: URL) async {
        await runScan { [weak self] in await self?.checkAndScan(url) }
    }

    /// Opens the review of an app Frog has already identified, such as one whose bundle is gone.
    func openReview(of app: AppIdentity, removedApp: Bool) async {
        await runScan { [weak self] in await self?.scan(app, removedApp: removedApp) }
    }

    /// The sentence that keeps an app out of the uninstaller, or nil when Frog may remove it.
    func refusal(for app: AppIdentity) -> String? {
        Self.refusal(for: app, roots: dependencies.roots, safety: dependencies.safety, ownBundleID: dependencies.ownBundleID)
    }

    func closeReview() {
        scanTask?.cancel(); scanTask = nil
        sizeTask?.cancel(); sizeTask = nil
        review = nil
        scanningApp = nil
        guard !isRemoving else { return }
        pending = nil
        phase = .idle
    }

    /// Ticking is the user's choice, so any item may be ticked here, shared and suggested ones too.
    func toggle(_ id: String) {
        guard var review, review.items.contains(where: { $0.id == id }) else { return }
        if review.selected.remove(id) == nil { review.selected.insert(id) }
        self.review = review
    }

    func setGroup(_ kind: CleanerGroupKind, selected: Bool) {
        guard var review else { return }
        let ids = review.groups(showPossible: showPossibleMatches).first { $0.kind == kind }?.items.map(\.id) ?? []
        if selected { review.selected.formUnion(ids) } else { review.selected.subtract(ids) }
        self.review = review
    }

    func refreshFullDiskAccess() async {
        let generation = self.generation
        let granted = await dependencies.system.hasFullDiskAccess()
        guard generation == self.generation else { return }
        fullDiskAccess = granted
        review?.fullDiskAccess = granted
    }

    /// For tests: waits until the open review's sizes are published.
    func waitForSizes() async { await sizeTask?.value }

    private func runScan(_ work: @escaping @MainActor () async -> Void) async {
        guard !isRemoving else { return }
        scanTask?.cancel()
        let task = Task { await work() }
        scanTask = task
        await task.value
        if scanTask == task { scanTask = nil }
    }

    private func checkAndScan(_ url: URL) async {
        issue = nil
        let url = url.standardizedFileURL
        var isFolder: ObjCBool = false
        guard url.pathExtension.lowercased() == "app", FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder),
              isFolder.boolValue else {
            issue = Self.notAnApp
            return
        }
        let inspector = dependencies.inspector, displayName = dependencies.displayName
        let identity = try? await Self.offMain(.userInitiated) { try inspector.identity(of: url, displayName: displayName(url)) }
        guard !Task.isCancelled else { return }
        guard let identity else {
            issue = Self.unreadable
            return
        }
        if let refusal = refusal(for: identity) {
            issue = refusal
            return
        }
        await scan(identity, removedApp: false)
    }

    private func scan(_ app: AppIdentity, removedApp: Bool) async {
        sizeTask?.cancel(); sizeTask = nil
        review = nil; pending = nil; outcome = nil; issue = nil
        phase = .scanning
        scanningApp = app
        defer { if scanningApp == app { scanningApp = nil } }
        let granted = await dependencies.system.hasFullDiskAccess()
        guard !Task.isCancelled else { return }
        fullDiskAccess = granted
        let path = key(app.path)
        let others = await allIdentities().filter { key($0.path) != path }
        guard !Task.isCancelled else { return }

        let scanner = LeftoverScanner(roots: dependencies.roots, safety: dependencies.safety, hasFullDiskAccess: granted ?? false)
        var items: [CleanerItem]
        do {
            items = try await Self.offMain(.userInitiated) { try scanner.scan(app: app, otherApps: others) }
        } catch {
            guard !Task.isCancelled else { return }
            phase = .idle
            issue = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        guard !Task.isCancelled else { return }
        if removedApp { items.removeAll { $0.kind == .application } }
        // Group containers hold data other apps of the developer may share, so Frog never ticks them.
        let selected = items.filter { $0.kind == .application || ($0.isPreselected && $0.kind != .groupContainer) }
        review = CleanerReview(app: app, removedApp: removedApp, items: items, selected: Set(selected.map(\.id)),
                               sizes: [:], fullDiskAccess: granted)
        phase = .reviewing
        measureReviewSizes(items)
    }

    /// Containers are not measured without Full Disk Access (`CleanerReview.measures`).
    private func measureReviewSizes(_ items: [CleanerItem]) {
        guard let shown = review else { return }
        let app = shown.app
        let urls = items.filter(shown.measures).map(\.url)
        guard !urls.isEmpty else { return }
        sizeTask = Task {
            guard let sizes = try? await Self.offMain(.utility, { CleanerSizer().measure(urls) }),
                  !Task.isCancelled, review?.app == app else { return }
            review?.sizes = sizes
        }
    }

    private func untickHidden() {
        guard var review else { return }
        let shown = Set(review.groups(showPossible: showPossibleMatches).flatMap(\.items).map(\.id))
        let kept = review.selected.intersection(shown)
        guard kept != review.selected else { return }
        review.selected = kept
        self.review = review
    }

    // MARK: - Removal

    func prepareRemoval() async {
        guard let review else { return }
        if review.removedApp, isInstalledAgain?(review.app) == true {
            issue = Self.installedAgain(review.app.name)
            closeReview()
            return
        }
        await prepare(RemovalRequest(app: review.app, items: review.items, selected: review.selected, purpose: .leftover,
                                     title: review.app.name, sizes: review.sizes))
    }

    /// Every tab confirms through here; `onFinish` lets the tab update its list after the removal.
    func prepare(_ request: RemovalRequest, onFinish: @escaping @MainActor (RemovalOutcome) -> Void = { _ in }) async {
        guard !isRemoving else { return }
        issue = nil
        // The record and the outcome count bytes from the items themselves.
        let items = request.items.map { item in
            var item = item
            if let size = request.sizes[item.id] { item.size = size.bytes }
            return item
        }
        let plan = RemovalPlan.make(app: request.app, items: items, selected: request.selected, purpose: request.purpose,
                                    safety: dependencies.safety, sizes: request.sizes)
        guard !plan.isEmpty else {
            issue = plan.refused.first?.reason ?? Self.nothingTicked
            return
        }
        var appIsRunning = false, helpers = 0
        let generation = self.generation
        if let app = request.app, !plan.quitBundleIDs.isEmpty {
            let running = await dependencies.system.running(bundleIDs: Set(plan.quitBundleIDs),
                                                            inside: plan.removesApp ? app.path : nil)
            guard generation == self.generation, !isRemoving else { return }
            let main = running.filter { $0.bundleID == app.bundleID || $0.bundlePath.map(key) == key(app.path) }
            appIsRunning = !main.isEmpty
            helpers = running.count - main.count
        }
        // Only read, never asked: the sheet says whether macOS will ask, or that Finder will refuse.
        let automation = plan.finderCount > 0 ? await dependencies.trash.finderAutomation() : nil
        guard generation == self.generation, !isRemoving else { return }
        pending = PendingRemoval(request: request, plan: plan,
                                 prompt: RemovalPrompt(plan: plan, appIsRunning: appIsRunning, runningHelpers: helpers,
                                                       finderAutomation: automation),
                                 onFinish: onFinish)
    }

    func confirmRemoval() async {
        guard let pending, !isRemoving else { return }
        let generation = self.generation, app = pending.request.app
        phase = .removing(done: 0, total: pending.plan.removals.count)
        let result = await makeRemover().perform(pending.plan, title: pending.request.title, confirmForceQuit: { [weak self] running in
            await self?.askForceQuit(running, app: app, generation: generation) ?? false
        }, progress: { [weak self] done, total in
            Task { @MainActor in self?.progressed(done: done, total: total, generation: generation) }
        })
        guard generation == self.generation else { return }
        finish(pending, result)
        pending.onFinish(result)
    }

    func answerForceQuit(_ forceQuit: Bool) {
        self.forceQuit = nil
        let answer = forceQuitAnswer
        forceQuitAnswer = nil
        answer?.resume(returning: forceQuit)
    }

    /// Only before anything ran; a removal under way finishes.
    func cancelRemoval() {
        guard !isRemoving else { return }
        pending = nil
    }

    func dismissOutcome() { outcome = nil }

    private func askForceQuit(_ running: [RunningAppInfo], app: AppIdentity?, generation: Int) async -> Bool {
        guard generation == self.generation, forceQuitAnswer == nil else { return false }
        let name = app?.name ?? running.first?.name ?? ""
        return await withCheckedContinuation { continuation in
            forceQuitAnswer = continuation
            forceQuit = ForceQuitQuestion(title: Self.didNotQuit(name), message: Self.unsavedChanges(name))
        }
    }

    private func progressed(done: Int, total: Int, generation: Int) {
        // Progress hops here in tasks of its own, so a late or out-of-order one never moves the bar back.
        guard generation == self.generation, case .removing(let shown, _) = phase, done > shown else { return }
        phase = .removing(done: done, total: total)
    }

    private func finish(_ pending: PendingRemoval, _ result: RemovalOutcome) {
        outcome = result
        self.pending = nil
        phase = .idle
        let moved = result.moved.map(\.original)
        guard !moved.isEmpty else { return }
        func isMoved(_ path: String) -> Bool { moved.contains { path == $0 || path.hasPrefix($0 + "/") } }

        var appMoved = false
        if let app = pending.request.app,
           pending.plan.removals.contains(where: { $0.item.kind == .application && isMoved($0.item.id) }) {
            let path = key(app.path)
            apps.removeAll { key($0.identity.path) == path }
            identities.removeAll { key($0.path) == path }
            identityCache[path] = nil
            appMoved = review.map { key($0.app.path) == path } ?? false
        }
        // Whatever moved leaves the open review, items inside moved folders too.
        guard var review else { return }
        review.items.removeAll { isMoved($0.id) }
        review.selected = review.selected.filter { !isMoved($0) }
        if appMoved {
            // The app is in the Trash. Its items that did not move stay listed and ticked, so the user can try
            // again, for example after allowing Full Disk Access; with none of them left, the list comes back.
            let failed = Set(result.failures.map(\.path))
            guard review.items.contains(where: { failed.contains($0.id) }) else {
                closeReview()
                return
            }
            review.removedApp = true
        }
        self.review = review
    }

    // MARK: - Recently moved

    /// What Frog moved in the last 30 days, newest first; read when the list opens.
    @Published private(set) var records: [RemovalRecord] = []
    /// By record: the original paths of items that left the Trash since they moved (it was emptied, or they
    /// were dragged out), so the list does not offer to put them back.
    @Published private(set) var missingFromTrash: [UUID: Set<String>] = [:]
    @Published var showsRecent = false
    @Published private(set) var putBackSummary: PutBackSummary?
    /// The record whose items are moving back; nil otherwise.
    @Published private(set) var puttingBack: UUID?

    nonisolated static let recordsUnreadable = "Frog could not read the list of moved items."
    nonisolated static let recordsUnchanged = "Frog could not change the list of moved items."

    func loadRecords() {
        do { records = try dependencies.store.records() } catch {
            issue = Self.recordsUnreadable
            return
        }
        let remover = makeRemover()
        missingFromTrash = records.reduce(into: [:]) { missing, record in
            let gone = record.entries.filter { !$0.restored && !remover.isInTrash($0) }.map(\.original)
            if !gone.isEmpty { missing[record.id] = Set(gone) }
        }
    }

    /// The rows of Recently moved, newest first.
    var recentRows: [RecentlyMovedRow] { records.map { RecentlyMovedRow($0, missing: missingFromTrash[$0.id] ?? []) } }

    /// Moves the record's own items back that Frog may restore; the rest are explained in the summary.
    func putBack(_ id: UUID) async {
        guard puttingBack == nil else { return }
        // A removal's outcome may name a record the list was not read for yet, or one that could not be saved.
        let stored = records.first { $0.id == id } ?? (try? dependencies.store.records())?.first { $0.id == id }
        guard let record = stored ?? outcome?.record.flatMap({ $0.id == id ? $0 : nil }) else { return }
        let generation = self.generation
        puttingBack = id
        let result = await makeRemover().putBack(record)
        guard generation == self.generation else { return }
        puttingBack = nil
        putBackSummary = PutBackSummary(before: record, after: result.record, failures: result.failures)
        loadRecords()
        let earlier = Set(record.entries.filter(\.restored).map(\.original))
        let returned = result.record.entries.filter { $0.restored && !earlier.contains($0.original) }
        // An open review no longer lists what is back; the list shows the app again, and opening it reads anew.
        if !returned.isEmpty, review != nil, !isRemoving { closeReview() }
        // An app that came back belongs in the list again.
        if identitiesLoaded, returned.contains(where: { $0.original.lowercased().hasSuffix(".app") }) { await loadApps() }
    }

    /// Forgets the record only; whatever is in the Trash stays there.
    func forget(_ id: UUID) {
        do { try dependencies.store.delete(id: id) } catch {
            issue = Self.recordsUnchanged
            return
        }
        records.removeAll { $0.id == id }
        missingFromTrash[id] = nil
    }

    func dismissPutBack() { putBackSummary = nil }

    // MARK: - Stop

    /// Called when the feature is turned off: nothing keeps running and nothing stays in memory.
    func stop() {
        // slot: cleaner-leftovers
        // slot: cleaner-junk
        // slot: cleaner-assist
        // slot: cleaner-disk
        // slot: cleaner-startup
        generation += 1
        for task in [loadTask, appSizeTask, scanTask, sizeTask] { task?.cancel() }
        loadTask = nil; appSizeTask = nil; scanTask = nil; sizeTask = nil
        answerForceQuit(false)
        review = nil; pending = nil; outcome = nil; issue = nil; scanningApp = nil
        apps = []; identities = []; identitiesLoaded = false; identityCache = [:]; appSizes = [:]
        loadingApps = false
        fullDiskAccess = nil
        records = []; missingFromTrash = [:]; showsRecent = false; putBackSummary = nil; puttingBack = nil
        phase = .idle
    }

    // MARK: - Helpers

    private func makeRemover() -> CleanerRemover {
        CleanerRemover(trash: dependencies.trash, system: dependencies.system, store: dependencies.store,
                       safety: dependencies.safety)
    }

    /// Paths compare in the roots' resolved spelling (`/private/var`, not `/var`).
    private func key(_ path: String) -> String { dependencies.roots.resolved(URL(fileURLWithPath: path)).path }

    private struct CachedIdentity: Sendable {
        var stamp: Double
        var identity: AppIdentity
    }

    private struct ListContext: Sendable {
        var roots: CleanerRoots
        var safety: CleanerSafety
        var inspector: AppBundleInspector
        var displayName: @Sendable (URL) -> String
        var ownBundleID: String
    }

    nonisolated private static func refusal(for app: AppIdentity, roots: CleanerRoots, safety: CleanerSafety,
                                            ownBundleID: String) -> String? {
        if app.isAppleApp { return appleApp }
        if app.bundleID.caseInsensitiveCompare(ownBundleID) == .orderedSame { return frogItself }
        let path = roots.resolved(app.url).path
        guard roots.applicationFolders.contains(where: { path.hasPrefix($0.path + "/") }) else { return outsideApplications }
        return safety.refusal(for: app.url, purpose: .application)
    }

    /// Inspects each bundle once per change of its Info.plist; unreadable bundles are left out.
    nonisolated private static func inspect(_ urls: [URL], context: ListContext, cache: [String: CachedIdentity]) throws
        -> (identities: [AppIdentity], listed: [AppIdentity], cache: [String: CachedIdentity]) {
        var identities: [AppIdentity] = [], listed: [AppIdentity] = []
        var fresh: [String: CachedIdentity] = [:]
        for url in urls {
            try Task.checkCancellation()
            let url = url.standardizedFileURL
            let path = context.roots.resolved(url).path
            guard fresh[path] == nil, let stamp = infoStamp(url) else { continue }
            let identity: AppIdentity
            if let cached = cache[path], cached.stamp == stamp {
                identity = cached.identity
            } else {
                guard let inspected = try? context.inspector.identity(of: url, displayName: context.displayName(url)) else { continue }
                identity = inspected
            }
            fresh[path] = CachedIdentity(stamp: stamp, identity: identity)
            identities.append(identity)
            if refusal(for: identity, roots: context.roots, safety: context.safety, ownBundleID: context.ownBundleID) == nil {
                listed.append(identity)
            }
        }
        return (identities, listed, fresh)
    }

    /// The Info.plist's modification time, or nil when it is missing.
    nonisolated private static func infoStamp(_ bundle: URL) -> Double? {
        var info = stat()
        guard lstat(bundle.appendingPathComponent("Contents/Info.plist").path, &info) == 0 else { return nil }
        return Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
    }

    /// Runs blocking disk work off the main actor and cancels it with the caller.
    nonisolated static func offMain<T: Sendable>(_ priority: TaskPriority,
                                                 _ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: priority) { try work() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
