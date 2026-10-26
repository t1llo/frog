import XCTest
@testable import FrogCore

final class SidebarArrangementTests: XCTestCase {
    private let catalog = FeatureID.allCases

    func testTheCatalogOrderIsTheDefaultAndStoresNothing() {
        let arrangement = SidebarArrangement(order: [], pinned: [])
        XCTAssertEqual(arrangement.order, catalog)
        XCTAssertEqual(arrangement.storedOrder, [])
        XCTAssertFalse(arrangement.isCustom)
        XCTAssertEqual(arrangement.shown(catalog), catalog)
    }

    func testAFeatureMissingFromTheStoredOrderFollowsItsCatalogPredecessor() throws {
        let stored = catalog.filter { $0 != .usage }.reversed().map(\.rawValue)
        let arrangement = SidebarArrangement(order: stored + ["unknown", "clipboard"], pinned: ["unknown"])
        let index = try XCTUnwrap(arrangement.order.firstIndex(of: .usage))
        let predecessor = catalog[try XCTUnwrap(catalog.firstIndex(of: .usage)) - 1]
        XCTAssertEqual(arrangement.order[index - 1], predecessor)
        XCTAssertEqual(Set(arrangement.order), Set(catalog))
        XCTAssertEqual(arrangement.order.count, catalog.count)
        XCTAssertTrue(arrangement.pinned.isEmpty)
    }

    func testPinnedFeaturesComeFirstAndUnpinningKeepsTheirPlace() {
        var arrangement = SidebarArrangement(order: [], pinned: [])
        arrangement.setPinned(.usage, true)
        XCTAssertEqual(arrangement.shown(catalog).first, .usage)
        XCTAssertTrue(arrangement.isCustom)
        XCTAssertEqual(arrangement.storedPinned, ["usage"])
        arrangement.setPinned(.usage, false)
        XCTAssertEqual(arrangement.shown(catalog), catalog)
        XCTAssertFalse(arrangement.isCustom)
    }

    func testDroppingAmongPinnedFeaturesPinsAndAmongTheOthersUnpins() {
        var arrangement = SidebarArrangement(order: [], pinned: [FeatureID.scripts.rawValue])
        var shown = arrangement.shown(catalog)
        XCTAssertEqual(shown.first, .scripts)

        // Dropped above the pinned feature, it joins the pinned group.
        arrangement.move(.usage, to: 0, in: shown)
        shown = arrangement.shown(catalog)
        XCTAssertEqual(Array(shown.prefix(2)), [.usage, .scripts])
        XCTAssertEqual(arrangement.pinned, [.usage, .scripts])

        // Dropped at the end, it leaves the group.
        arrangement.move(.scripts, to: shown.count, in: shown)
        shown = arrangement.shown(catalog)
        XCTAssertEqual(shown.last, .scripts)
        XCTAssertEqual(arrangement.pinned, [.usage])

        // On the line between the groups it keeps what it was.
        let other = shown[shown.count - 2]
        arrangement.move(other, to: 1, in: shown)
        XCTAssertFalse(arrangement.pinned.contains(other))
        XCTAssertEqual(arrangement.shown(catalog)[1], other)
    }

    func testMovingWithinTheOthersReordersThemAndSurvivesStorage() {
        var arrangement = SidebarArrangement(order: [], pinned: [])
        let shown = arrangement.shown(catalog)
        arrangement.move(shown[0], to: 3, in: shown)
        let expected = [shown[1], shown[2], shown[0]] + shown.dropFirst(3)
        XCTAssertEqual(arrangement.shown(catalog), expected)
        let restored = SidebarArrangement(order: arrangement.storedOrder, pinned: arrangement.storedPinned)
        XCTAssertEqual(restored, arrangement)
    }

    func testAHiddenFeatureKeepsItsPlaceWhenARowMovesPastIt() {
        var arrangement = SidebarArrangement(order: [], pinned: [])
        let visible = catalog.filter { $0 != catalog[1] }
        arrangement.move(catalog[0], to: 2, in: arrangement.shown(visible))
        XCTAssertEqual(arrangement.shown(visible), [visible[1], visible[0]] + visible.dropFirst(2))
        XCTAssertEqual(Set(arrangement.order), Set(catalog))
    }

    func testMoveUpAndDownStayInsideTheGroup() {
        var arrangement = SidebarArrangement(order: [], pinned: [FeatureID.usage.rawValue])
        let shown = arrangement.shown(catalog)
        XCTAssertFalse(arrangement.canMove(.usage, by: 1, in: shown))
        XCTAssertFalse(arrangement.canMove(.usage, by: -1, in: shown))
        XCTAssertFalse(arrangement.canMove(shown[1], by: -1, in: shown))
        XCTAssertTrue(arrangement.canMove(shown[1], by: 1, in: shown))
        XCTAssertFalse(arrangement.canMove(shown[shown.count - 1], by: 1, in: shown))

        arrangement.move(shown[1], by: 1, in: shown)
        XCTAssertEqual(Array(arrangement.shown(catalog).prefix(3)), [.usage, shown[2], shown[1]])
        let next = arrangement.shown(catalog)
        arrangement.move(next[2], by: -1, in: next)
        XCTAssertEqual(arrangement.shown(catalog), shown)
    }

    func testTheSidebarListsPinnedFeaturesFirst() {
        var preferences = Preferences()
        preferences.setFeature(.usage, enabled: true)
        var toolkit = preferences.toolkitSettings
        toolkit.pinnedSidebarItems = [FeatureID.usage.rawValue]
        preferences.toolkit = toolkit
        XCTAssertEqual(preferences.sidebarFeatures.first, .usage)
    }
}
