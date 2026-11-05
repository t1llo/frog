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
        XCTAssertEqual(SelectionBubblePolicy.mayRead(context, options: options), .needsAccessibility,
                       "Writing rules alone give the bubble something to show")
        context.writingEnabled = false
        XCTAssertEqual(SelectionBubblePolicy.mayRead(context, options: options), .off)
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

    func testTheSelectionOfferedLastNeedsToBeSelectedAgain() {
        func show(offered: SelectionFingerprint?, reselected: Bool, fingerprint: SelectionFingerprint? = nil,
                  shown: SelectionFingerprint? = nil, items: Int = 1) -> BubbleBlock? {
            SelectionBubblePolicy.mayShow(selection(fingerprint: fingerprint), dismissed: nil, shown: shown, offered: offered,
                                          reselected: reselected, itemCount: items)
        }
        XCTAssertEqual(show(offered: fingerprint, reselected: false), .unchanged)
        XCTAssertNil(show(offered: fingerprint, reselected: true))
        XCTAssertNil(show(offered: nil, reselected: false), "A selection never offered shows")
        var other = fingerprint
        other.location = 9
        XCTAssertNil(show(offered: fingerprint, reselected: false, fingerprint: other), "Another selection shows")
        XCTAssertEqual(show(offered: fingerprint, reselected: false, shown: fingerprint), .alreadyShowing,
                       "While it shows, it stays")
        XCTAssertEqual(show(offered: fingerprint, reselected: false, items: 0), .unchanged)
    }

    func testAGestureSelectsAgainWhenItEndsOnItsSelectionOrIsNoShortcut() {
        func reselects(_ pointer: CGPoint?, afterShortcut: Bool = false, bounds: CGRect?, endBounds: CGRect?) -> Bool {
            SelectionBubblePolicy.reselects(pointer: pointer, afterShortcut: afterShortcut, bounds: bounds, endBounds: endBounds)
        }
        let word = CGRect(x: 100, y: 500, width: 40, height: 16)
        let last = CGRect(x: 132, y: 500, width: 8, height: 16)
        XCTAssertTrue(reselects(CGPoint(x: 120, y: 508), bounds: word, endBounds: last))
        XCTAssertTrue(reselects(CGPoint(x: 160, y: 490), bounds: word, endBounds: last), "A drag that ends just past the text")
        XCTAssertFalse(reselects(CGPoint(x: 400, y: 880), bounds: word, endBounds: last), "The title bar of a window being dragged")
        XCTAssertFalse(reselects(CGPoint(x: 400, y: 880), afterShortcut: true, bounds: word, endBounds: last))
        XCTAssertTrue(reselects(CGPoint(x: 136, y: 508), bounds: nil, endBounds: last))
        XCTAssertTrue(reselects(CGPoint(x: 400, y: 880), bounds: nil, endBounds: nil), "Without a rectangle a mouse gesture counts")
        XCTAssertTrue(reselects(nil, bounds: word, endBounds: last), "Shift and the arrow keys")
        XCTAssertTrue(reselects(nil, bounds: nil, endBounds: nil))
        XCTAssertFalse(reselects(nil, afterShortcut: true, bounds: word, endBounds: last), "A shortcut such as ⇧⌘T")
        XCTAssertFalse(reselects(nil, afterShortcut: true, bounds: nil, endBounds: nil))
    }

    func testStatus() {
        XCTAssertNil(SelectionBubblePolicy.status(bubbleEnabled: false, accessibilityTrusted: false))
        XCTAssertEqual(SelectionBubblePolicy.status(bubbleEnabled: true, accessibilityTrusted: false),
                       "Needs Accessibility to see what you select")
        XCTAssertNil(SelectionBubblePolicy.status(bubbleEnabled: true, accessibilityTrusted: true),
                     "the switch already says the bubble is on")
    }

    func testEditorsBuiltOnVSCodeAreNeverOfferedWithoutText() {
        for id in ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
                   "com.exafunction.windsurf", "com.vscodium"] {
            XCTAssertFalse(SelectionBubblePolicy.offersWithoutText(bundleID: id, builtOnVSCode: false), id)
        }
        XCTAssertFalse(SelectionBubblePolicy.offersWithoutText(bundleID: "com.example.fork", builtOnVSCode: true))
        XCTAssertFalse(SelectionBubblePolicy.offersWithoutText(bundleID: nil, builtOnVSCode: true))
        XCTAssertTrue(SelectionBubblePolicy.offersWithoutText(bundleID: "com.tinyspeck.slackmacgap", builtOnVSCode: false))
        XCTAssertTrue(SelectionBubblePolicy.offersWithoutText(bundleID: "com.google.Chrome", builtOnVSCode: false))
        XCTAssertTrue(SelectionBubblePolicy.offersWithoutText(bundleID: nil, builtOnVSCode: false))
    }

    func testWithoutTextTheGestureMustEndInsideAWindowBelowItsTitleBarAndLeftOfItsScrollBar() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertNil(SelectionBubblePolicy.mayOfferWithoutText(pointer: CGPoint(x: 400, y: 400), window: window))
        XCTAssertEqual(SelectionBubblePolicy.mayOfferWithoutText(pointer: CGPoint(x: 400, y: 680), window: window),
                       .windowChrome, "The tabs of a window being dragged")
        XCTAssertEqual(SelectionBubblePolicy.mayOfferWithoutText(pointer: CGPoint(x: 890, y: 400), window: window),
                       .windowChrome, "The scroll bar")
        XCTAssertEqual(SelectionBubblePolicy.mayOfferWithoutText(pointer: CGPoint(x: 50, y: 400), window: window), .noPosition)
        XCTAssertEqual(SelectionBubblePolicy.mayOfferWithoutText(pointer: CGPoint(x: 400, y: 400), window: nil), .noPosition)
        XCTAssertEqual(SelectionBubblePolicy.mayOfferWithoutText(pointer: nil, window: window), .noPosition, "Shift and the arrow keys")
    }

    func testIsGame() {
        XCTAssertTrue(SelectionBubblePolicy.isGame(applicationCategory: "public.app-category.games"))
        XCTAssertTrue(SelectionBubblePolicy.isGame(applicationCategory: "public.app-category.action-games"))
        XCTAssertFalse(SelectionBubblePolicy.isGame(applicationCategory: "public.app-category.productivity"))
        XCTAssertFalse(SelectionBubblePolicy.isGame(applicationCategory: nil))
    }

    func testNoBubbleWithoutTextByDefault() {
        XCTAssertFalse(SelectionBubbleOptions().chromiumApps)
    }

    func testOneCharacterOrOnlyPunctuationIsTooShort() {
        func show(_ text: String) -> BubbleBlock? {
            SelectionBubblePolicy.mayShow(selection(text), dismissed: nil, shown: nil, itemCount: 1)
        }
        XCTAssertEqual(show("a"), .tooShort)
        XCTAssertEqual(show(" a \n"), .tooShort)
        XCTAssertEqual(show("..."), .tooShort)
        XCTAssertEqual(show("- ("), .tooShort)
        XCTAssertEqual(show("   "), .empty)
        XCTAssertNil(show("ok"))
        XCTAssertNil(show("42"))
        XCTAssertNil(show("a.b"))
    }

    func testAGestureMustBeginOnTextNotOnAControlOrAWindowPart() {
        func block(_ role: String?, _ ancestors: [String] = []) -> BubbleBlock? {
            SelectionBubblePolicy.mayStartSelection(on: role.map { PointElement(role: $0, ancestors: ancestors) })
        }
        XCTAssertNil(SelectionBubblePolicy.mayStartSelection(on: nil), "Unknown: the text decides")
        for role in ["AXScrollBar", "AXSlider", "AXButton", "AXRadioButton", "AXImage", "AXWindow", "AXMenuItem", "AXToolbar"] {
            XCTAssertEqual(block(role, ["AXWebArea"]), .notText, role)
        }
        XCTAssertNil(block("AXTextArea", ["AXScrollArea", "AXWindow"]))
        XCTAssertNil(block("AXTextField", ["AXToolbar", "AXWindow"]), "A search field in a toolbar")
        XCTAssertNil(block("AXTextField", ["AXCell", "AXRow", "AXOutline"]), "A file being renamed")
        XCTAssertNil(block("AXStaticText", ["AXGroup", "AXScrollArea", "AXWindow"]))
        XCTAssertNil(block("AXWebArea"))
        XCTAssertNil(block("AXStaticText", ["AXCell", "AXRow", "AXTable", "AXGroup", "AXWebArea"]), "A table in a web page")
        XCTAssertNil(block("AXLink", ["AXGroup", "AXWebArea"]))
        XCTAssertEqual(block("AXStaticText", ["AXCell", "AXRow", "AXOutline", "AXScrollArea", "AXWindow"]), .notText, "A file list")
        XCTAssertEqual(block("AXStaticText", ["AXGroup", "AXToolbar", "AXWindow"]), .notText)
        XCTAssertEqual(block("AXGroup", ["AXTabGroup", "AXWindow"]), .notText)
    }

    func testWithoutTextOnlyADragOrDoubleClickInsideTheContentCounts() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        let inside = CGPoint(x: 400, y: 400)
        func offer(_ start: CGPoint?, _ gesture: SelectionGesture, to end: CGPoint = CGPoint(x: 600, y: 400)) -> BubbleBlock? {
            SelectionBubblePolicy.mayOfferWithoutText(pointer: end, window: window, start: start, gesture: gesture)
        }
        XCTAssertNil(offer(inside, .drag))
        XCTAssertNil(offer(inside, .doubleClick, to: inside))
        XCTAssertNil(offer(inside, .tripleClick, to: inside))
        XCTAssertEqual(offer(inside, .shiftClick), .noPosition)
        XCTAssertEqual(offer(inside, .keyboard), .noPosition)
        XCTAssertEqual(offer(CGPoint(x: 400, y: 690), .drag), .windowChrome, "A drag that began on the tabs moves the window")
        XCTAssertEqual(offer(CGPoint(x: 895, y: 400), .drag), .windowChrome, "A drag that began on the scroll bar")
        XCTAssertEqual(offer(CGPoint(x: 50, y: 400), .drag), .windowChrome, "Began outside the window")
        XCTAssertEqual(offer(inside, .drag, to: CGPoint(x: 405, y: 405)), .tooShort, "A slipped click")
    }

    func testAGestureBeginningOnTheSelectionCountsAsSelectingIt() {
        let word = CGRect(x: 100, y: 500, width: 40, height: 16)
        XCTAssertTrue(SelectionBubblePolicy.reselects(pointer: CGPoint(x: 400, y: 100), start: CGPoint(x: 110, y: 508),
                                                      afterShortcut: false, bounds: word, endBounds: word))
        XCTAssertFalse(SelectionBubblePolicy.reselects(pointer: CGPoint(x: 400, y: 100), start: CGPoint(x: 300, y: 100),
                                                       afterShortcut: false, bounds: word, endBounds: word))
    }

    func testOnlyNavigationKeysWithShiftEndAKeyboardSelection() {
        var keys = ShiftKeys()
        XCTAssertFalse(keys.endsSelection, "Shift alone")
        keys.pressed(keyCode: 124)
        XCTAssertTrue(keys.endsSelection, "Shift and the right arrow")
        keys.pressed(keyCode: 0)
        XCTAssertFalse(keys.endsSelection, "Typing in between")
        var typed = ShiftKeys()
        typed.pressed(keyCode: 17)
        XCTAssertFalse(typed.endsSelection, "A capital letter or a shortcut")
        for code in [UInt16]([123, 124, 125, 126, 115, 119, 116, 121]) { XCTAssertTrue(ShiftKeys.extendsSelection(keyCode: code)) }
        XCTAssertFalse(ShiftKeys.extendsSelection(keyCode: 36), "Return")
    }
}
