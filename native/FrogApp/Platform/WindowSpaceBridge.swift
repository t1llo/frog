import AppKit
import ApplicationServices

/// The public AX list may omit windows on inactive Spaces. Public WindowServer
/// metadata supplies their stable IDs; optional native symbols establish Space
/// membership and select the existing destination without moving any window.
/// No images, permission prompts, synthetic clicks, or preference changes.
enum WindowSpaceBridge {
    struct Window: Sendable {
        let id: CGWindowID
        let pid: pid_t
        let title: String?
    }

    private struct Display {
        let name: String
        let current: UInt64
        let spaces: Set<UInt64>
    }

    private typealias Connection = @convention(c) () -> UInt32
    private typealias CopyDisplays = @convention(c) (UInt32) -> Unmanaged<CFArray>?
    private typealias CopyMembership = @convention(c) (UInt32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias SelectSpace = @convention(c) (UInt32, CFString, UInt64) -> Void
    private typealias WindowNumber = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias Ordered = @convention(c) (UInt32, CGWindowID, UnsafeMutablePointer<UInt8>) -> CGError
    private typealias Tags = @convention(c) (UInt32, CGWindowID, UnsafeMutablePointer<UInt32>, Int) -> CGError

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(address, to: type)
    }
    private static let connection = symbol("CGSMainConnectionID", as: Connection.self)?() ?? 0
    private static let copyDisplays = symbol("CGSCopyManagedDisplaySpaces", as: CopyDisplays.self)
    private static let copyMembership = symbol("CGSCopySpacesForWindows", as: CopyMembership.self)
    private static let selectSpace = symbol("CGSManagedDisplaySetCurrentSpace", as: SelectSpace.self)
    private static let windowNumber = symbol("_AXUIElementGetWindow", as: WindowNumber.self)
    private static let ordered = symbol("CGSWindowIsOrderedIn", as: Ordered.self)
    private static let tags = symbol("CGSGetWindowTags", as: Tags.self)

    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard let windowNumber, windowNumber(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    private static func displays() -> [Display]? {
        guard connection != 0, let copyDisplays,
              let values = copyDisplays(connection)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        let result = values.compactMap { value -> Display? in
            guard let name = value["Display Identifier"] as? String,
                  let current = (value["Current Space"] as? [String: Any])?["id64"] as? NSNumber else { return nil }
            let spaces = (value["Spaces"] as? [[String: Any]] ?? []).compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
            return Display(name: name, current: current.uint64Value, spaces: Set(spaces))
        }
        return result.isEmpty ? nil : result
    }

    private static func spaces(_ id: CGWindowID) -> Set<UInt64>? {
        guard connection != 0, let copyMembership,
              let values = copyMembership(connection, 7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return nil }
        return Set(values.map(\.uint64Value))
    }

    static func offSpaceWindows(owners: Set<pid_t>) -> [Window] {
        guard !owners.isEmpty, windowNumber != nil, selectSpace != nil, let displays = displays(),
              let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let visible = Set(displays.map(\.current))
        return rows.compactMap { row in
            guard let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, owners.contains(pid),
                  (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let membership = spaces(id), !membership.isEmpty, membership.isDisjoint(with: visible),
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.width > 1, frame.height > 1 else { return nil }
            if let ordered {
                var value: UInt8 = 0
                guard ordered(connection, id, &value) == .success, value != 0 else { return nil }
            }
            if let tags {
                var value = [UInt32](repeating: 0, count: 2)
                let result = value.withUnsafeMutableBufferPointer { tags(connection, id, $0.baseAddress!, 64) }
                if result == .success, value[0] & (1 << 18) != 0 { return nil }
            }
            return Window(id: id, pid: pid, title: row[kCGWindowName as String] as? String)
        }
    }

    /// Checks the exact ID/owner before any Space change. IDs can disappear or be
    /// reused between presentation and selection; never activate a different owner.
    static func exists(_ id: CGWindowID, pid: pid_t) -> Bool {
        guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] else { return false }
        return rows.contains {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id
                && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
        }
    }

    static func isOnVisibleSpace(_ id: CGWindowID) -> Bool? {
        guard let membership = spaces(id), let topology = displays() else { return nil }
        return !membership.isDisjoint(with: Set(topology.map(\.current)))
    }

    static func reveal(_ id: CGWindowID, pid: pid_t, isCurrent: @Sendable () -> Bool,
                       willChangeSpace: @Sendable () async -> Void = {}) async -> Bool {
        guard !Task.isCancelled, isCurrent(), exists(id, pid: pid) else { return false }
        // Absence of the optional private API keeps the ordinary AX path usable.
        // Minimized AX windows may temporarily have no desktop membership; the
        // ordinary unminimize path remains authoritative for those windows.
        guard let membership = spaces(id), !membership.isEmpty, let topology = displays() else { return true }
        if !membership.isDisjoint(with: Set(topology.map(\.current))) { return true }
        guard let destination = topology.first(where: { !$0.spaces.isDisjoint(with: membership) }),
              let space = membership.intersection(destination.spaces).sorted().first,
              let selectSpace, !Task.isCancelled, isCurrent() else { return false }
        await willChangeSpace()
        guard !Task.isCancelled, isCurrent() else { return false }
        selectSpace(connection, destination.name as CFString, space)
        // Usually visible immediately; wait only for an actual OS transition.
        // No further focus-changing request is issued by this wait.
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        repeat {
            guard !Task.isCancelled, isCurrent() else { return false }
            if let current = displays(), !membership.isDisjoint(with: Set(current.map(\.current))) { return true }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
        } while ContinuousClock.now < deadline
        return false
    }

    static func resolve(_ id: CGWindowID, pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &result) == .success,
              let windows = result as? [AXUIElement] else { return nil }
        return windows.first { windowID($0) == id }
    }
}
