import ApplicationServices
import XCTest
@testable import FrogApp

@MainActor
final class MenuCommandTests: XCTestCase {
    // Plain identities; nothing is asked of these processes.
    private let copy = AXUIElementCreateApplication(900_101)
    private let paste = AXUIElementCreateApplication(900_102)

    func testOneSelectionWalksTheMenuBarOncePerCommand() {
        var walks: [String] = []
        let menu = MenuCommandCache(find: { walks.append($0); return $0 == "c" ? self.copy : self.paste },
                                    matches: { _, _ in true })
        // One rule run asks for Copy twice and for Paste up to three times.
        for character in ["c", "v", "c", "v", "v"] {
            XCTAssertTrue(menu.item(character).map { CFEqual($0, character == "c" ? copy : paste) } ?? false)
        }
        XCTAssertEqual(walks, ["c", "v"])
    }

    func testRememberedItemIsCheckedAgainstItsOwnCommand() {
        var checked: [String] = []
        let menu = MenuCommandCache(find: { $0 == "c" ? self.copy : self.paste },
                                    matches: { item, character in
                                        checked.append(character + (CFEqual(item, self.copy) ? ":copy" : ":paste"))
                                        return true
                                    })
        _ = menu.item("c"); _ = menu.item("v")
        XCTAssertEqual(checked, [], "A freshly found item needs no second check")
        _ = menu.item("v"); _ = menu.item("c")
        XCTAssertEqual(checked, ["v:paste", "c:copy"])
    }

    func testDisabledOrReplacedItemIsLookedUpAgain() {
        var walks = 0
        var matches = true
        let menu = MenuCommandCache(find: { _ in walks += 1; return walks == 1 ? self.paste : self.copy },
                                    matches: { _, _ in matches })
        XCTAssertTrue(menu.item("v").map { CFEqual($0, paste) } ?? false)
        // The app disabled the item, or rebuilt its menu so that it is another command now.
        matches = false
        XCTAssertTrue(menu.item("v").map { CFEqual($0, copy) } ?? false,
                      "A remembered item that no longer is the command must not stand in for a fresh search")
        XCTAssertEqual(walks, 2)
    }

    func testMissingCommandIsSearchedAgainNextTime() {
        var walks = 0
        let menu = MenuCommandCache(find: { _ in walks += 1; return walks == 1 ? nil : self.paste },
                                    matches: { _, _ in true })
        XCTAssertNil(menu.item("v"))
        XCTAssertTrue(menu.item("v").map { CFEqual($0, paste) } ?? false)
        XCTAssertTrue(menu.item("v").map { CFEqual($0, paste) } ?? false)
        XCTAssertEqual(walks, 2)
    }
}

/// The search runs against a plain tree here; the app asks another process the same questions.
final class MenuCommandSearchTests: XCTestCase {
    private final class Node {
        let name: String
        let role: String
        let character: String?
        let modifiers: Int?
        let enabled: Bool
        let children: [Node]

        init(_ name: String, role: String = kAXMenuItemRole, character: String? = nil, modifiers: Int? = 0,
             enabled: Bool = true, children: [Node] = []) {
            self.name = name; self.role = role; self.character = character; self.modifiers = modifiers
            self.enabled = enabled; self.children = children
        }
    }

    private var read: [String] = []

    private var reader: MenuCommandSearch.Reader<Node> {
        .init(prepare: { [unowned self] in self.read.append($0.name) }, role: { $0.role },
              character: { $0.character }, modifiers: { $0.modifiers }, enabled: { $0.enabled },
              children: { $0.children })
    }

    /// A menu bar item that opens one menu holding `items`.
    private func menu(_ name: String, _ items: [Node]) -> Node {
        Node(name, role: kAXMenuBarItemRole, children: [Node(name + " menu", role: kAXMenuRole, children: items)])
    }

    private func bar(_ menus: [Node]) -> Node { Node("bar", role: kAXMenuBarRole, children: menus) }

    private func filler(_ name: String, count: Int) -> [Node] {
        (0..<count).map { Node("\(name) \($0)", character: "y") }
    }

