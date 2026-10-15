import Foundation

/// What a cleanable item is, which decides its symbol and how it moves to the Trash.
public enum CleanerItemKind: String, Codable, Sendable, CaseIterable {
    case application, folder, file, preferences, container, groupContainer, launchAgent, launchDaemon, helperTool

    /// The SF Symbol shown next to the item.
    public var symbol: String {
        switch self {
        case .application: "app"
        case .folder: "folder"
        case .file: "doc"
        case .preferences: "slider.horizontal.3"
        case .container: "shippingbox"
        case .groupContainer: "square.stack.3d.up"
        case .launchAgent: "gearshape.2"
        case .launchDaemon: "gearshape.2.fill"
        case .helperTool: "wrench.and.screwdriver"
        }
    }
}

/// How sure the scanner is that an item belongs to the app: `certain` matches a bundle ID, `likely` an exact,
/// distinctive app name, `possible` anything weaker.
public enum MatchConfidence: Int, Codable, Sendable, Comparable {
    case possible = 0, likely = 1, certain = 2
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Who owns an item on disk. Administrator-owned items move through Finder, which asks for the password.
public enum CleanerOwner: String, Codable, Sendable { case user, administrator }

/// One file or folder the cleaner offers to move to the Trash.
public struct CleanerItem: Identifiable, Codable, Hashable, Sendable {
    /// Standardized and absolute.
    public var url: URL
    public var kind: CleanerItemKind
    public var confidence: MatchConfidence
    /// One sentence shown under the path.
    public var reason: String
    public var owner: CleanerOwner
    /// Names of other installed apps that claim the item.
    public var sharedWith: [String]
    /// nil until measured, or when it cannot be measured.
    public var size: Int64?
    public var needsFullDiskAccess: Bool
    /// The job label of a launch agent or daemon.
    public var launchLabel: String?
    /// Found from an AI suggestion rather than by the scanner; never preselected.
    public var suggested: Bool

    public var id: String { url.path }
    /// Only confident, unshared, scanner-found items start ticked.
    public var isPreselected: Bool { !suggested && sharedWith.isEmpty && confidence >= .likely }

    public init(url: URL, kind: CleanerItemKind, confidence: MatchConfidence, reason: String,
                owner: CleanerOwner = .user, sharedWith: [String] = [], size: Int64? = nil,
                needsFullDiskAccess: Bool = false, launchLabel: String? = nil, suggested: Bool = false) {
        self.url = url.standardizedFileURL
        self.kind = kind
        self.confidence = confidence
        self.reason = reason
        self.owner = owner
        self.sharedWith = sharedWith
        self.size = size
        self.needsFullDiskAccess = needsFullDiskAccess
        self.launchLabel = launchLabel
        self.suggested = suggested
    }
}
