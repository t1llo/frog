import Foundation

/// How an item reaches the Trash: `FileManager.trashItem` for the user's own items, Finder for app bundles,
/// containers and administrator-owned items, so Finder can ask for the password.
public enum TrashRoute: String, Codable, Sendable { case fileManager, finder }

public struct PlannedRemoval: Sendable, Equatable {
    public var item: CleanerItem
    public var route: TrashRoute

    public init(item: CleanerItem, route: TrashRoute) {
        self.item = item
        self.route = route
    }
}

/// A ticked item `CleanerSafety` does not allow, with its sentence.
public struct RemovalRefusal: Sendable, Equatable {
    public var item: CleanerItem
    public var reason: String

    public init(item: CleanerItem, reason: String) {
        self.item = item
        self.reason = reason
    }
}

/// What moving the ticked items to the Trash does: which items move by which route, what is quit or stopped
/// first, and how much space it frees.
public struct RemovalPlan: Sendable, Equatable {
    public var app: AppIdentity?
    /// As passed to `make`; the remover checks every item again with it.
    public var purpose: CleanerSafety.Purpose
    /// Sorted by path.
    public var removals: [PlannedRemoval]
    public var refused: [RemovalRefusal]
    /// The app's bundle IDs when anything of the app moves.
    public var quitBundleIDs: [String]
    /// Launch agents that move; they are booted out of the gui domain first.
    public var launchLabelsToStop: [String]
    /// Launch daemons and helper tools that move; they keep running until the Mac restarts.
    public var restartLabels: [String]
    /// The sum of the known sizes.
    public var totalBytes: Int64
    /// A moving item has no size or an incomplete one, so `totalBytes` is a lower bound.
    public var sizeIncomplete: Bool
    public var removesApp: Bool

    public var finderCount: Int { removals.filter { $0.route == .finder }.count }
    public var administratorCount: Int { removals.filter { $0.item.owner == .administrator }.count }
    public var isEmpty: Bool { removals.isEmpty }

    public static func make(app: AppIdentity?, items: [CleanerItem], selected: Set<String>,
                            purpose: CleanerSafety.Purpose, safety: CleanerSafety,
                            sizes: [String: CleanerSize] = [:]) -> RemovalPlan {
        var allowed: [CleanerItem] = [], refused: [RemovalRefusal] = []
        for item in items where selected.contains(item.id) {
            if let reason = safety.refusal(for: item.url, purpose: item.kind == .application ? .application : purpose) {
                refused.append(RemovalRefusal(item: item, reason: reason))
            } else {
                allowed.append(item)
            }
        }

        // An item inside a folder that also moves goes with its folder.
        let paths = Set(allowed.map { safety.roots.resolved($0.url).path })
        let kept = allowed.filter { item in
            var parent = safety.roots.resolved(item.url).deletingLastPathComponent()
            while parent.pathComponents.count > 1 {
                if paths.contains(parent.path) { return false }
                parent.deleteLastPathComponent()
            }
            return true
        }

        let removals = kept.map { item in
            let finder = [CleanerItemKind.application, .container, .groupContainer].contains(item.kind)
                || item.owner == .administrator
            return PlannedRemoval(item: item, route: finder ? .finder : .fileManager)
        }.sorted { $0.item.id < $1.item.id }

        var stop: [String] = [], restart: [String] = []
        for removal in removals {
            let item = removal.item, label = item.jobLabel
            switch item.kind {
            case .launchAgent: if !stop.contains(label) { stop.append(label) }
            case .launchDaemon, .helperTool: if !restart.contains(label) { restart.append(label) }
            default: break
            }
        }

        var total: Int64 = 0, incomplete = false
        for removal in removals {
            let measured = sizes[removal.item.id]
            if let bytes = measured?.bytes ?? removal.item.size { total += bytes }
            if measured.map({ !$0.complete }) ?? (removal.item.size == nil) { incomplete = true }
        }

        let appPath = app.map { safety.roots.resolved($0.url).path }
        let removesApp = removals.contains { removal in
            removal.item.kind == .application && (appPath == nil || safety.roots.resolved(removal.item.url).path == appPath)
        }
        return RemovalPlan(app: app, purpose: purpose, removals: removals,
                           refused: refused.sorted { $0.item.id < $1.item.id },
                           quitBundleIDs: removals.isEmpty ? [] : app?.bundleIDs ?? [],
                           launchLabelsToStop: stop, restartLabels: restart, totalBytes: total,
                           sizeIncomplete: incomplete, removesApp: removesApp)
    }
}

