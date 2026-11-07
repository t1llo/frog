import CoreGraphics
import XCTest
@testable import FrogCore

final class PanelFamilyPlacementTests: XCTestCase {
    typealias P = PanelFamilyPlacement
    // A laptop with the menu bar, and a larger display to its right, lower down.
    let laptop = P.Display(id: "laptop", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949))
    let external = P.Display(id: "external", frame: CGRect(x: 1512, y: -300, width: 1920, height: 1080),
                             visibleFrame: CGRect(x: 1512, y: -300, width: 1920, height: 1055))
    var displays: [P.Display] { [laptop, external] }
    let bar = CGSize(width: P.width, height: P.height)
    let switcher = CGSize(width: P.width, height: 270)

    func testEveryPanelHangsFromTheSameTopCentreOnTheDisplayUnderThePointer() throws {
        let tall = try XCTUnwrap(P.opening(size: bar, pointer: CGPoint(x: 700, y: 400), displays: displays, memory: .init()))
        let short = try XCTUnwrap(P.opening(size: switcher, pointer: CGPoint(x: 700, y: 400), displays: displays, memory: .init()))
        XCTAssertEqual(tall.maxY, short.maxY, "One top edge")
        XCTAssertEqual(tall.midX, short.midX, "One centre line")
        XCTAssertEqual(tall.midX, laptop.visibleFrame.midX)
        // Two fifths of the free height above the tallest panel, three below.
        XCTAssertEqual(laptop.visibleFrame.maxY - tall.maxY, ((949 - 460) * 0.4).rounded())
        let there = try XCTUnwrap(P.opening(size: bar, pointer: CGPoint(x: 2000, y: 100), displays: displays, memory: .init()))
        XCTAssertTrue(external.visibleFrame.contains(there), "Opens on the display with the pointer")
        XCTAssertEqual(there.midX, external.visibleFrame.midX)
    }

    func testADragIsRememberedForItsDisplayOnlyAndReopensThere() throws {
        let opened = try XCTUnwrap(P.opening(size: bar, pointer: CGPoint(x: 700, y: 400), displays: displays, memory: .init()))
        let dropped = opened.offsetBy(dx: 200, dy: -120)
        let drag = P.finishDrag(dropped, displays: displays, memory: .init())
        XCTAssertTrue(drag.placed)
        XCTAssertEqual(drag.frame, dropped)
        XCTAssertNotNil(drag.memory.displays["laptop"])
        XCTAssertNil(drag.memory.displays["external"])
        // The other panels of the family reopen at the same top centre.
        let reopened = try XCTUnwrap(P.opening(size: switcher, pointer: CGPoint(x: 10, y: 10), displays: displays, memory: drag.memory))
        XCTAssertEqual(reopened.maxY, dropped.maxY)
        XCTAssertEqual(reopened.midX, dropped.midX)
        // The external display keeps its default place.
        let there = try XCTUnwrap(P.opening(size: bar, pointer: CGPoint(x: 2000, y: 100), displays: displays, memory: drag.memory))
        XCTAssertEqual(there.midX, external.visibleFrame.midX)
        XCTAssertTrue(P.isPlaced(dropped, displays: displays, memory: drag.memory))
        XCTAssertFalse(P.isPlaced(there, displays: displays, memory: drag.memory))
    }

    func testTheMemorySurvivesEncoding() throws {
        let memory = P.Memory(displays: ["laptop": .init(x: 300, top: 120)])
        let decoded = try JSONDecoder().decode(P.Memory.self, from: JSONEncoder().encode(memory))
        XCTAssertEqual(decoded, memory)
    }

    func testDraggingBackNearTheDefaultPlaceSnapsHomeAndForgets() throws {
        let opened = try XCTUnwrap(P.opening(size: bar, pointer: CGPoint(x: 700, y: 400), displays: displays, memory: .init()))
        let placed = P.finishDrag(opened.offsetBy(dx: 300, dy: 50), displays: displays, memory: .init())
        let back = P.finishDrag(opened.offsetBy(dx: 10, dy: -14), displays: displays, memory: placed.memory)
        XCTAssertFalse(back.placed)
        XCTAssertEqual(back.frame, opened, "Snapped to the default place")
        XCTAssertNil(back.memory.displays["laptop"])
    }

    func testResetForgetsTheDisplaysSpot() throws {
        let opened = try XCTUnwrap(P.opening(size: bar, pointer: CGPoint(x: 700, y: 400), displays: displays, memory: .init()))
        let placed = P.finishDrag(opened.offsetBy(dx: -400, dy: -200), displays: displays, memory: .init())
        let reset = P.reset(placed.frame, displays: displays, memory: placed.memory)
        XCTAssertEqual(reset.frame, opened)
        XCTAssertEqual(reset.memory, .init())
    }

    func testARememberedPlaceStaysOnScreen() throws {
        // Dragged half off the bottom right of the laptop's display.
        let half = CGRect(x: 1300, y: -200, width: P.width, height: P.height)
        let drag = P.finishDrag(half, displays: [laptop], memory: .init())
        XCTAssertTrue(laptop.visibleFrame.contains(drag.frame), "Kept wholly on screen")
        // A spot that a smaller display can't show, such as one taken at a larger resolution, is clamped onto it.
        let far = P.Memory(displays: ["laptop": .init(x: 3000, top: 2000)])
        let opened = try XCTUnwrap(P.opening(size: bar, pointer: CGPoint(x: 700, y: 400), displays: [laptop], memory: far))
        XCTAssertTrue(laptop.visibleFrame.insetBy(dx: P.margin, dy: P.margin).contains(opened))
        // A disconnected display's spot is kept for when it comes back, and does not move the others.
        let gone = P.Memory(displays: ["external": .init(x: 10, top: 10)])
        let here = try XCTUnwrap(P.opening(size: bar, pointer: CGPoint(x: 2000, y: 100), displays: [laptop], memory: gone))
        XCTAssertEqual(here.midX, laptop.visibleFrame.midX, "The pointer's display is gone: the primary display, at its default place")
    }

    func testGrowingAndShrinkingKeepsTheTopEdge() throws {
        let opened = try XCTUnwrap(P.opening(size: switcher, pointer: CGPoint(x: 700, y: 400), displays: displays, memory: .init()))
        let taller = P.resized(opened, to: CGSize(width: P.width, height: 400), displays: displays)
        XCTAssertEqual(taller.maxY, opened.maxY)
        XCTAssertEqual(taller.midX, opened.midX)
        XCTAssertEqual(taller.height, 400)
        // Near the bottom of the display the panel moves up rather than run off it.
        let low = CGRect(x: 400, y: 20, width: P.width, height: 200)
        XCTAssertEqual(P.resized(low, to: CGSize(width: P.width, height: 400), displays: displays).minY, P.margin)
    }

    func testAShortDisplayKeepsTheSearchLineReachable() {
        let tiny = CGRect(x: 0, y: 0, width: 800, height: 400)
        let frame = P.frame(size: bar, hangingFrom: P.defaultTopCentre(in: tiny), in: tiny)
        XCTAssertEqual(frame.maxY, tiny.maxY - P.margin, "Taller than the display: the top edge stays inside it")
    }

    func testTheDisplayADragEndsOnIsTheOneShowingMostOfThePanel() {
        let straddling = CGRect(x: 1400, y: 300, width: P.width, height: P.height)
        XCTAssertEqual(P.display(holding: straddling, in: displays)?.id, "external")
        XCTAssertEqual(P.display(holding: CGRect(x: 1000, y: 300, width: P.width, height: P.height), in: displays)?.id, "laptop")
    }
}
