import XCTest
@testable import FrogCore

final class RemovalPlanTests: XCTestCase {
    private func make(_ fixture: CleanerFixture, app: AppIdentity? = nil, items: [CleanerItem],
                      selected: [CleanerItem]? = nil, sizes: [String: CleanerSize] = [:]) -> RemovalPlan {
        RemovalPlan.make(app: app, items: items, selected: Set((selected ?? items).map(\.id)), purpose: .leftover,
                         safety: CleanerSafety(roots: fixture.roots), sizes: sizes)
    }

    private func app(_ fixture: CleanerFixture) throws -> AppIdentity {
        let bundle = try fixture.app("Example", bundleID: "com.example.app")
        return AppIdentity(path: bundle.path, name: "Example", bundleID: "com.example.app",
                           nestedBundleIDs: ["com.example.app.helper"])
    }

    private func leftover(_ url: URL, kind: CleanerItemKind = .folder, owner: CleanerOwner = .user,
                          size: Int64? = 10, label: String? = nil) -> CleanerItem {
        CleanerItem(url: url, kind: kind, confidence: .certain, reason: "Named after the bundle ID.", owner: owner,
                    size: size, launchLabel: label)
    }

    func testOnlyTickedAllowedItemsMoveAndRefusalsKeepTheirSentence() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let ticked = leftover(try fixture.item(.caches, "com.example.app"))
        let untouched = leftover(try fixture.item(.applicationSupport, "Example"))
        let apple = leftover(try fixture.item(.caches, "com.apple.Safari"))

        let plan = make(fixture, items: [ticked, untouched, apple], selected: [ticked, apple])

        XCTAssertEqual(plan.removals.map(\.item), [ticked])
        XCTAssertEqual(plan.refused, [RemovalRefusal(item: apple, reason: "Frog never moves Apple's own files.")])
        XCTAssertEqual(plan.purpose, .leftover)
        XCTAssertFalse(plan.isEmpty)
        XCTAssertTrue(make(fixture, items: [ticked], selected: []).isEmpty)
    }

    func testAChildOfATickedFolderIsNotMovedTwice() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let folder = try fixture.item(.applicationSupport, "Example")
        let parent = leftover(folder), child = leftover(folder.appendingPathComponent("Cache"))
        let sibling = leftover(try fixture.item(.applicationSupport, "Example Helper"))

        let plan = make(fixture, items: [child, sibling, parent])

        XCTAssertEqual(plan.removals.map(\.item), [parent, sibling])
        XCTAssertEqual(plan.totalBytes, 20)
    }

    func testAppsAdminItemsAndContainersGoThroughFinder() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let identity = try app(fixture)
        let bundle = CleanerItem(url: identity.url, kind: .application, confidence: .certain, reason: "The app itself.")
        let container = leftover(try fixture.item(.containers, "com.example.app"), kind: .container)
        let group = leftover(try fixture.item(.groupContainers, "ABCDE12345.com.example"), kind: .groupContainer)
        let shared = leftover(try fixture.item(.caches, "com.example.app", domain: .system), owner: .administrator)
        let own = leftover(try fixture.item(.caches, "com.example.app"))

        let plan = make(fixture, app: identity, items: [bundle, container, group, shared, own])

        let routes = Dictionary(uniqueKeysWithValues: plan.removals.map { ($0.item.id, $0.route) })
        XCTAssertEqual(routes[bundle.id], .finder)
        XCTAssertEqual(routes[container.id], .finder)
        XCTAssertEqual(routes[group.id], .finder)
        XCTAssertEqual(routes[shared.id], .finder)
        XCTAssertEqual(routes[own.id], .fileManager)
        XCTAssertEqual(plan.finderCount, 4)
        XCTAssertEqual(plan.administratorCount, 1)
        XCTAssertTrue(plan.removesApp)
        XCTAssertEqual(plan.removals.map(\.item.id), plan.removals.map(\.item.id).sorted())
    }

    func testAgentsAreStoppedAndDaemonsWaitForARestart() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let agent = leftover(try fixture.launchPlist(.launchAgents, label: "com.example.agent"), kind: .launchAgent,
                             label: "com.example.agent")
        let unlabelled = leftover(try fixture.launchPlist(.launchAgents, label: "com.example.other"), kind: .launchAgent)
        let daemon = leftover(try fixture.launchPlist(.launchDaemons, label: "com.example.daemon", domain: .system),
                              kind: .launchDaemon, owner: .administrator, label: "com.example.daemon")
        let helper = leftover(try fixture.item(.privilegedHelperTools, "com.example.helper", domain: .system, directory: false),
                              kind: .helperTool, owner: .administrator)

        let plan = make(fixture, items: [agent, unlabelled, daemon, helper])

        XCTAssertEqual(plan.launchLabelsToStop, ["com.example.agent", "com.example.other"])
        XCTAssertEqual(plan.restartLabels, ["com.example.daemon", "com.example.helper"])
        XCTAssertEqual(plan.administratorCount, 2)
    }

    func testQuittingIsPlannedWheneverAnythingOfTheAppMoves() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let identity = try app(fixture)
        let cache = leftover(try fixture.item(.caches, "com.example.app"))

        let leftoversOnly = make(fixture, app: identity, items: [cache])
        XCTAssertEqual(leftoversOnly.quitBundleIDs, ["com.example.app", "com.example.app.helper"])
        XCTAssertFalse(leftoversOnly.removesApp)
        XCTAssertEqual(make(fixture, app: identity, items: [cache], selected: []).quitBundleIDs, [])
        XCTAssertEqual(make(fixture, items: [cache]).quitBundleIDs, [])
        let apple = leftover(try fixture.item(.caches, "com.apple.example"))
        XCTAssertEqual(make(fixture, app: identity, items: [apple]).quitBundleIDs, [], "nothing moves when all is refused")
    }

    func testUnknownSizesMakeTheTotalAtLeast() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let known = leftover(try fixture.item(.caches, "com.example.known"), size: 100)
        let measured = leftover(try fixture.item(.caches, "com.example.measured"), size: nil)
        let unknown = leftover(try fixture.item(.caches, "com.example.unknown"), size: nil)
        let complete = [measured.id: CleanerSize(bytes: 200, complete: true)]

        let partial = make(fixture, items: [known, measured, unknown], sizes: complete)
        XCTAssertEqual(partial.totalBytes, 300)
        XCTAssertTrue(partial.sizeIncomplete)

        let whole = make(fixture, items: [known, measured], sizes: complete)
        XCTAssertEqual(whole.totalBytes, 300)
        XCTAssertFalse(whole.sizeIncomplete)

        let cut = make(fixture, items: [known, measured], sizes: [measured.id: CleanerSize(bytes: 50, complete: false),
                                                                  known.id: CleanerSize(bytes: 120, complete: true)])
        XCTAssertEqual(cut.totalBytes, 170, "a measured size wins over the item's own")
        XCTAssertTrue(cut.sizeIncomplete)
    }
}
