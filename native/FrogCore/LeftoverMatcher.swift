import Foundation

/// The parts of a launchd job property list the cleaner uses.
public struct LaunchPlist: Sendable, Equatable {
    public var url: URL
    public var label: String
    /// Program, else ProgramArguments[0].
    public var program: String?
    public var associatedBundleIDs: [String]
    public var runAtLoad: Bool
    /// True for a Bool true or any dictionary.
    public var keepAlive: Bool
    public var disabled: Bool

    public init(url: URL, label: String, program: String? = nil, associatedBundleIDs: [String] = [],
                runAtLoad: Bool = false, keepAlive: Bool = false, disabled: Bool = false) {
        self.url = url
        self.label = label
        self.program = program
        self.associatedBundleIDs = associatedBundleIDs
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.disabled = disabled
    }

    private static let maximumBytes = 262_144

    /// nil for unreadable, larger than 256 KB, or without Label. XML or binary.
    public static func read(_ url: URL) -> LaunchPlist? {
        guard let data = (try? PrivateFile.read(url, maximumBytes: maximumBytes)) ?? nil,
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let label = plist["Label"] as? String, !label.isEmpty else { return nil }
        let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [Any])?.first as? String
        let associated: [String]
        switch plist["AssociatedBundleIdentifiers"] {
        case let one as String: associated = [one]
        case let many as [Any]: associated = many.compactMap { $0 as? String }
        default: associated = []
        }
        let keepAlive: Bool
        switch plist["KeepAlive"] {
        case let flag as Bool: keepAlive = flag
        case is [String: Any]: keepAlive = true
        default: keepAlive = false
        }
        return LaunchPlist(url: url, label: label, program: program.flatMap { $0.isEmpty ? nil : $0 },
                           associatedBundleIDs: associated, runAtLoad: plist["RunAtLoad"] as? Bool ?? false,
                           keepAlive: keepAlive, disabled: plist["Disabled"] as? Bool ?? false)
    }
}

/// Decides whether a name in a leftover location belongs to one app, and how sure that is. Precision matters
/// more than recall: a certain or likely match the user does not untick moves someone's data to the Trash.
public struct LeftoverMatcher: Sendable {
    public struct Match: Sendable, Equatable {
        public var confidence: MatchConfidence
        public var reason: String
        /// Names of other installed apps that claim the item too.
        public var sharedWith: [String]
        public init(confidence: MatchConfidence, reason: String, sharedWith: [String] = []) {
            self.confidence = confidence
            self.reason = reason
            self.sharedWith = sharedWith
        }
    }

    private enum IDKind: Sendable { case main, nested, group }

    /// Who holds one lowercased ID: this app (`app == nil`) or another installed app.
    private struct Holder: Sendable {
        var app: Int?
        var id: String
        var kind: IDKind
    }

    private let app: AppIdentity
    private let others: [AppIdentity]
    /// Every installed app's bundle IDs and app groups, lowercased.
    private let holders: [String: [Holder]]
    /// Every other app's names, lowercased, to the indices of the apps that use them.
    private let otherNames: [String: [Int]]
    private let names: [String]
    private let containsTerms: [String]
    private let otherContainsTerms: [[String]]
    private let vendorPrefix: String?
    private let otherVendorPrefixes: [String?]

    private static let likelyLocations: Set<LeftoverLocation> = [.applicationSupport, .caches, .logs, .httpStorages, .webKit]
    private static let crashExtensions: Set<String> = ["ips", "crash", "diag", "hang"]

    public init(app: AppIdentity, otherApps: [AppIdentity]) {
        self.app = app
        let others = otherApps.filter { $0.path != app.path }
        self.others = others
        var holders: [String: [Holder]] = [:]
        func add(_ identity: AppIdentity, index: Int?) {
            let ids = [(identity.bundleID, IDKind.main)] + identity.nestedBundleIDs.map { ($0, .nested) }
                + identity.appGroups.map { ($0, .group) }
            for (id, kind) in ids where Self.isUsableID(id) {
                holders[id.lowercased(), default: []].append(Holder(app: index, id: id, kind: kind))
            }
        }
        add(app, index: nil)
        for (index, other) in others.enumerated() { add(other, index: index) }
        self.holders = holders
        var otherNames: [String: [Int]] = [:]
        for (index, other) in others.enumerated() {
            for name in other.names { otherNames[name.lowercased(), default: []].append(index) }
        }
        self.otherNames = otherNames
        names = app.names
        containsTerms = Self.containsTerms(of: app)
        otherContainsTerms = others.map(Self.containsTerms(of:))
        vendorPrefix = Self.vendorPrefix(of: app.bundleID)
        otherVendorPrefixes = others.map { Self.vendorPrefix(of: $0.bundleID) }
    }

    // MARK: - Names