extension CleanerItem {
    /// A job's file is named after its label by convention, so the name stands in when no label was read.
    var jobLabel: String {
        launchLabel ?? (url.pathExtension == "plist" ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent)
    }
}

/// What the confirmation sheet says before items move: one title and the notes that apply, in a fixed order.
public struct RemovalPrompt: Equatable, Sendable {
    public let title: String
    public let notes: [String]
    public let confirm: String
    public let cancel: String

    public init(plan: RemovalPlan, appIsRunning: Bool, runningHelpers: Int,
                formatBytes: (Int64) -> String = CleanerFormat.bytes) {
        let count = plan.removals.count
        let appName = plan.app?.name ?? plan.removals.first { $0.item.kind == .application }
            .map { $0.item.url.deletingPathExtension().lastPathComponent }
        if plan.removesApp, let name = appName {
            let others = count - 1
            title = others == 0 ? "Move \(name) to the Trash?"
                : others == 1 ? "Move \(name) and 1 other item to the Trash?"
                : "Move \(name) and \(others) other items to the Trash?"
        } else if let name = plan.app?.name {
            title = count == 1 ? "Move 1 item of \(name) to the Trash?" : "Move \(count) items of \(name) to the Trash?"
        } else {
            title = count == 1 ? "Move 1 item to the Trash?" : "Move \(count) items to the Trash?"
        }

        var notes: [String] = []
        if let name = plan.app?.name, !plan.quitBundleIDs.isEmpty, appIsRunning || runningHelpers > 0 {
            if !appIsRunning {
                notes.append("Frog quits \(runningHelpers) of \(name)'s helpers first.")
            } else if runningHelpers == 0 {
                notes.append("Frog quits \(name) first.")
            } else if runningHelpers == 1 {
                notes.append("Frog quits \(name) and 1 of its helpers first.")
            } else {
                notes.append("Frog quits \(name) and \(runningHelpers) of its helpers first.")
            }
        }
        let stopping = plan.launchLabelsToStop.count
        if stopping == 1 { notes.append("Frog stops 1 background service first.") }
        if stopping > 1 { notes.append("Frog stops \(stopping) background services first.") }
        let finder = plan.finderCount
        if finder == 1 { notes.append("Finder moves 1 item. macOS asks once whether Frog may control Finder.") }
        if finder > 1 { notes.append("Finder moves \(finder) items. macOS asks once whether Frog may control Finder.") }
        let administrator = plan.administratorCount
        if administrator == 1 {
            notes.append("1 item belongs to the system. Finder asks for your administrator password; Frog never sees it.")
        }
        if administrator > 1 {
            notes.append("\(administrator) items belong to the system. Finder asks for your administrator password; Frog never sees it.")
        }
        let restarting = plan.restartLabels.count
        if restarting == 1 { notes.append("1 background service stops after you restart your Mac.") }
        if restarting > 1 { notes.append("\(restarting) background services stop after you restart your Mac.") }
        if let app = plan.app, app.hasSystemExtensions, plan.removesApp {
            notes.append("\(app.name)'s system extension is removed with the app. macOS may ask you to confirm.")
        }
        let refused = plan.refused.count
        if refused == 1 { notes.append("Frog leaves out 1 item it may not move.") }
        if refused > 1 { notes.append("Frog leaves out \(refused) items it may not move.") }
        let space = formatBytes(plan.totalBytes)
        notes.append(plan.sizeIncomplete ? "The space (at least \(space)) is freed when you empty the Trash."
            : "The space (\(space)) is freed when you empty the Trash.")
        notes.append(administrator > 0
            ? "Put back items that belong to the system with Put Back in Finder's Trash; Frog puts back only your own items."
            : "You can put items back from Recently moved in Frog, or from the Trash.")
        self.notes = notes
        confirm = "Move to Trash"
        cancel = "Cancel"
    }
}
