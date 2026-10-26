import AppKit
import Combine
import FrogCore
@preconcurrency import UserNotifications
import WebKit

/// A line a plugin's page logged, or Frog logged about it.
struct PluginLogLine: Sendable {
    let date: Date
    let level: String
    let text: String
}

/// An installed plugin as the Plugins page lists it.
struct PluginItem: Identifiable, Equatable {
    let record: PluginRecord
    /// Nil when the installed files no longer read; `problem` says why.
    let manifest: PluginManifest?
    let grant: PluginGrant?
    let problem: String?
    var id: String { record.id }
    var name: String { manifest?.name ?? record.id }
    var symbol: String { manifest?.displaySymbol ?? PluginManifest.defaultSymbol }
    /// It asks for something the user has not approved: it was just installed, or an update asks for more.
    var needsReview: Bool {
        guard let grant else { return false }
        return !(record.approved?.covers(grant) ?? false)
    }
    var runs: Bool { record.enabled && manifest != nil && problem == nil && !needsReview }
    var hasPage: Bool { manifest?.entry != nil }
}

/// A plugin waiting for the user's yes: one to install from a file or link, or an installed one whose first
/// install or update asks for something not yet approved.
struct PluginReview: Identifiable {
    let id = UUID()
    let package: PluginPackage
    let source: PluginSource
    let sha256: String?
    /// What the user approved before, so the sheet marks what is new.
    let approved: PluginGrant?
    /// Installed already and waiting for approval, rather than unpacked to install.
    let installed: Bool
    /// Where the installed plugin with this id came from, when this one comes from somewhere else: it replaces
    /// that plugin and keeps its stored data, so the sheet says so and treats it as a new install.
    var replacing: PluginSource? = nil
    var compatible: Bool { package.manifest.runs(on: AppVersion.current) }
    var additions: (permissions: [PluginPermission], hosts: [String], scripts: [String]) {
        (approved ?? PluginGrant()).additions(in: package.grant)
    }
}

/// A plugin in the directory at frog.beffa.xyz/plugins.
struct PluginListing: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let version: String
    let description: String
    let author: String
    let homepage: String
    let symbol: String?
    let permissions: [String]
    let hosts: [String]
    let frog: String?
    let download: String
    let sha256: String

    var downloadURL: URL? { URL(string: download).flatMap { $0.scheme == "https" ? $0 : nil } }
    var isUsable: Bool {
        PluginManifest.isValidID(id) && downloadURL != nil && sha256.count == 64 && sha256.allSatisfy(\.isHexDigit)
    }
}

/// Runs the installed plugins: one sandboxed page each, created when first needed, and the `frog` bridge, which
/// checks every call against what the user approved.
@MainActor final class PluginRuntime: NSObject, ObservableObject {
    /// The plugin directory's index; nil reads none, as in tests.
    var directoryURL: URL? = URL(string: "https://frog.beffa.xyz/plugins/index.json")
    /// Where removed plugins go; tests delete them instead of filling the user's Trash.
    var trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    static let maximumLogLines = 500

    @Published private(set) var items: [PluginItem] = []
    @Published var review: PluginReview?
    @Published private(set) var listings: [PluginListing] = []
    @Published private(set) var listingsError: String?
    @Published private(set) var loadingListings = false
    /// The host a link is being downloaded from.
    @Published private(set) var downloading: String?
    /// Plugins whose page is loaded, shown or not.
    @Published private(set) var running: Set<String> = []

    let store: PluginStore
    private(set) var logs: [String: [PluginLogLine]] = [:]
    private var hosts: [String: PluginWebHost] = [:]
    private var storages: [String: PluginStorage] = [:]
    /// When each plugin last showed a notification at once, for the rate limit.
    private var shownNotifications: [String: [Date]] = [:]
    private var contentRules: WKContentRuleList?
    private var busy: [String: Int] = [:]
    private var enabled = false
    private lazy var network = PluginNetwork(userAgent: "Frog/\(AppVersion.current) plugin")
    private let downloads: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()