    public func match(name: String, location: LeftoverLocation) -> Match? {
        let lowered = name.lowercased()
        switch idMatch(lowered) {
        case .other: return nil
        case let .own(holder, shared):
            return Match(confidence: .certain, reason: reason(for: holder), sharedWith: shared)
        case .none: break
        }

        if let own = names.first(where: { $0.lowercased() == lowered }) {
            if Self.likelyLocations.contains(location), Self.isDistinctive(own) {
                return Match(confidence: .likely, reason: "Folder named \(own).", sharedWith: sharingName(lowered))
            }
        } else if otherNames[lowered] != nil {
            // Named exactly after another installed app: it is that app's.
            return nil
        }

        if location == .diagnosticReports {
            switch crashReport(lowered) {
            case .other: return nil
            case let .own(match): return match
            case .none: break
            }
        }
        return possibleMatch(lowered)
    }

    public func match(launchPlist: LaunchPlist) -> Match? {
        if let program = launchPlist.program.map({ URL(fileURLWithPath: $0).standardizedFileURL.path.lowercased() }) {
            let bundles = [(app.path, nil as Int?)] + others.enumerated().map { ($0.element.path, $0.offset as Int?) }
            let owner = bundles
                .map { (path: URL(fileURLWithPath: $0.0).standardizedFileURL.path.lowercased(), index: $0.1) }
                .filter { program.hasPrefix($0.path + "/") }
                .max { $0.path.count < $1.path.count }
            if let owner {
                guard owner.index == nil else { return nil }
                return Match(confidence: .certain, reason: "Starts a program inside \(app.url.lastPathComponent).")
            }
        }

        if !launchPlist.associatedBundleIDs.isEmpty {
            let declared = launchPlist.associatedBundleIDs.flatMap { holders[$0.lowercased()] ?? [] }
            if declared.contains(where: { $0.app == nil }) {
                return Match(confidence: .certain, reason: "Declares \(app.name) as its app.",
                             sharedWith: appNames(declared.compactMap(\.app)))
            }
            if !declared.isEmpty { return nil }
        }

        let label = launchPlist.label.lowercased()
        switch idMatch(label) {
        case .other: return nil
        case let .own(_, shared):
            return Match(confidence: .certain, reason: "Its label is \(app.name)'s bundle ID.", sharedWith: shared)
        case .none: break
        }

        if let vendorPrefix, label.hasPrefix(vendorPrefix) {
            let shared = otherVendorPrefixes.indices.filter { otherVendorPrefixes[$0] == vendorPrefix }
            return Match(confidence: .possible, reason: "Label shares \(app.name)'s developer prefix.",
                         sharedWith: appNames(shared))
        }
        if otherNames[label] != nil, !names.contains(where: { $0.lowercased() == label }) { return nil }
        return possibleMatch(label)
    }

    // MARK: - Shared rules

    /// Never a likely match on their own. The single list of generic names in the cleaner: the AI
    /// suggestion search and the docs refer to this one.
    public static let genericNames: Set<String> = [
        "Google", "Microsoft", "Adobe", "Apple", "Helper", "Helpers", "Update", "Updater", "Electron", "Support",
        "Data", "Cache", "Caches", "Logs", "Sync", "Notes", "Player", "Agent", "Service", "Services", "Launcher",
        "Installer", "Plugins", "PlugIns", "Extensions", "Shared", "Common", "Default", "Temp", "Frameworks",
        "Library", "Settings", "Preferences", "Backup", "Backups", "Downloads", "Documents", "Desktop", "Media",
        "Music", "Movies", "Pictures", "Photos", "Mail", "Messages", "Calendar", "Contacts", "Reminders", "Safari",
        "Chrome", "Firefox", "Browser", "Code", "Studio", "Tools"
    ]
    private static let genericLowercased = Set(genericNames.map { $0.lowercased() })

    static func isGeneric(_ name: String) -> Bool { genericLowercased.contains(name.lowercased()) }

    /// At least 4 characters and not in `genericNames` (case-insensitive).
    public static func isDistinctive(_ name: String) -> Bool { name.count >= 4 && !isGeneric(name) }

    private static let bundleIDFirstComponents: Set<String> = ["com", "org", "net", "io", "app", "dev", "me", "co"]