    private func find(_ character: String, modifiers: Int = 0, in root: Node, depth: Int = 5,
                      now: () -> TimeInterval = { 0 }, isCancelled: () -> Bool = { false }) -> Node? {
        MenuCommandSearch.find(character: character, modifiers: modifiers, under: root, depth: depth,
                               reader: reader, now: now, isCancelled: isCancelled)
    }

    func testPasteInTheFourthOfTenMenusIsFoundDespiteLargeMenusToItsRight() {
        // Apple, app, File, Edit, then six menus that together exceed the element budget.
        var menus = ["Apple", "App", "File"].map { menu($0, filler($0, count: 12)) }
        menus.append(menu("Edit", filler("Edit", count: 4) + [Node("Paste", character: "V")]))
        menus += (5...10).map { menu("Menu \($0)", filler("Menu \($0)", count: 200)) }

        XCTAssertEqual(find("v", in: bar(menus))?.name, "Paste")
        XCTAssertLessThan(read.count, 60, "Menus to the right of Edit must not be read before it")
        XCTAssertFalse(read.contains { $0.hasPrefix("Menu ") })
    }

    func testFirstMatchInVisibleOrderWins() {
        let tree = bar([
            menu("File", [Node("Other", character: "n")]),
            menu("Edit", [Node("Submenu", children: [Node("Inner menu", role: kAXMenuRole, children: [Node("Nested", character: "v")])]),
                          Node("Second", character: "v")]),
            menu("View", [Node("Third", character: "v")])
        ])
        XCTAssertEqual(find("v", in: tree)?.name, "Nested")
    }

    func testDisabledItemsAndOtherModifiersAreNotTheCommand() {
        let tree = bar([menu("Edit", [
            Node("Disabled Paste", character: "v", enabled: false),
            Node("Paste and Match Style", character: "v", modifiers: 3),
            Node("No modifiers reported", character: "v", modifiers: nil),
            Node("Not an item", role: kAXMenuRole, character: "v")
        ])])
        XCTAssertNil(find("v", in: tree))
        XCTAssertEqual(find("v", modifiers: 3, in: tree)?.name, "Paste and Match Style")
    }

    func testSearchGivesUpAtItsDeadline() {
        let tree = bar([menu("File", filler("File", count: 100)), menu("Edit", [Node("Paste", character: "v")])])
        var clock: TimeInterval = 0
        // Every element costs a tenth of a second against a budget of one and a half.
        XCTAssertNil(find("v", in: tree, now: { clock += 0.1; return clock }))
        XCTAssertLessThanOrEqual(read.count, 15)
        XCTAssertFalse(read.isEmpty)
    }

    func testSearchStopsAfterAThousandElements() {
        let tree = bar((1...6).map { menu("Menu \($0)", filler("Menu \($0)", count: 200)) }
                       + [menu("Last", [Node("Paste", character: "v")])])
        XCTAssertNil(find("v", in: tree))
        XCTAssertEqual(read.count, 1_000)
    }

    func testSearchDoesNotLookBelowItsDepth() {
        let tree = bar([menu("Edit", [Node("Paste", character: "v")])])
        XCTAssertNil(find("v", in: tree, depth: 2))
        XCTAssertEqual(find("v", in: tree, depth: 3)?.name, "Paste")
    }

    func testCancelledSearchReadsNothing() {
        let tree = bar([menu("Edit", [Node("Paste", character: "v")])])
        XCTAssertNil(find("v", in: tree, isCancelled: { true }))
        XCTAssertEqual(read, [])
    }

    func testMatchCheckAsksTheSameQuestionsAsTheSearch() {
        let reader = reader
        XCTAssertTrue(MenuCommandSearch.matches(Node("Paste", character: "V"), character: "v", modifiers: 0, reader: reader))
        XCTAssertFalse(MenuCommandSearch.matches(Node("Paste", character: "v", enabled: false), character: "v", modifiers: 0, reader: reader))
        XCTAssertFalse(MenuCommandSearch.matches(Node("Copy", character: "c"), character: "v", modifiers: 0, reader: reader))
    }
}
