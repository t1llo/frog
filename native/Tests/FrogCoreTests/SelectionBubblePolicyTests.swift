import XCTest
@testable import FrogCore

final class SelectionBubblePolicyTests: XCTestCase {
    private let options = SelectionBubbleOptions()
    private let fingerprint = SelectionFingerprint(pid: 42, element: 7, location: 3, length: 5, textHash: 99)

    private var ready: BubbleContext {
        BubbleContext(explainEnabled: true, bubbleEnabled: true, writingEnabled: false, accessibilityTrusted: true,
                      frogFrontmost: false, secureInput: false, bundleID: "com.apple.TextEdit", isGame: false, busy: false)
    }

    private func selection(_ text: String = "river bank", fingerprint: SelectionFingerprint? = nil) -> SelectionReadResult {
        let fingerprint = fingerprint ?? self.fingerprint
        return .selection(SelectionSnapshot(text: text, bounds: nil, endBounds: nil, context: nil, source: nil,
                                            isEditable: true, pid: fingerprint.pid, bundleID: nil, applicationName: nil,
                                            fingerprint: fingerprint))
    }

    func testMayReadReportsTheFirstBlockInOrder() {
        var context = ready
        XCTAssertNil(SelectionBubblePolicy.mayRead(context, options: options))
        context.busy = true
        XCTAssertEqual(SelectionBubblePolicy.mayRead(context, options: options), .busy)
        context.isGame = true
        XCTAssertEqual(SelectionBubblePolicy.mayRead(context, options: options), .game)
        context.bundleID = "com.1password.1password"
        XCTAssertEqual(SelectionBubblePolicy.mayRead(context, options: options), .excluded, "excluded wins over game")
        context.secureInput = true
        XCTAssertEqual(SelectionBubblePolicy.mayRead(context, options: options), .secureInput)
        context.frogFrontmost = true
        XCTAssertEqual(SelectionBubblePolicy.mayRead(context, options: options), .frogFrontmost)
        context.accessibilityTrusted = false
        XCTAssertEqual(SelectionBubblePolicy.mayRead(context, options: options), .needsAccessibility)
        context.bubbleEnabled = false
        XCTAssertEqual(SelectionBubblePolicy.mayRead(context, options: options), .off)
        context.bubbleEnabled = true
        context.explainEnabled = false
        context.writingEnabled = true
        XCTAssertEqual(SelectionBubblePolicy.mayRead(context, options: options), .off, "the bubble needs Explain")
    }

    func testExcludedAppsComeFromTheOptions() {
        var context = ready
        var custom = options
        custom.excludedApps = ["com.apple.TextEdit"]
        XCTAssertEqual(SelectionBubblePolicy.mayRead(context, options: custom), .excluded)
        context.bundleID = nil
        XCTAssertNil(SelectionBubblePolicy.mayRead(context, options: custom))
    }

    func testMayShow() {
        func show(_ result: SelectionReadResult, dismissed: SelectionFingerprint? = nil, shown: SelectionFingerprint? = nil,
                  items: Int = 1) -> BubbleBlock? {
            SelectionBubblePolicy.mayShow(result, dismissed: dismissed, shown: shown, itemCount: items)
        }
        XCTAssertNil(show(selection()))
        XCTAssertEqual(show(.secure), .secureField)
        XCTAssertEqual(show(.empty), .empty)
        XCTAssertEqual(show(.unavailable), .empty)
        XCTAssertEqual(show(selection(" \n\t ")), .empty)
        XCTAssertEqual(show(.tooLong(4_001)), .tooLong)
        XCTAssertEqual(show(selection(), dismissed: fingerprint, shown: fingerprint), .dismissedBefore)
        XCTAssertEqual(show(selection(), shown: fingerprint, items: 0), .alreadyShowing)
        XCTAssertEqual(show(selection(), items: 0), .noItems)
        var other = fingerprint
        other.textHash = 100
        XCTAssertNil(show(selection(fingerprint: other), dismissed: fingerprint, shown: fingerprint))
    }

    func testStatus() {
        XCTAssertNil(SelectionBubblePolicy.status(explainEnabled: true, bubbleEnabled: false, accessibilityTrusted: true))
        XCTAssertEqual(SelectionBubblePolicy.status(explainEnabled: false, bubbleEnabled: true, accessibilityTrusted: false),
                       "Turn on Explain to use the selection bubble")
        XCTAssertEqual(SelectionBubblePolicy.status(explainEnabled: true, bubbleEnabled: true, accessibilityTrusted: false),
                       "Needs Accessibility: allow Frog in System Settings → Privacy & Security → Accessibility")
        XCTAssertEqual(SelectionBubblePolicy.status(explainEnabled: true, bubbleEnabled: true, accessibilityTrusted: true),
                       "On: select text in another app to see Explain")
    }

    func testIsGame() {
        XCTAssertTrue(SelectionBubblePolicy.isGame(applicationCategory: "public.app-category.games"))
        XCTAssertTrue(SelectionBubblePolicy.isGame(applicationCategory: "public.app-category.action-games"))
        XCTAssertFalse(SelectionBubblePolicy.isGame(applicationCategory: "public.app-category.productivity"))
        XCTAssertFalse(SelectionBubblePolicy.isGame(applicationCategory: nil))
    }
}
