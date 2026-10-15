import XCTest
@testable import FrogCore

final class CleanerRemoverTests: XCTestCase {
    private var fixture: CleanerFixture!
    private var log: CleanerCallLog!
    private var trash: FakeCleanerTrash!
    private var system: FakeCleanerSystem!
    private var store: CleanerStore!

    override func setUpWithError() throws {
        fixture = try CleanerFixture()
        log = CleanerCallLog()
        trash = FakeCleanerTrash(folder: fixture.root.appendingPathComponent("Trash", isDirectory: true), log: log)
        system = FakeCleanerSystem(log: log)
        store = CleanerStore(directory: fixture.root.appendingPathComponent("Data/Cleaner", isDirectory: true))
    }

    override func tearDown() { fixture.remove() }

    private func remover(protecting: [URL] = []) -> CleanerRemover {
        CleanerRemover(trash: trash, system: system, store: store,
                       safety: CleanerSafety(roots: fixture.roots, protectedPaths: protecting))
    }

    private func identity() throws -> AppIdentity {
        let bundle = try fixture.app("Example", bundleID: "com.example.app")
        return AppIdentity(path: bundle.path, name: "Example", bundleID: "com.example.app",
                           nestedBundleIDs: ["com.example.app.helper"])
    }

    private func item(_ url: URL, kind: CleanerItemKind = .folder, owner: CleanerOwner = .user,
                      fullDiskAccess: Bool = false, label: String? = nil) -> CleanerItem {
        CleanerItem(url: url, kind: kind, confidence: .certain, reason: "Named after the bundle ID.", owner: owner,
                    size: 10, needsFullDiskAccess: fullDiskAccess, launchLabel: label)
    }

    private func plan(_ items: [CleanerItem], app: AppIdentity? = nil) -> RemovalPlan {
        RemovalPlan.make(app: app, items: items, selected: Set(items.map(\.id)), purpose: .leftover,
                         safety: CleanerSafety(roots: fixture.roots))
    }

