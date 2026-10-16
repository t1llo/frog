import FrogCore
import XCTest
@testable import FrogApp

/// The App cleaner's page state, without a window: everything runs in a fixture folder with a fake Trash and
/// a fake set of running apps.
@MainActor
final class CleanerModelTests: XCTestCase {
    func testAllIdentitiesIncludeTheAppsThatAreNotListed() async throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let urls = [
            try fixture.app("Chatter", bundleID: "com.example.chatter"),
            try fixture.app("Pages", bundleID: "com.apple.iWork.Pages"),
            try fixture.app("Notes", bundleID: "com.apple.Notes", in: fixture.appleApplications),
            try fixture.app("Frog", bundleID: "xyz.beffa.frog", in: fixture.homeApplications),
            try fixture.app("Loose", bundleID: "com.example.loose", in: fixture.home.appendingPathComponent("Downloads")),
            fixture.applications.appendingPathComponent("Broken.app", isDirectory: true)
        ]
        try FileManager.default.createDirectory(at: urls[5], withIntermediateDirectories: true)
        let model = CleanerModel(dependencies: .fake(root: fixture.root, applications: urls))

        let identities = await model.allIdentities()

        XCTAssertEqual(Set(identities.map(\.bundleID)),
                       ["com.example.chatter", "com.apple.iWork.Pages", "com.apple.Notes", "xyz.beffa.frog", "com.example.loose"])
        XCTAssertEqual(model.apps.map(\.identity.name), ["Chatter"])
        XCTAssertFalse(model.loadingApps)
    }

    func testAppleSystemAndFrogAppsAreNotListedButStillClaimNames() async throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        try fixture.app("Pages", bundleID: "com.apple.iWork.Pages")
        try fixture.app("Frog", bundleID: "xyz.beffa.frog")
        let pages = try fixture.app("Pages", bundleID: "com.example.pages", in: fixture.homeApplications)
        let folder = try fixture.item(.applicationSupport, "Pages")
        let cache = try fixture.item(.caches, "com.example.pages")
        let model = CleanerModel(dependencies: .fake(root: fixture.root))

        await model.loadApps()
        XCTAssertEqual(model.apps.map(\.identity.bundleID), ["com.example.pages"])
        await model.open(pages)

        let review = try XCTUnwrap(model.review)
        let shared = try XCTUnwrap(review.items.first { $0.id == id(folder) })
        XCTAssertEqual(shared.sharedWith, ["Pages"], "Apple's Pages still claims the folder named after it")
        XCTAssertFalse(review.selected.contains(shared.id))
        XCTAssertTrue(review.selected.contains(id(cache)))
        XCTAssertEqual(review.groups(showPossible: false).map(\.kind), [.application, .sure, .shared])
    }

    func testSearchMatchesNameAndBundleIDAndSizeSortPutsUnknownLast() async throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        try fixture.app("Alpha", bundleID: "org.example.alpha", bundleName: "Alphabet Soup")
        try fixture.app("Écrivain", bundleID: "com.example.writer", payload: 50_000)
        try fixture.app("Zebra", bundleID: "com.example.zebra", payload: 200_000)
        let model = CleanerModel(dependencies: .fake(root: fixture.root))
        await model.loadApps()
        await model.measureAppSizes()
        try fixture.app("Late", bundleID: "com.example.late")
        await model.loadApps()

        model.search = "ecri"
        XCTAssertEqual(model.visibleApps.map(\.identity.name), ["Écrivain"])
        model.search = "ORG.EXAMPLE"
        XCTAssertEqual(model.visibleApps.map(\.identity.name), ["Alpha"])
        model.search = " soup "
        XCTAssertEqual(model.visibleApps.map(\.identity.name), ["Alpha"])
        model.search = ""
        XCTAssertEqual(model.visibleApps.map(\.identity.name), ["Alpha", "Écrivain", "Late", "Zebra"])
        model.sort = .size
        XCTAssertEqual(model.visibleApps.map(\.identity.name), ["Zebra", "Écrivain", "Alpha", "Late"])
        XCTAssertNil(model.visibleApps.last?.size)
        XCTAssertEqual(CleanerAppSort.allCases.map(\.title), ["Name", "Size"])
    }

    func testOpeningAnAppTicksOnlyConfidentUnsharedItems() async throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let chatter = try fixture.app("Chatter", bundleID: "com.example.chatter")
        try fixture.app("Chatter Lite", bundleID: "com.example.chatterlite", in: fixture.homeApplications)
        let signatures = FakeCodeSignatures(signatures: [
            "Chatter.app": CodeSignatureInfo(teamID: "ABCDE12345", appGroups: ["ABCDE12345.com.example.chatter", "ABCDE12345.shared.store"]),
            "Chatter Lite.app": CodeSignatureInfo(teamID: "ABCDE12345", appGroups: ["ABCDE12345.shared.store"])
        ])
        let cache = try fixture.item(.caches, "com.example.chatter")
        let support = try fixture.item(.applicationSupport, "Chatter")
        let possible = try fixture.item(.logs, "ChatterSync")
        let group = try fixture.item(.groupContainers, "ABCDE12345.com.example.chatter")
        let sharedGroup = try fixture.item(.groupContainers, "ABCDE12345.shared.store")
        let model = CleanerModel(dependencies: .fake(root: fixture.root, signatures: signatures))

        await model.open(chatter)

        let review = try XCTUnwrap(model.review)
        XCTAssertEqual(model.phase, .reviewing)
        XCTAssertEqual(Set(review.items.map(\.id)),
                       Set([chatter, cache, support, possible, group, sharedGroup].map { id($0) }))
        XCTAssertEqual(review.selected, Set([chatter, cache, support].map { id($0) }),
                       "Possible matches, shared items and group containers are never ticked by Frog")
        XCTAssertEqual(review.selectedCount, 3)
    }

    func testPossibleMatchesAreGroupedOnlyWhenShown() async throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let chatter = try fixture.app("Chatter", bundleID: "com.example.chatter")
        try fixture.item(.caches, "com.example.chatter")
        let possible = id(try fixture.item(.logs, "ChatterSync"))
        let model = CleanerModel(dependencies: .fake(root: fixture.root))
        await model.open(chatter)

        let review = try XCTUnwrap(model.review)
        XCTAssertEqual(review.groups(showPossible: false).map(\.kind), [.application, .sure])
        XCTAssertEqual(review.groups(showPossible: true).map(\.kind), [.application, .sure, .possible])
        XCTAssertEqual(CleanerGroupKind.allCases.map(\.title),
                       ["App", "Sure matches", "Likely matches", "Possible matches", "Used by other apps", "Suggested by AI"])

        model.showPossibleMatches = true
        model.setGroup(.possible, selected: true)
        XCTAssertTrue(model.review?.selected.contains(possible) == true, "The user may tick possible matches")
        model.showPossibleMatches = false
        XCTAssertFalse(model.review?.selected.contains(possible) == true, "Hidden matches never move")
    }

    func testDroppingSomethingThatIsNotAnAppExplainsWhy() async throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let folder = fixture.root.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = fixture.root.appendingPathComponent("Fake.app")
        try Data().write(to: file)
        let broken = fixture.applications.appendingPathComponent("Broken.app", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        let cases: [(URL, String)] = [
            (folder, "Drop an app from Finder."),
            (file, "Drop an app from Finder."),
            (broken, "Frog cannot read this app."),
            (try fixture.app("Pages", bundleID: "com.apple.iWork.Pages"), "Frog leaves Apple's apps alone. Remove them in Finder."),
            (try fixture.app("Frog", bundleID: "xyz.beffa.frog"),
             "Frog cannot remove itself. Quit Frog, then move it to the Trash in Finder."),
            (try fixture.app("Loose", bundleID: "com.example.loose", in: fixture.home.appendingPathComponent("Downloads")),
             "Frog removes apps from the Applications folders. Move this one to the Trash in Finder.")
        ]
        let model = CleanerModel(dependencies: .fake(root: fixture.root))

        for (url, message) in cases {
            await model.open(url)
            XCTAssertEqual(model.issue, message, url.lastPathComponent)
            XCTAssertNil(model.review)
            XCTAssertEqual(model.phase, .idle)
        }
    }

    func testPreparingBuildsThePlanAndTheExactPrompt() async throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let chatter = try fixture.app("Chatter", bundleID: "com.example.chatter")
        try fixture.item(.caches, "com.example.chatter", bytes: 10_000)
        try fixture.item(.applicationSupport, "Chatter", bytes: 5_000)
        let log = CleanerCallLog()
        let system = FakeCleanerSystem(log: log)
        await system.setRunning([
            RunningAppInfo(pid: 101, bundleID: "com.example.chatter", name: "Chatter", bundlePath: chatter.path),
            RunningAppInfo(pid: 102, bundleID: nil, name: "Chatter Helper",
                           bundlePath: chatter.path + "/Contents/Frameworks/Chatter Helper.app")
        ])
        let model = CleanerModel(dependencies: .fake(root: fixture.root, system: system))
        await model.open(chatter)
        await model.waitForSizes()

        await model.prepareRemoval()

        let pending = try XCTUnwrap(model.pending)
        XCTAssertEqual(pending.plan.removals.count, 3)
        XCTAssertEqual(pending.prompt.title, "Move Chatter and 2 other items to the Trash?")
        XCTAssertEqual(pending.prompt.notes.first, "Frog quits Chatter and 1 of its helpers first.")
        XCTAssertEqual(pending.prompt, RemovalPrompt(plan: pending.plan, appIsRunning: true, runningHelpers: 1))
        let sizes = try XCTUnwrap(model.review?.sizes)
        XCTAssertEqual(pending.plan.totalBytes, pending.plan.removals.reduce(0) { $0 + (sizes[$1.item.id]?.bytes ?? 0) })
        XCTAssertFalse(pending.plan.sizeIncomplete)
        XCTAssertTrue(pending.plan.removals.allSatisfy { $0.item.size != nil }, "Records carry the measured sizes")
        XCTAssertEqual(log.entries.filter { $0 != "fullDiskAccess" }, ["running"], "Preparing moves and quits nothing")

        model.cancelRemoval()
        XCTAssertNil(model.pending)
        XCTAssertTrue(FileManager.default.fileExists(atPath: chatter.path))
    }

    func testConfirmingMovesThroughTheFakesRecordsAndDropsTheApp() async throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let chatter = try fixture.app("Chatter", bundleID: "com.example.chatter")
        try fixture.item(.caches, "com.example.chatter", bytes: 10_000)
        try fixture.item(.applicationSupport, "Chatter", bytes: 5_000)
        let log = CleanerCallLog()
        let trash = FakeCleanerTrash(folder: fixture.root.appendingPathComponent("Trash"), log: log)
        let model = CleanerModel(dependencies: .fake(root: fixture.root, trash: trash, system: FakeCleanerSystem(log: log)))
        await model.loadApps()
        XCTAssertEqual(model.apps.count, 1)
        await model.open(chatter)
        await model.waitForSizes()
        await model.prepareRemoval()

        await model.confirmRemoval()

        let outcome = try XCTUnwrap(model.outcome)
        XCTAssertEqual(outcome.moved.count, 3)
        XCTAssertEqual(outcome.failures, [])
        XCTAssertGreaterThan(outcome.movedBytes, 15_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chatter.path))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent("Trash").path)),
                       ["Chatter.app", "Chatter", "com.example.chatter"])
        XCTAssertEqual(log.entries.filter { $0.hasPrefix("trash") || $0.hasPrefix("finder") },
                       ["finder Chatter.app", "trash Chatter", "trash com.example.chatter"])
        XCTAssertEqual(try model.dependencies.store.records().map(\.title), ["Chatter"])
        XCTAssertEqual(model.apps, [])
        XCTAssertNil(model.review)
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.phase, .idle)
        let identities = await model.allIdentities()
        XCTAssertFalse(identities.contains { $0.bundleID == "com.example.chatter" })
    }

    func testAForceQuitQuestionWaitsForTheAnswerAndNoMovesNothing() async throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let chatter = try fixture.app("Chatter", bundleID: "com.example.chatter")
        try fixture.item(.caches, "com.example.chatter")
        let log = CleanerCallLog()
        let system = FakeCleanerSystem(log: log)
        await system.setRunning([RunningAppInfo(pid: 101, bundleID: "com.example.chatter", name: "Chatter", bundlePath: chatter.path)])
        await system.setSurvivors(quit: 1)
        let trash = FakeCleanerTrash(folder: fixture.root.appendingPathComponent("Trash"), log: log)
        let model = CleanerModel(dependencies: .fake(root: fixture.root, trash: trash, system: system))
        await model.open(chatter)
        await model.prepareRemoval()

        let confirming = Task { await model.confirmRemoval() }
        await eventually { model.forceQuit != nil }

        XCTAssertEqual(model.forceQuit?.title, "Chatter did not quit. Force quit it?")
        XCTAssertEqual(model.forceQuit?.message, "Unsaved changes in Chatter may be lost.")
        XCTAssertEqual(model.phase, .removing(done: 0, total: 2))
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("trash") || $0.hasPrefix("finder") })
        model.answerForceQuit(false)
        await confirming.value

        XCTAssertEqual(model.outcome?.cancelled, true)
        XCTAssertEqual(model.outcome?.moved, [])
        XCTAssertNil(model.forceQuit)
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("forceQuit") || $0.hasPrefix("trash") || $0.hasPrefix("finder") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: chatter.path))
        XCTAssertEqual(model.phase, .idle)
    }

    func testStoppingCancelsAScanAndAnswersAnOpenQuestion() async throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let chatter = try fixture.app("Chatter", bundleID: "com.example.chatter")
        try fixture.item(.caches, "com.example.chatter")
        let log = CleanerCallLog()
        let system = FakeCleanerSystem(log: log)
        let gate = CleanerGate()
        await system.holdFullDiskAccess(at: gate)
        let model = CleanerModel(dependencies: .fake(root: fixture.root, system: system))

        let opening = Task { await model.open(chatter) }
        await eventually { model.phase == .scanning }
        while await gate.waiters == 0 { try await Task.sleep(for: .milliseconds(5)) }
        model.stop()
        await gate.open()
        await opening.value

        XCTAssertNil(model.review, "A stopped scan publishes nothing")
        XCTAssertEqual(model.phase, .idle)

        await system.setRunning([RunningAppInfo(pid: 101, bundleID: "com.example.chatter", name: "Chatter", bundlePath: chatter.path)])
        await system.setSurvivors(quit: 1)
        await model.open(chatter)
        await model.prepareRemoval()
        let confirming = Task { await model.confirmRemoval() }
        await eventually { model.forceQuit != nil }
        model.stop()
        await confirming.value

        XCTAssertNil(model.forceQuit)
        XCTAssertNil(model.outcome)
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("forceQuit") }, "Stopping answers no")
        XCTAssertTrue(FileManager.default.fileExists(atPath: chatter.path))
    }

    func testContainersAreNotMeasuredWithoutFullDiskAccess() async throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let chatter = try fixture.app("Chatter", bundleID: "com.example.chatter")
        let container = id(try fixture.item(.containers, "com.example.chatter", bytes: 20_000))
        let cache = id(try fixture.item(.caches, "com.example.chatter", bytes: 1_000))
        let system = FakeCleanerSystem()
        await system.setFullDiskAccess(false)
        let model = CleanerModel(dependencies: .fake(root: fixture.root, system: system))

        await model.open(chatter)
        await model.waitForSizes()
        XCTAssertEqual(model.fullDiskAccess, false)
        XCTAssertNil(model.review?.sizes[container])
        XCTAssertNotNil(model.review?.sizes[cache])
        XCTAssertNotNil(model.review?.sizes[id(chatter)])

        await system.setFullDiskAccess(true)
        await model.open(chatter)
        await model.waitForSizes()
        XCTAssertNotNil(model.review?.sizes[container])
    }

    func testNothingTickedSaysSo() async throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let chatter = try fixture.app("Chatter", bundleID: "com.example.chatter")
        try fixture.item(.caches, "com.example.chatter")
        let model = CleanerModel(dependencies: .fake(root: fixture.root))
        await model.open(chatter)

        for group in model.review?.groups(showPossible: false) ?? [] { model.setGroup(group.kind, selected: false) }
        XCTAssertEqual(model.review?.selectedCount, 0)
        await model.prepareRemoval()

        XCTAssertEqual(model.issue, "Tick at least one item.")
        XCTAssertNil(model.pending)
    }

    func testARemovedAppsReviewIsRefusedWhenTheAppIsInstalledAgain() async throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let gone = AppIdentity(path: fixture.applications.appendingPathComponent("Gone.app").path, name: "Gone",
                               bundleID: "com.example.gone")
        try fixture.item(.caches, "com.example.gone", bytes: 1_000)
        let model = CleanerModel(dependencies: .fake(root: fixture.root))

        await model.openReview(of: gone, removedApp: true)
        XCTAssertEqual(model.review?.removedApp, true)
        XCTAssertEqual(model.review?.items.map(\.kind), [.folder], "The bundle is gone, so only its leftovers are listed")
        model.isInstalledAgain = { _ in true }
        await model.prepareRemoval()
        XCTAssertEqual(model.issue, "Gone is installed again.")
        XCTAssertNil(model.review)
        XCTAssertNil(model.pending)

        await model.openReview(of: gone, removedApp: true)
        model.isInstalledAgain = { _ in false }
        await model.prepareRemoval()
        XCTAssertEqual(model.pending?.prompt.title, "Move 1 item of Gone to the Trash?")
    }

    // MARK: - Recently moved

    func testRecentlyMovedListsRecordsAndPutBackRestoresThem() async throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let chatter = try fixture.app("Chatter", bundleID: "com.example.chatter")
        let cache = try fixture.item(.caches, "com.example.chatter", bytes: 100)
        let support = try fixture.item(.applicationSupport, "Chatter", bytes: 100)
        let log = CleanerCallLog()
        let trash = FakeCleanerTrash(folder: fixture.root.appendingPathComponent("Trash"), log: log)
        let model = CleanerModel(dependencies: .fake(root: fixture.root, trash: trash))
        await model.loadApps()
        await model.open(chatter)
        await model.prepareRemoval()
        await model.confirmRemoval()
        let record = try XCTUnwrap(model.outcome?.record)
        XCTAssertEqual(model.apps, [])

        model.loadRecords()
        XCTAssertEqual(model.records.map(\.title), ["Chatter"])
        let row = RecentlyMovedRow(try XCTUnwrap(model.records.first))
        XCTAssertTrue(row.canPutBack)
        XCTAssertFalse(row.needsFinder)
        XCTAssertNil(row.restoredText)

        await model.putBack(record.id)

        XCTAssertEqual(model.putBackSummary?.title, "Put back 3 items.")
        XCTAssertEqual(model.putBackSummary?.failures, [])
        for url in [chatter, cache, support] { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent) }
        let after = RecentlyMovedRow(try XCTUnwrap(model.records.first))
        XCTAssertEqual(after.restoredText, "3 put back")
        XCTAssertFalse(after.canPutBack, "A second Put Back has nothing to do")
        XCTAssertEqual(model.apps.map(\.identity.name), ["Chatter"], "The app is listed again")
        model.dismissPutBack()
        XCTAssertNil(model.putBackSummary)

        model.showsRecent = true
        model.stop()
        XCTAssertEqual(model.records, [])
        XCTAssertFalse(model.showsRecent)
    }

    func testForgettingARecordLeavesTheTrashAlone() async throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let chatter = try fixture.app("Chatter", bundleID: "com.example.chatter")
        try fixture.item(.caches, "com.example.chatter")
        let log = CleanerCallLog()
        let trash = FakeCleanerTrash(folder: fixture.root.appendingPathComponent("Trash"), log: log)
        let model = CleanerModel(dependencies: .fake(root: fixture.root, trash: trash))
        await model.open(chatter)
        await model.prepareRemoval()
        await model.confirmRemoval()
        model.loadRecords()
        let record = try XCTUnwrap(model.records.first)

        model.forget(record.id)

        XCTAssertEqual(model.records, [])
        XCTAssertEqual(try model.dependencies.store.records(), [])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent("Trash").path)),
                       ["Chatter.app", "com.example.chatter"])
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("putBack") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: chatter.path))
    }

    func testPutBackSummaryTexts() {
        func entry(_ name: String, restored: Bool = false, bytes: Int64? = 100) -> RemovalRecord.Entry {
            RemovalRecord.Entry(original: "/fixture/\(name)", trashed: "/fixture/Trash/\(name)", bytes: bytes, route: .fileManager,
                                owner: .user, restored: restored)
        }
        let before = RemovalRecord(date: Date(), title: "12 items", entries: (1...12).map { entry("\($0)") })
        var all = before
        for index in all.entries.indices { all.entries[index].restored = true }
        XCTAssertEqual(PutBackSummary(before: before, after: all, failures: []).title, "Put back 12 items.")
        var one = before
        one.entries[3].restored = true
        XCTAssertEqual(PutBackSummary(before: before, after: one, failures: []).title, "Put back 1 item.")
        XCTAssertEqual(PutBackSummary(before: one, after: one, failures: []).title, "Nothing was put back.",
                       "Items put back earlier are not counted again")
        let failure = RemovalFailure(path: "/fixture/1", message: "Something else is now at the original place.")
        XCTAssertEqual(PutBackSummary(before: before, after: before, failures: [failure]).failures, [failure])

        let format: (Int64) -> String = { "\($0) B" }
        XCTAssertEqual(RecentlyMovedRow(before, formatBytes: format).detail, "12 items · 1200 B")
        let unknown = RemovalRecord(date: Date(), title: "Example", entries: [entry("a"), entry("b", bytes: nil)])
        XCTAssertEqual(RecentlyMovedRow(unknown, formatBytes: format).detail, "2 items · at least 100 B")
        let none = RemovalRecord(date: Date(), title: "Example", entries: [entry("a", bytes: nil)])
        XCTAssertEqual(RecentlyMovedRow(none, formatBytes: format).detail, "1 item")
        let partly = RemovalRecord(date: Date(), title: "Example", entries: [entry("a", restored: true), entry("b", restored: true), entry("c", restored: true), entry("d")])
        XCTAssertEqual(RecentlyMovedRow(partly).restoredText, "3 put back")
        XCTAssertEqual(RecentlyMovedRow.state(of: entry("a")), "In the Trash")
        XCTAssertEqual(RecentlyMovedRow.state(of: entry("a", restored: true)), "Put back")
    }

    func testAdministratorEntriesOfferPutBackInFinderOnly() async throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let folder = fixture.root.appendingPathComponent("Trash", isDirectory: true)
        let log = CleanerCallLog()
        let model = CleanerModel(dependencies: .fake(root: fixture.root, trash: FakeCleanerTrash(folder: folder, log: log)))
        let mine = fixture.home.appendingPathComponent("Library/Caches/com.example.mine")
        let shared = fixture.system.appendingPathComponent("Library/Caches/com.example.shared")
        for name in ["com.example.mine", "com.example.shared"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let record = RemovalRecord(date: Date(), title: "2 items", entries: [
            RemovalRecord.Entry(original: mine.path, trashed: folder.appendingPathComponent("com.example.mine").path, bytes: 10,
                                route: .fileManager, owner: .user),
            RemovalRecord.Entry(original: shared.path, trashed: folder.appendingPathComponent("com.example.shared").path, bytes: 10,
                                route: .finder, owner: .administrator)
        ])
        try model.dependencies.store.add(record)
        model.loadRecords()
        let row = RecentlyMovedRow(try XCTUnwrap(model.records.first))
        XCTAssertTrue(row.canPutBack)
        XCTAssertTrue(row.needsFinder)

        await model.putBack(record.id)

        XCTAssertEqual(model.putBackSummary?.title, "Put back 1 item.")
        XCTAssertEqual(model.putBackSummary?.failures.map(\.path), [shared.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: mine.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.path), "Only Finder puts the administrator's item back")
        XCTAssertEqual(log.entries, ["putBack com.example.mine"])
        let after = try XCTUnwrap(model.records.first)
        XCTAssertFalse(RecentlyMovedRow(after).canPutBack)
        XCTAssertTrue(RecentlyMovedRow(after).needsFinder)
        XCTAssertEqual(after.entries.map(RecentlyMovedRow.state(of:)), ["Put back", "Use Put Back in Finder"])
    }

    func testOnFinishRunsAfterARemovalAndAfterACancelledOne() async throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let chatter = try fixture.app("Chatter", bundleID: "com.example.chatter")
        try fixture.item(.caches, "com.example.chatter")
        let system = FakeCleanerSystem()
        await system.setRunning([RunningAppInfo(pid: 101, bundleID: "com.example.chatter", name: "Chatter", bundlePath: chatter.path)])
        await system.setSurvivors(quit: 1)
        let model = CleanerModel(dependencies: .fake(root: fixture.root, system: system))
        await model.open(chatter)
        let review = try XCTUnwrap(model.review)
        let request = RemovalRequest(app: review.app, items: review.items, selected: review.selected, purpose: .leftover,
                                     title: review.app.name, sizes: review.sizes)
        var finished: [RemovalOutcome] = []

        await model.prepare(request) { finished.append($0) }
        let confirming = Task { await model.confirmRemoval() }
        await eventually { model.forceQuit != nil }
        XCTAssertEqual(finished, [], "Nothing finished while the question is open")
        model.answerForceQuit(false)
        await confirming.value
        XCTAssertEqual(finished.map(\.cancelled), [true])

        await system.setRunning([])
        await model.prepare(request) { finished.append($0) }
        await model.confirmRemoval()
        XCTAssertEqual(finished.count, 2)
        XCTAssertEqual(finished.last, model.outcome)
        XCTAssertEqual(finished.last?.moved.count, 2)
    }

    // MARK: - Helpers

    /// The id the scanner gives an item: its standardized path, which spells the temporary folder `/var`.
    private func id(_ url: URL) -> String { url.standardizedFileURL.path }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Timed out", file: file, line: line)
    }
}