    /// Shows a plugin's page in Frog's window.
    var openPage: (String) -> Void = { _ in }
    /// Called once the user approved a plugin.
    var onApproved: (String) -> Void = { _ in }
    var report: (Error) -> Void = { _ in }
    /// Runs text through the user's default text model: plugin name, instructions, text.
    var complete: (String, String, String) async throws -> String = { _, _, _ in throw FrogError.message("No model is set up.") }
    /// The pasteboard the bridge reads and writes; tests use their own.
    var pasteboard = NSPasteboard.general

    init(store: PluginStore) {
        self.store = store
        super.init()
    }

    // MARK: Lifecycle

    /// Starts or stops with the Plugins feature.
    func configure(enabled: Bool) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        if enabled {
            refresh()
            if Self.notificationsAvailable { UNUserNotificationCenter.current().delegate = self }
        } else {
            stopPages()
        }
    }

    func stop() {
        stopPages()
        enabled = false
    }

    private func stopPages() {
        for host in hosts.values { host.stop() }
        hosts = [:]
        running = []
        busy = [:]
    }

    /// Reads the records and the installed files again.
    func refresh() {
        let records: [PluginRecord]
        do { records = try store.records() } catch { report(error); return }
        items = records.map { record in
            do {
                let package = try store.package(record.id)
                return PluginItem(record: record, manifest: package.manifest, grant: package.grant, problem: nil)
            } catch {
                return PluginItem(record: record, manifest: nil, grant: nil, problem: error.localizedDescription)
            }
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for id in hosts.keys where items.first(where: { $0.id == id })?.runs != true { unload(id) }
    }

    func item(_ id: String) -> PluginItem? { items.first { $0.id == id } }

    /// The plugin's page, loaded on first use. Fails for a plugin that is off or waits for review.
    func host(for id: String) async throws -> PluginWebHost {
        guard enabled else { throw FrogError.message("Turn on Plugins in Features first.") }
        if let host = hosts[id] { return host }
        guard let item = item(id) else { throw FrogError.message("No plugin “\(id)” is installed.") }
        if let problem = item.problem { throw FrogError.message(problem) }
        guard !item.needsReview else { throw FrogError.message("Review \(item.name) in Plugins before it runs.") }
        guard item.record.enabled else { throw FrogError.message("\(item.name) is turned off in Plugins.") }
        let rules = try await contentRuleList()
        if let host = hosts[id] { return host }
        let package = try store.package(id)
        guard let approved = item.record.approved, approved.covers(package.grant) else {
            throw FrogError.message("Review \(item.name) in Plugins before it runs.")
        }
        var inspectable = false
        if case .folder = item.record.source { inspectable = true }
        let host = PluginWebHost(package: package, contentRules: rules, runtime: self, inspectable: inspectable)
        hosts[id] = host
        running.insert(id)
        host.load()
        return host
    }

    func loadedHost(_ id: String) -> PluginWebHost? { hosts[id] }

    /// Unloads the page. Its storage stays.
    func unload(_ id: String) {
        hosts[id]?.stop()
        hosts[id] = nil
        running.remove(id)
    }

    func reload(_ id: String) {
        guard let host = hosts[id] else { return }
        host.reload()
    }

    private func contentRuleList() async throws -> WKContentRuleList {
        if let contentRules { return contentRules }
        guard let store = WKContentRuleListStore.default() else { throw FrogError.message("Plugins cannot start: WebKit has no rule store.") }
        let list = try await store.compileContentRuleList(forIdentifier: "frog-plugin-sandbox-2", encodedContentRuleList: PluginPageSource.contentRules)
        guard let list else { throw FrogError.message("Plugins cannot start: the sandbox rules did not compile.") }
        contentRules = list
        return list
    }

    // MARK: Commands

    /// Sends the command to the plugin's page, loading it first, and shows the page unless the command says not to.
    func run(command: String, of id: String) async throws {
        guard let manifest = item(id)?.manifest, let entry = manifest.commands.first(where: { $0.id == command }) else {
            throw FrogError.message("The plugin has no command “\(command)”.")
        }
        let host = try await host(for: id)
        host.lastCommand = Date()
        host.emit("command", command)
        if entry.opensPage, manifest.entry != nil { openPage(id) }
    }

    func snapshot(_ id: String) async throws -> Data {
        let host = try await host(for: id)
        return try await host.snapshot()
    }

    // MARK: Logs

    func log(_ id: String, level: String, _ text: String) {
        var lines = logs[id] ?? []
        lines.append(PluginLogLine(date: Date(), level: level, text: String(text.prefix(4_000))))
        if lines.count > Self.maximumLogLines { lines.removeFirst(lines.count - Self.maximumLogLines) }
        logs[id] = lines
    }

    // MARK: Installing

    /// Installs from a folder, such as the one an AI agent builds the plugin in. A plugin new to Frog, or an update
    /// that asks for more, waits for the user's review in Frog; nothing from this path approves it.
    @discardableResult
    func installFolder(_ folder: URL) throws -> PluginItem {
        let package = try PluginPackage.read(folder.standardizedFileURL)
        let id = package.manifest.id
        try store.install(package, source: .folder(folder.standardizedFileURL.path))
        refresh()
        guard let item = item(id) else { throw FrogError.message("The plugin was installed but could not be read back.") }
        if item.runs { reload(id) } else { unload(id) }
        return item
    }

    /// Unpacks a `.frogplugin` file and opens its review. Nothing is installed until the user approves.
    func openArchive(_ data: Data, source: PluginSource) async throws {
        guard data.count <= PluginArchive.maximumArchiveBytes else { throw FrogError.message("A plugin file can be at most 25 MB.") }
        let sha256 = PluginPackage.sha256(data)
        clearStaging()
        let package = try store.unpack(data, in: stagingDirectory)
        let record = try store.record(package.manifest.id)
        let sameOrigin = record?.source.sharesOrigin(with: source) ?? false
        review = PluginReview(package: package, source: source, sha256: sha256, approved: sameOrigin ? record?.approved : nil,
                              installed: false, replacing: sameOrigin ? nil : record?.source)
        // The review opens at once; whether the directory lists the file shows once the directory answers.
        if listings.isEmpty { Task { await loadListings() } }
    }

    /// Downloads a `.frogplugin` over https, checks it against `sha256` when given, and opens its review.
    func openLink(_ url: URL, sha256: String?) async throws {
        guard url.scheme?.lowercased() == "https", url.host != nil else { throw FrogError.message("Plugins install only from https links.") }
        if let sha256, !(sha256.count == 64 && sha256.allSatisfy(\.isHexDigit)) { throw FrogError.message("The link's SHA-256 is not valid.") }
        downloading = url.host
        defer { downloading = nil }
        var request = URLRequest(url: url)
        request.setValue("Frog/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await downloads.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FrogError.message("The plugin could not be downloaded from \(url.host ?? "the link").")
        }
        guard http.url?.scheme?.lowercased() == "https" else { throw FrogError.message("The download left https.") }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > PluginArchive.maximumArchiveBytes { throw FrogError.message("A plugin file can be at most 25 MB.") }
        }
        if let sha256, PluginPackage.sha256(data) != sha256.lowercased() {
            throw FrogError.message("The downloaded file is not the one the link names: its SHA-256 differs. Nothing was installed.")
        }
        try await openArchive(data, source: .link(url.absoluteString))
    }

    /// Opens the review of an installed plugin that waits for approval.
    func reviewInstalled(_ id: String) throws {
        let package = try store.package(id)
        let record = try store.record(id)
        review = PluginReview(package: package, source: record?.source ?? .folder(package.root.path), sha256: record?.sha256,
                              approved: record?.approved, installed: true)
        if record?.sha256 != nil, listings.isEmpty { Task { await loadListings() } }
    }

    /// Installs or approves what the review showed, exactly: a plugin that changed since is refused.
    func approve(_ review: PluginReview) throws {
        guard review.compatible else {
            throw FrogError.message("\(review.package.manifest.name) needs Frog \(review.package.manifest.frog ?? "") or later. Update Frog first.")
        }
        let id = review.package.manifest.id
        if review.installed {
            try store.approve(id, expecting: review.package.grant)
        } else {
            try store.install(review.package, source: review.source, sha256: review.sha256, approving: true)
            clearStaging()
        }
        self.review = nil
        unload(id)
        refresh()
        onApproved(id)
    }

    func dismissReview() {
        if review?.installed == false { clearStaging() }
        review = nil
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        do {
            try store.setEnabled(id, enabled)
            if !enabled { unload(id) }
            refresh()
        } catch { report(error) }
    }

    func remove(_ id: String) {
        unload(id)
        do {
            try store.remove(id, trash: trash)
            storages[id] = nil
            logs[id] = nil
            removeNotifications(of: id)
            refresh()
        } catch { report(error) }
    }

    private var stagingDirectory: URL { store.directory.appendingPathComponent("Staging", isDirectory: true) }
    private func clearStaging() { try? FileManager.default.removeItem(at: stagingDirectory) }

    // MARK: Directory

    /// Whether the directory lists this exact file.
    func isListed(_ sha256: String?) -> Bool {
        guard let sha256 = sha256?.lowercased() else { return false }
        return listings.contains { $0.sha256.lowercased() == sha256 }
    }

    func loadListings() async {
        guard !loadingListings, let directoryURL else { return }
        loadingListings = true
        defer { loadingListings = false }
        struct Directory: Decodable { let plugins: [PluginListing] }
        do {
            var request = URLRequest(url: directoryURL, timeoutInterval: 15)
            request.setValue("Frog/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await downloads.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2 * 1024 * 1024 else {
                throw FrogError.message("The plugin directory did not answer.")
            }
            listings = try JSONDecoder().decode(Directory.self, from: data).plugins.filter(\.isUsable)
            listingsError = nil
        } catch {
            listingsError = "The plugin directory could not be loaded: \(error.localizedDescription)"
        }
    }

    // MARK: The bridge

    /// Answers one call from a plugin's page. `PluginWebHost` has checked that it came from that plugin's own page.
    func handle(_ name: String, _ arguments: [String: Any], from host: PluginWebHost) async throws -> Any? {
        let id = host.id
        guard enabled, hosts[id] === host, let item = item(id), item.runs, let approved = item.record.approved else {
            throw FrogError.message("The plugin is not running.")
        }
        func require(_ permission: PluginPermission) throws {
            guard host.manifest.permissions.contains(permission), approved.permissions.contains(permission) else {
                throw FrogError.message("\(name) needs the “\(permission.rawValue)” permission in plugin.json.")
            }
        }
        func text(_ key: String, maximum: Int, required: Bool = true) throws -> String? {
            guard let value = arguments[key] as? String else {
                if required { throw FrogError.message("\(name) needs “\(key)”.") }
                return nil
            }
            guard value.utf8.count <= maximum else { throw FrogError.message("“\(key)” is longer than \(maximum / 1024) KB.") }
            return value
        }

        switch name {
        case "log":
            log(id, level: (try text("level", maximum: 10)) ?? "log", try text("text", maximum: 8_000) ?? "")
            return nil

        case "storage.get":
            return try storage(id).get(try text("key", maximum: 1_000)!)
        case "storage.set":
            let json = try text("json", maximum: PluginStorage.maximumBytes)!
            guard (try? JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)) != nil else {
                throw FrogError.message("Storage keeps JSON values only.")
            }
            try storage(id).set(try text("key", maximum: 1_000)!, json: json)
            return nil
        case "storage.remove":
            try storage(id).set(try text("key", maximum: 1_000)!, json: nil)
            return nil
        case "storage.keys":
            return try storage(id).keys()

        case "clipboard.read":
            try require(.clipboardRead)
            guard host.isShowing || host.commandedRecently else {
                throw FrogError.message("A plugin reads the clipboard only while its page is open or right after one of its commands.")
            }
            guard !pasteboard.holdsSensitiveText else { return nil }
            return pasteboard.string(forType: .string)
        case "clipboard.write":
            try require(.clipboardWrite)
            guard host.isShowing || host.commandedRecently else {
                throw FrogError.message("A plugin writes the clipboard only while its page is open or right after one of its commands.")
            }
            let value = try text("text", maximum: 1024 * 1024)!
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
            return nil

        case "notify":
            try require(.notifications)
            return try await notify(host, title: try text("title", maximum: 400)!, body: try text("body", maximum: 2_000, required: false) ?? "",
                                    at: (arguments["at"] as? NSNumber)?.doubleValue, tag: try text("id", maximum: 100, required: false))
        case "notify.cancel":
            try require(.notifications)
            let identifier = Self.notificationPrefix(id) + (try text("id", maximum: 100)!)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
            return nil

        case "openURL":
            try require(.links)
            guard let url = URL(string: try text("url", maximum: 8_000)!), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw FrogError.message("A plugin opens http and https links only.")
            }
            NSWorkspace.shared.open(url)
            return nil

        case "fetch":
            try require(.network)
            guard let url = URL(string: try text("url", maximum: 8_000)!) else { throw FrogError.message("That is not a web address.") }
            let headers = (arguments["headers"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
            let body = try text("body", maximum: PluginNetwork.maximumRequestBytes, required: false).map { Data($0.utf8) }
            let request = PluginFetchRequest(url: url, method: try text("method", maximum: 10, required: false) ?? "GET", headers: headers,
                                             body: body, base64: arguments["as"] as? String == "base64")
            let allowed = host.manifest.hosts.filter(approved.hosts.contains)
            return try await limited(id, "fetch", maximum: 6) {
                try await self.network.fetch(request, hosts: allowed).dictionary
            }

        case "ai":
            try require(.ai)
            let instructions = try text("instructions", maximum: 20_000)!
            let input = try text("text", maximum: 200_000, required: false) ?? ""
            guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FrogError.message("frog.ai needs instructions.") }
            return try await limited(id, "ai", maximum: 1) {
                try await self.complete(host.manifest.name, instructions, input)
            }

        case "run":
            try require(.scripts)
            let script = try text("name", maximum: 100)!
            guard host.manifest.scripts[script] != nil, let approvedHash = approved.scripts[script] else {
                throw FrogError.message("The plugin has no script “\(script)” in plugin.json.")
            }
            let package = try store.package(id)
            let source = try package.scriptText(script)
            // The script that runs is the one the user approved, byte for byte.
            guard PluginPackage.sha256(Data(source.utf8)) == approvedHash, package.scriptHashes[script] == approvedHash,
                  package.scriptHashes[PluginGrant.filesKey] == approved.scripts[PluginGrant.filesKey] else {
                throw FrogError.message("The script “\(script)” changed since you approved it. Review the plugin again.")
            }
            let scriptArguments = (arguments["args"] as? [Any] ?? []).compactMap { $0 as? String }
            guard scriptArguments.count <= 50, scriptArguments.allSatisfy({ $0.utf8.count <= 10_000 }) else {
                throw FrogError.message("A script takes at most 50 arguments of 10 KB each.")
            }
            let input = try text("input", maximum: 100_000, required: false)
            let folder = store.dataFolder(for: id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return try await limited(id, "run", maximum: 2) {
                let result = try await ScriptProcess.run(source, arguments: scriptArguments, directory: folder,
                                                         environment: ["FROG_INPUT": input ?? "", "FROG_PLUGIN_ID": id],
                                                         timeout: 60, outputLimit: 1024 * 1024)
                return ["output": result.output, "status": Int(result.status), "truncated": result.truncated] as [String: Any]
            }

        case "show":
            guard host.manifest.entry != nil else { throw FrogError.message("This plugin has no page to show.") }
            // Only a command the user ran brings Frog forward; a page in the background cannot.
            guard host.isShowing || host.commandedRecently else {
                throw FrogError.message("A plugin shows its page only right after one of its commands.")
            }
            openPage(id)
            return nil
        case "close":
            if !host.isShowing { unload(id) }
            return nil

        default:
            throw FrogError.message("Frog has no “\(name)”.")
        }
    }

    /// Follows a link the page activated, when it may open links.
    func followLink(_ url: URL, from host: PluginWebHost) {
        guard let approved = item(host.id)?.record.approved, approved.permissions.contains(.links), host.manifest.permissions.contains(.links),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            log(host.id, level: "warn", "Blocked a link to \(url.absoluteString.prefix(200)). Add the “links” permission to open web links.")
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func storage(_ id: String) throws -> PluginStorage {
        if let storage = storages[id] { return storage }
        let folder = store.dataFolder(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let storage = PluginStorage(folder: folder)
        storages[id] = storage
        return storage
    }

    /// Runs `work` while fewer than `maximum` of the plugin's `kind` calls are running.
    private func limited<T>(_ id: String, _ kind: String, maximum: Int, _ work: () async throws -> T) async throws -> T {
        let key = "\(id) \(kind)"
        guard busy[key, default: 0] < maximum else { throw FrogError.message("Wait for the plugin's earlier \(kind) call to finish.") }
        busy[key, default: 0] += 1
        defer { busy[key, default: 1] -= 1 }
        return try await work()
    }

    // MARK: Notifications

    private func notify(_ host: PluginWebHost, title: String, body: String, at: Double?, tag: String?) async throws -> String {
        guard Self.notificationsAvailable else { throw FrogError.message("Notifications need the installed Frog app.") }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FrogError.message("A notification needs a title.") }
        let center = UNUserNotificationCenter.current()
        guard try await center.requestAuthorization(options: [.alert, .sound]) else {
            throw FrogError.message("Notifications from Frog are off. Turn them on in System Settings → Notifications.")
        }
        let tag = tag ?? UUID().uuidString
        let prefix = Self.notificationPrefix(host.id)
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = host.manifest.name
        content.body = body
        content.sound = .default
        content.threadIdentifier = "plugin.\(host.id)"
        content.userInfo = ["plugin": host.id]
        var trigger: UNNotificationTrigger?
        if let at {
            let seconds = at / 1000 - Date().timeIntervalSince1970
            guard seconds <= 30 * 24 * 3600 else { throw FrogError.message("A notification can be at most 30 days ahead.") }
            if seconds >= 1 {
                let pending = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(prefix) && $0.identifier != prefix + tag }
                guard pending.count < 20 else { throw FrogError.message("A plugin can have at most 20 notifications waiting.") }
                trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
            }
        }
        if trigger == nil {
            let now = Date()
            let recent = (shownNotifications[host.id] ?? []).filter { now.timeIntervalSince($0) < 60 }
            guard recent.count < 10 else { throw FrogError.message("A plugin can show at most 10 notifications a minute.") }
            shownNotifications[host.id] = recent + [now]
        }
        try await center.add(UNNotificationRequest(identifier: prefix + tag, content: content, trigger: trigger))
        return tag
    }

    /// Notification Center serves app bundles only; a test or `swift run` has none.
    static var notificationsAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    /// Ids may contain dots, so a slash, which ids cannot, ends the plugin's part of a notification's identifier.
    static func notificationPrefix(_ id: String) -> String { "plugin.\(id)/" }

    private func removeNotifications(of id: String) {
        guard Self.notificationsAvailable else { return }
        let prefix = Self.notificationPrefix(id)
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: requests.map(\.identifier).filter { $0.hasPrefix(prefix) })
        }
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: notifications.map(\.request.identifier).filter { $0.hasPrefix(prefix) })
        }
    }
}

extension PluginRuntime: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// Clicking a plugin's notification opens its page.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["plugin"] as? String else { return }
        await MainActor.run {
            guard let item = self.item(id), item.runs, item.hasPage else { return }
            self.openPage(id)
        }
    }
}