    private func run(_ plan: RemovalPlan, with remover: CleanerRemover? = nil, forceQuit: Bool = true) async -> RemovalOutcome {
        let log = log!
        return await (remover ?? self.remover()).perform(plan, title: "Example", confirmForceQuit: { apps in
            log.append("confirm " + apps.map(\.name).joined(separator: ","))
            return forceQuit
        }, progress: { done, total in log.append("progress \(done)/\(total)") })
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func running(_ app: AppIdentity) -> [RunningAppInfo] {
        [RunningAppInfo(pid: 10, bundleID: app.bundleID, name: "Example", bundlePath: app.path),
         RunningAppInfo(pid: 11, bundleID: "com.example.app.helper", name: "Example Helper",
                        bundlePath: app.path + "/Contents/Library/LoginItems/Example Helper.app")]
    }

    func testStepsRunInOrderQuitStopMoveRecord() async throws {
        let app = try identity()
        let bundle = item(app.url, kind: .application)
        let agent = item(try fixture.launchPlist(.launchAgents, label: "com.example.agent"), kind: .launchAgent,
                         label: "com.example.agent")
        let cache = item(try fixture.item(.caches, "com.example.app"))
        await system.setRunning(running(app) + [RunningAppInfo(pid: 12, bundleID: "com.other", name: "Other", bundlePath: nil)])

        let outcome = await run(plan([bundle, agent, cache], app: app))

        XCTAssertEqual(log.entries, [
            "running", "quit Example,Example Helper", "bootOut com.example.agent",
            "trash com.example.app", "progress 1/3", "trash com.example.agent.plist", "progress 2/3",
            "automation", "finder Example.app", "progress 3/3"
        ])
        XCTAssertEqual(outcome.failures, [])
        XCTAssertFalse(outcome.cancelled)
        XCTAssertEqual(Set(outcome.moved.map(\.original)), Set([bundle.id, agent.id, cache.id]))
        XCTAssertEqual(outcome.movedBytes, 30)
        XCTAssertTrue(outcome.moved.allSatisfy { $0.trashed != nil && $0.restorable })
        XCTAssertFalse(exists(app.url))
        let record = try XCTUnwrap(outcome.record)
        XCTAssertEqual(record.title, "Example")
        XCTAssertEqual(record.entries, outcome.moved)
        XCTAssertEqual(try store.records(), [record])
    }

    func testDecliningForceQuitMovesNothing() async throws {
        let app = try identity()
        let cache = item(try fixture.item(.caches, "com.example.app"))
        await system.setRunning(running(app))
        await system.setSurvivors(quit: 1)

        let outcome = await run(plan([item(app.url, kind: .application), cache], app: app), forceQuit: false)

        XCTAssertEqual(outcome, RemovalOutcome(cancelled: true))
        XCTAssertEqual(log.entries, ["running", "quit Example,Example Helper", "confirm Example"])
        XCTAssertTrue(exists(app.url))
        XCTAssertTrue(exists(cache.url))
        XCTAssertEqual(try store.records(), [])
    }

    func testAnAppThatSurvivesForceQuitMovesNothing() async throws {
        let app = try identity()
        let cache = item(try fixture.item(.caches, "com.example.app"))
        await system.setRunning(running(app))
        await system.setSurvivors(quit: 2, forceQuit: 1)

        let outcome = await run(plan([cache], app: app))

        XCTAssertTrue(outcome.cancelled)
        XCTAssertEqual(outcome.failures, [RemovalFailure(path: app.path, message: "Example is still running. Nothing was moved.")])
        XCTAssertEqual(outcome.moved, [])
        XCTAssertEqual(log.entries.suffix(2), ["confirm Example,Example Helper", "forceQuit Example,Example Helper"])
        XCTAssertTrue(exists(cache.url))
    }

    func testAMissingOrNewlyRefusedItemFailsAloneAndTheRestMove() async throws {
        let missing = item(try fixture.item(.caches, "com.example.missing"))
        let protected = item(try fixture.item(.caches, "com.example.protected"))
        let kept = item(try fixture.item(.caches, "com.example.kept"))
        let planned = plan([missing, protected, kept])
        try FileManager.default.removeItem(at: missing.url)

        let outcome = await run(planned, with: remover(protecting: [protected.url]))

        XCTAssertEqual(outcome.moved.map(\.original), [kept.id])
        XCTAssertEqual(outcome.failures, [
            RemovalFailure(path: missing.id, message: "It is no longer there."),
            RemovalFailure(path: protected.id, message: "Frog never moves its own files.")
        ])
        XCTAssertTrue(exists(protected.url))
        XCTAssertFalse(log.entries.contains("trash com.example.protected"))
    }

    func testFinderItemsMoveInOneCall() async throws {
        let app = try identity()
        let container = item(try fixture.item(.containers, "com.example.app"), kind: .container)
        let group = item(try fixture.item(.groupContainers, "ABCDE12345.com.example"), kind: .groupContainer)

        let outcome = await run(plan([item(app.url, kind: .application), container, group], app: app))

        XCTAssertEqual(log.entries.filter { $0.hasPrefix("finder ") }.count, 1)
        XCTAssertEqual(outcome.moved.count, 3)
        XCTAssertTrue(outcome.moved.allSatisfy { $0.route == .finder && $0.trashed != nil })
        XCTAssertEqual(outcome.failures, [])
    }

    func testAFinderErrorAfterTheFirstOfThreeRecordsTheMovedOneAsNotRestorable() async throws {
        let items = try ["one", "three", "two"].map {
            item(try fixture.item(.containers, "com.example.\($0)"), kind: .container)
        }
        await trash.failFinder(after: 1, with: NSError(domain: NSOSStatusErrorDomain, code: -10_000))

        let outcome = await run(plan(items))

        XCTAssertEqual(outcome.moved, [RemovalRecord.Entry(original: items[0].id, trashed: nil, bytes: 10, route: .finder,
                                                           owner: .user)])
        XCTAssertFalse(outcome.moved[0].restorable)
        XCTAssertEqual(outcome.failures, items.dropFirst().map {
            RemovalFailure(path: $0.id, message: "Finder could not move this item.")
        })
        XCTAssertEqual(try store.records().first?.entries, outcome.moved)
    }

    func testAdministratorEntriesAreNotRestorableByFrog() async throws {
        let shared = item(try fixture.item(.caches, "com.example.app", domain: .system), owner: .administrator)

        let outcome = await run(plan([shared]))

        let entry = try XCTUnwrap(outcome.moved.first)
        XCTAssertEqual(entry.route, .finder)
        XCTAssertEqual(entry.owner, .administrator)
        XCTAssertNotNil(entry.trashed)
        XCTAssertFalse(entry.restorable)
        let (record, failures) = await remover().putBack(try XCTUnwrap(outcome.record))
        XCTAssertEqual(failures, [RemovalFailure(path: shared.id, message: "Use Put Back in the Trash in Finder.")])
        XCTAssertFalse(record.entries[0].restored)
        XCTAssertFalse(exists(shared.url))
    }

    func testDeniedAutomationFailsOnlyFinderItemsWithTheSettingsSentence() async throws {
        let container = item(try fixture.item(.containers, "com.example.app"), kind: .container)
        let cache = item(try fixture.item(.caches, "com.example.app"))
        await trash.setAutomation(.denied)

        let outcome = await run(plan([container, cache]))

        XCTAssertEqual(outcome.moved.map(\.original), [cache.id])
        XCTAssertEqual(outcome.failures, [RemovalFailure(
            path: container.id,
            message: "Frog may not control Finder. Allow it in System Settings → Privacy & Security → Automation.")])
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("finder ") })
        XCTAssertTrue(exists(container.url))
    }

    func testCancelledPasswordPromptIsReported() async throws {
        let shared = item(try fixture.item(.caches, "com.example.app", domain: .system), owner: .administrator)
        await trash.failFinder(after: 0, with: NSError(domain: "NSAppleScriptErrorDomain", code: -128))

        let outcome = await run(plan([shared]))

        XCTAssertEqual(outcome.failures, [RemovalFailure(path: shared.id, message: "You cancelled the password prompt.")])
        XCTAssertEqual(outcome.moved, [])
        XCTAssertNil(outcome.record)
        XCTAssertEqual(try store.records(), [])
    }

    func testPermissionErrorsSayWhetherFullDiskAccessWouldHelp() async throws {
        let protected = item(try fixture.item(.caches, "com.example.protected"), fullDiskAccess: true)
        let denied = item(try fixture.item(.caches, "com.example.denied"))
        let vanished = item(try fixture.item(.caches, "com.example.vanished"))
        let other = item(try fixture.item(.caches, "com.example.other"))
        await trash.fail(protected.url, with: CocoaError(.fileWriteNoPermission))
        await trash.fail(denied.url, with: POSIXError(.EACCES))
        await trash.fail(vanished.url, with: CocoaError(.fileNoSuchFile))
        await trash.fail(other.url, with: NSError(domain: "Example", code: 1))
        let planned = plan([protected, denied, vanished, other])

        let outcome = await run(planned)

        XCTAssertEqual(outcome.failures, [
            RemovalFailure(path: denied.id, message: "macOS did not allow Frog to move this item."),
            RemovalFailure(path: other.id, message: "Frog could not move this item."),
            RemovalFailure(path: protected.id, message: "Frog needs Full Disk Access to move this item."),
            RemovalFailure(path: vanished.id, message: "It is no longer there.")
        ])
        XCTAssertNil(outcome.record)

        // With Full Disk Access already granted, it would not help.
        await system.setFullDiskAccess(true)
        let again = await run(plan([protected]))
        XCTAssertEqual(again.failures, [RemovalFailure(path: protected.id, message: "macOS did not allow Frog to move this item.")])
    }

    func testAFailedBootoutIsANoteNotAFailure() async throws {
        let failing = item(try fixture.launchPlist(.launchAgents, label: "com.example.agent"), kind: .launchAgent,
                           label: "com.example.agent")
        let stopping = item(try fixture.launchPlist(.launchAgents, label: "com.example.updater"), kind: .launchAgent,
                            label: "com.example.updater")
        await system.failBootOut("com.example.agent")

        let outcome = await run(plan([failing, stopping]))

        XCTAssertEqual(outcome.notes, ["Frog could not stop com.example.agent. It stops after you log out or restart."])
        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.moved.count, 2)
        XCTAssertEqual(Array(log.entries.prefix(2)), ["bootOut com.example.agent", "bootOut com.example.updater"])
    }

    func testAListThatCannotBeSavedIsANoteAndTheItemsStillMove() async throws {
        let blocked = fixture.root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let cache = item(try fixture.item(.caches, "com.example.app"))
        let remover = CleanerRemover(trash: trash, system: system,
                                     store: CleanerStore(directory: blocked.appendingPathComponent("Cleaner")),
                                     safety: CleanerSafety(roots: fixture.roots))

        let outcome = await run(plan([cache]), with: remover)

        XCTAssertEqual(outcome.moved.map(\.original), [cache.id])
        XCTAssertNotNil(outcome.record)
        XCTAssertEqual(outcome.notes, ["Frog could not save the list for Put Back."])
    }

    func testPutBackRestoresFreePlacesAndExplainsTheRest() async throws {
        let free = item(try fixture.item(.caches, "com.example.free"))
        let taken = item(try fixture.item(.caches, "com.example.taken"))
        let failing = item(try fixture.item(.caches, "com.example.failing"))
        let outcome = await run(plan([free, taken, failing]))
        var record = try XCTUnwrap(outcome.record)
        let unknown = fixture.home.appendingPathComponent("Library/Caches/com.example.unknown").path
        record.entries.append(RemovalRecord.Entry(original: unknown, trashed: nil, bytes: nil, route: .finder, owner: .user))
        try store.replace(record)
        try fixture.item(.caches, "com.example.taken")
        let failingTrashed = try XCTUnwrap(record.entries.first { $0.original == failing.id }?.trashed)
        await trash.fail(URL(fileURLWithPath: failingTrashed), with: CocoaError(.fileWriteUnknown))

        let (restored, failures) = await remover().putBack(record)

        XCTAssertEqual(failures, [
            RemovalFailure(path: failing.id, message: "Frog could not put this item back."),
            RemovalFailure(path: taken.id, message: "Something else is now at the original place."),
            RemovalFailure(path: unknown, message: "Use Put Back in the Trash in Finder.")
        ])
        XCTAssertTrue(exists(free.url))
        XCTAssertEqual(restored.entries.filter(\.restored).map(\.original), [free.id])
        XCTAssertEqual(try store.records().first, restored)
    }
}
