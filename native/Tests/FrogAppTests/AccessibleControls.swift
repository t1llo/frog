import AppKit
import XCTest

/// Finds SwiftUI controls the way VoiceOver does, by their label in the accessibility tree, so a test clicks the
/// control itself rather than a point that moves whenever the layout does.
@MainActor
enum AccessibleControls {
    /// One element of the tree. SwiftUI's elements answer the accessibility methods without declaring
    /// `NSAccessibilityProtocol`, so they are read by name.
    struct Element {
        let object: NSObject
        var role: String? { read("accessibilityRole") as? String }
        var label: String? { read("accessibilityLabel") as? String }
        var title: String? { read("accessibilityTitle") as? String }
        /// In screen coordinates.
        var frame: NSRect { (read("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
        var children: [Element] {
            ((read("accessibilityChildren") as? [Any]) ?? []).compactMap { ($0 as? NSObject).map(Element.init) }
        }
        /// Asks only what the element answers: an unknown key would raise an Objective-C exception.
        private func read(_ key: String) -> Any? {
            object.responds(to: Selector(key)) ? object.value(forKey: key) : nil
        }
    }

    /// SwiftUI builds its accessibility tree only once an assistive app asks for it, as VoiceOver or a window
    /// manager does by turning on the enhanced interface. The setting lasts for this test process only.
    static func enable() {
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    }

    /// Every element under `view`, depth first in reading order.
    static func elements(in view: NSView) -> [Element] {
        func walk(_ element: Element) -> [Element] { element.children.flatMap { [$0] + walk($0) } }
        return walk(Element(object: view))
    }

    /// The first element under `view` whose label or title is `label`, waiting up to a second for the tree to
    /// be built. `role` tells a control from the row title that names it.
    static func element(_ label: String, role: NSAccessibility.Role? = nil, in view: NSView) async throws -> Element? {
        enable()
        for _ in 0..<10 {
            if let found = first(label, role: role, in: view) { return found }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private static func first(_ label: String, role: NSAccessibility.Role?, in view: NSView) -> Element? {
        elements(in: view).first { ($0.label == label || $0.title == label) && (role == nil || $0.role == role?.rawValue) }
    }

    /// The element labelled `label`, failing the test when there is none.
    static func require(_ label: String, role: NSAccessibility.Role? = nil, in view: NSView) async throws -> Element {
        let found = try await element(label, role: role, in: view)
        let named = elements(in: view).compactMap { $0.label ?? $0.title }
        return try XCTUnwrap(found, "No control labelled \(label) among: \(named.joined(separator: ", "))")
    }

    /// The element's frame in `view`'s coordinates.
    static func frame(of element: Element, in view: NSView) throws -> NSRect {
        let window = try XCTUnwrap(view.window)
        return view.convert(window.convertFromScreen(element.frame), from: nil)
    }

    /// Clicks the centre of the element labelled `label` with a mouse down and up, as a person would.
    static func click(_ label: String, role: NSAccessibility.Role? = nil, in view: NSView) async throws {
        let element = try await require(label, role: role, in: view)
        let window = try XCTUnwrap(view.window)
        let frame = try frame(of: element, in: view)
        let point = view.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
        try await Task.sleep(for: .milliseconds(150))
    }
}
