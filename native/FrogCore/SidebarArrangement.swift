import Foundation

/// How the sidebar orders the features: pinned ones first, then the others, each group in the
/// order the user arranged. A feature the stored order does not name, such as one a later Frog adds, takes its
/// place after the feature it follows in the catalog.
public struct SidebarArrangement: Equatable, Sendable {
    /// Every feature, in the user's order.
    public private(set) var order: [FeatureID]
    public private(set) var pinned: Set<FeatureID>

    public init(order stored: [String], pinned: Set<String>) {
        var order: [FeatureID] = []
        for id in stored {
            if let feature = FeatureID(rawValue: id), !order.contains(feature) { order.append(feature) }
        }
        let catalog = FeatureID.allCases
        for (index, feature) in catalog.enumerated() where !order.contains(feature) {
            let previous = catalog[..<index].last { order.contains($0) }
            order.insert(feature, at: previous.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        }
        self.order = order
        self.pinned = Set(pinned.compactMap(FeatureID.init(rawValue:)))
    }

    /// What settings keep: the whole order, so a feature turned on later already has its place; nothing while it
    /// is the catalog's, so later catalog changes still reach the user.
    public var storedOrder: [String] { order == FeatureID.allCases ? [] : order.map(\.rawValue) }
    public var storedPinned: Set<String> { Set(pinned.map(\.rawValue)) }
    /// The user pinned or moved something, so Reset has something to undo.
    public var isCustom: Bool { !pinned.isEmpty || order != FeatureID.allCases }

    /// The features of `visible` as the sidebar lists them, pinned ones first.
    public func shown(_ visible: [FeatureID]) -> [FeatureID] {
        let arranged = order.filter(Set(visible).contains)
        return arranged.filter(pinned.contains) + arranged.filter { !pinned.contains($0) }
    }

    /// Pinning leaves the order alone, so a feature unpinned again returns to where it was among the others.
    public mutating func setPinned(_ feature: FeatureID, _ pinned: Bool) {
        if pinned { self.pinned.insert(feature) } else { self.pinned.remove(feature) }
    }

    /// Moves `feature` so that it shows before what is at `index` of `shown`, the list as the sidebar shows it
    /// now (`shown.count` for the end). Dropped among the pinned features it is pinned, among the others it is
    /// not; on the line between the two groups it keeps what it was.
    public mutating func move(_ feature: FeatureID, to index: Int, in shown: [FeatureID]) {
        guard let from = shown.firstIndex(of: feature), let original = order.firstIndex(of: feature) else { return }
        var list = shown
        list.remove(at: from)
        let target = min(max(0, index > from ? index - 1 : index), list.count)
        let pinnedAbove = list.filter(pinned.contains).count
        if target < pinnedAbove { pinned.insert(feature) } else if target > pinnedAbove { pinned.remove(feature) }
        list.insert(feature, at: target)

        // Placed next to its new neighbour in the same group; alone in its group, it keeps its place.
        let isPinned = pinned.contains(feature)
        order.remove(at: original)
        if target + 1 < list.count, pinned.contains(list[target + 1]) == isPinned, let at = order.firstIndex(of: list[target + 1]) {
            order.insert(feature, at: at)
        } else if target > 0, pinned.contains(list[target - 1]) == isPinned, let at = order.firstIndex(of: list[target - 1]) {
            order.insert(feature, at: at + 1)
        } else {
            order.insert(feature, at: min(original, order.count))
        }
    }

    /// Move up and Move down stay inside the feature's group: pinning is its own command.
    public func canMove(_ feature: FeatureID, by offset: Int, in shown: [FeatureID]) -> Bool {
        guard let index = shown.firstIndex(of: feature), shown.indices.contains(index + offset) else { return false }
        return pinned.contains(shown[index + offset]) == pinned.contains(feature)
    }

    public mutating func move(_ feature: FeatureID, by offset: Int, in shown: [FeatureID]) {
        guard canMove(feature, by: offset, in: shown), let index = shown.firstIndex(of: feature) else { return }
        move(feature, to: offset < 0 ? index + offset : index + offset + 1, in: shown)
    }
}
