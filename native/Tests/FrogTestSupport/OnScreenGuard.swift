import AppKit
import ObjectiveC
import XCTest

/// Tests that show windows or bring the test process forward cover the screen and take the keyboard
/// while someone works, so a plain `swift test` keeps them off screen:
///
/// - A test that needs a real window starts with `try requireOnScreen()` and is skipped unless
///   `FROG_ON_SCREEN_TESTS=1` is set (CI and the release script set it).
/// - Without that variable, every other test is guarded: showing a window or activating the app
///   does nothing and fails the test, naming it, so a new test can't slip onto the screen.
public enum OnScreenTests {
    public static let variable = "FROG_ON_SCREEN_TESTS"
    public static var enabled: Bool { ProcessInfo.processInfo.environment[variable] == "1" }
    /// Picture and fixture runs someone asks for by name draw or show windows on purpose.
    static let pictureVariables = ["FROG_UI_SHOTS", "FROG_PAGE_SHOTS", "FROG_SURFACE_SHOTS", "FROG_BUBBLE_SHOTS", "FROG_RUN_SPACE_FIXTURE"]
    static var guarded: Bool {
        let environment = ProcessInfo.processInfo.environment
        return !enabled && !pictureVariables.contains { environment[$0] != nil }
    }
}

extension XCTestCase {
    /// Skips this test unless on-screen tests are turned on. Call it before the test shows anything.
    public func requireOnScreen() throws {
        guard OnScreenTests.enabled else {
            throw XCTSkip("Shows windows on screen; set \(OnScreenTests.variable)=1 to run it")
        }
    }
}

@_cdecl("frog_test_boot")
public func frogTestBoot() {
    guard OnScreenTests.guarded else { return }
    OnScreenGuard.install()
}

private final class OnScreenGuard: NSObject, XCTestObservation {
    nonisolated(unsafe) static var current: XCTestCase?
    nonisolated(unsafe) static var reported = false

    static func install() {
        let block: @convention(block) (AnyObject, AnyObject?) -> Void = { _, _ in caught("shows a window") }
        let blockPlain: @convention(block) (AnyObject) -> Void = { _ in caught("shows a window") }
        let blockOrder: @convention(block) (AnyObject, Int, Int) -> Void = { _, place, _ in
            if place != NSWindow.OrderingMode.out.rawValue { caught("shows a window") }
        }
        let activate: @convention(block) (AnyObject, Bool) -> Void = { _, _ in caught("brings the test process forward") }
        let activatePlain: @convention(block) (AnyObject) -> Void = { _ in caught("brings the test process forward") }

        replace(NSWindow.self, "orderFront:", block)
        replace(NSWindow.self, "makeKeyAndOrderFront:", block)
        replace(NSWindow.self, "orderFrontRegardless", blockPlain)
        replace(NSWindow.self, "orderWindow:relativeTo:", blockOrder)
        replace(NSApplication.self, "activateIgnoringOtherApps:", activate)
        replace(NSApplication.self, "activate", activatePlain)

        // `isVisible = true` orders the window in too; hiding still works.
        if let method = class_getInstanceMethod(NSWindow.self, NSSelectorFromString("setIsVisible:")) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Setter.self)
            let visible: @convention(block) (AnyObject, Bool) -> Void = { window, show in
                if show { caught("shows a window") } else { original(window, NSSelectorFromString("setIsVisible:"), false) }
            }
            method_setImplementation(method, imp_implementationWithBlock(visible))
        }
        XCTestObservationCenter.shared.addTestObserver(OnScreenGuard())
    }

    private static func replace(_ type: AnyClass, _ name: String, _ block: Any) {
        guard let method = class_getInstanceMethod(type, NSSelectorFromString(name)) else { return }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func caught(_ what: String) {
        guard let test = current, !reported else { return }
        reported = true
        test.record(XCTIssue(type: .assertionFailure, compactDescription:
            "This test \(what). Start it with `try requireOnScreen()` so a plain `swift test` keeps it off screen."))
    }

    func testCaseWillStart(_ testCase: XCTestCase) { Self.current = testCase; Self.reported = false }
    func testCaseDidFinish(_ testCase: XCTestCase) { Self.current = nil }
}