    /// The one "looks like a bundle ID" rule in the cleaner (OrphanFinder and JunkScanner use it): at least three
    /// components separated by `.`, each 1-64 characters of letters, digits, `-` or `_`; the first component is
    /// `com`, `org`, `net`, `io`, `app`, `dev`, `me`, `co` or any two-letter country code.
    public static func isBundleIDShaped(_ name: String) -> Bool {
        let components = name.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 3, components.allSatisfy({ component in
            (1...64).contains(component.count) && component.unicodeScalars.allSatisfy {
                ($0.isASCII && (CharacterSet.alphanumerics.contains($0))) || $0 == "-" || $0 == "_"
            }
        }) else { return false }
        let first = components[0].lowercased()
        return bundleIDFirstComponents.contains(first)
            || (first.count == 2 && first.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.letters.contains($0) })
    }

    // MARK: - Vendor folders

    /// The developer's name from the bundle ID's second component, when it is distinctive.
    var vendor: String? {
        let components = app.bundleID.split(separator: ".")
        guard components.count >= 3, Self.isDistinctive(String(components[1])) else { return nil }
        return String(components[1]).lowercased()
    }

    /// A folder named after the developer in Application Support or Caches.
    func matchVendorFolder(name: String) -> Match? {
        let lowered = name.lowercased()
        guard let vendor, lowered == vendor else { return nil }
        if otherNames[lowered] != nil, !names.contains(where: { $0.lowercased() == lowered }) { return nil }
        let shared = others.indices.filter { index in
            let components = others[index].bundleID.lowercased().split(separator: ".")
            return components.count >= 3 && components[1] == Substring(vendor)
        }
        return Match(confidence: .possible, reason: "Folder of the developer, \(name).", sharedWith: appNames(shared))
    }

    /// A folder named exactly after the app inside the developer's folder.
    func matchInsideVendor(name: String, vendorFolder: String) -> Match? {
        let lowered = name.lowercased()
        guard let own = names.first(where: { $0.lowercased() == lowered }), Self.isDistinctive(own) else { return nil }
        return Match(confidence: .likely, reason: "Folder \(own) inside \(vendorFolder).", sharedWith: sharingName(lowered))
    }

    // MARK: - Private

    private enum IDResult {
        case none
        case other
        case own(Holder, shared: [String])
    }

    /// The longest bundle ID or app group the name equals or starts with, followed by `.`.
    private func idMatch(_ lowered: String) -> IDResult {
        var candidate = lowered[...]
        while true {
            if let found = holders[String(candidate)] {
                guard let own = found.first(where: { $0.app == nil }) else { return .other }
                return .own(own, shared: appNames(found.compactMap(\.app)))
            }
            guard let dot = candidate.lastIndex(of: ".") else { return .none }
            candidate = candidate[..<dot]
        }
    }

    private func reason(for holder: Holder) -> String {
        switch holder.kind {
        case .main: "Named after the bundle ID \(holder.id)."
        case .nested: "Named after \(holder.id), a part of \(app.name)."
        case .group: "Named after the app group \(holder.id)."
        }
    }

    private enum Claim {
        case none
        case other
        case own(Match)
    }

    /// `<Name>_...` or `<Name>-...` ending in a crash report extension; the longest app name wins.
    private func crashReport(_ lowered: String) -> Claim {
        let ext = (lowered as NSString).pathExtension
        guard Self.crashExtensions.contains(ext) else { return .none }
        func prefix(_ names: [String]) -> String? {
            names.map { $0.lowercased() }
                .filter { $0.count >= 3 && !Self.isGeneric($0) && (lowered.hasPrefix($0 + "_") || lowered.hasPrefix($0 + "-")) }
                .max { $0.count < $1.count }
        }
        let own = prefix(names)
        var shared: [Int] = []
        for (index, other) in others.enumerated() {
            guard let theirs = prefix(other.names) else { continue }
            if theirs.count > own?.count ?? 0 { return .other }
            if theirs == own { shared.append(index) }
        }
        guard let own else { return .none }
        let shown = names.first { $0.lowercased() == own } ?? app.name
        return .own(Match(confidence: .likely, reason: "Crash report of \(shown).", sharedWith: appNames(shared)))
    }

    private func possibleMatch(_ lowered: String) -> Match? {
        if let term = containsTerms.filter({ lowered.contains($0.lowercased()) }).max(by: { $0.count < $1.count }) {
            let shared = otherContainsTerms.indices.filter { index in
                otherContainsTerms[index].contains { lowered.contains($0.lowercased()) }
            }
            return Match(confidence: .possible, reason: "Name contains \(term).", sharedWith: appNames(shared))
        }
        if let team = app.teamID?.lowercased(), !team.isEmpty, lowered.hasPrefix(team + "."),
           !app.appGroups.contains(where: { $0.lowercased() == lowered }) {
            let shared = others.indices.filter { others[$0].teamID?.lowercased() == team }
            return Match(confidence: .possible, reason: "Starts with the developer's team ID.", sharedWith: appNames(shared))
        }
        return nil
    }

    private func sharingName(_ lowered: String) -> [String] { appNames(otherNames[lowered] ?? []) }

    /// Distinct names of other apps, in the order the apps were given.
    private func appNames(_ indices: [Int]) -> [String] {
        var seen = Set<Int>()
        return indices.sorted().filter { seen.insert($0).inserted }.map { others[$0].name }
    }

    /// App names of at least 5 characters and the bundle ID's last component of at least 5, none generic.
    private static func containsTerms(of app: AppIdentity) -> [String] {
        var terms = app.names.filter { $0.count >= 5 && !isGeneric($0) }
        if let last = app.bundleID.split(separator: ".").last.map(String.init), last.count >= 5, !isGeneric(last),
           !terms.contains(where: { $0.lowercased() == last.lowercased() }) {
            terms.append(last)
        }
        return terms
    }

    /// The first two bundle-ID components plus `.`, for an ID of at least three components.
    private static func vendorPrefix(of bundleID: String) -> String? {
        let components = bundleID.lowercased().split(separator: ".")
        guard components.count >= 3 else { return nil }
        return components.prefix(2).joined(separator: ".") + "."
    }

    /// An ID without a dot or shorter than 4 characters ("app", "Foo") would claim unrelated names.
    private static func isUsableID(_ id: String) -> Bool { id.count >= 4 && id.contains(".") }
}
