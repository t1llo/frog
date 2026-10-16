import XCTest
@testable import FrogCore

final class RemovalPromptTests: XCTestCase {
    private let slack = AppIdentity(path: "/Applications/Slack.app", name: "Slack", bundleID: "com.example.slack")

    private func removal(_ name: String, kind: CleanerItemKind = .folder, owner: CleanerOwner = .user,
                         route: TrashRoute = .fileManager) -> PlannedRemoval {
        PlannedRemoval(item: CleanerItem(url: URL(fileURLWithPath: "/Library/Caches/" + name), kind: kind,
                                         confidence: .certain, reason: "", owner: owner), route: route)
    }

    private var bundle: PlannedRemoval {
        PlannedRemoval(item: CleanerItem(url: slack.url, kind: .application, confidence: .certain, reason: "The app itself."),
                       route: .finder)
    }

    private func items(_ count: Int) -> [PlannedRemoval] { (0..<count).map { removal("item\($0)") } }

    private func plan(app: AppIdentity?? = nil, removals: [PlannedRemoval]? = nil, refused: Int = 0, stop: Int = 0,
                      restart: Int = 0, total: Int64 = 1_400, incomplete: Bool = false, removesApp: Bool = false) -> RemovalPlan {
        let app: AppIdentity? = app ?? slack
        let removals = removals ?? items(1)
        return RemovalPlan(app: app, purpose: .leftover, removals: removals,
                           refused: (0..<refused).map { RemovalRefusal(item: removal("refused\($0)").item, reason: "No.") },
                           quitBundleIDs: removals.isEmpty ? [] : app?.bundleIDs ?? [],
                           launchLabelsToStop: (0..<stop).map { "agent\($0)" }, restartLabels: (0..<restart).map { "daemon\($0)" },
                           totalBytes: total, sizeIncomplete: incomplete, removesApp: removesApp)
    }

    private func prompt(_ plan: RemovalPlan, running: Bool = false, helpers: Int = 0,
                        automation: AutomationStatus? = nil) -> RemovalPrompt {
        RemovalPrompt(plan: plan, appIsRunning: running, runningHelpers: helpers, finderAutomation: automation,
                      formatBytes: { "\($0) B" })
    }

    // MARK: - Titles

    func testTitleNamesTheAppWhenItsBundleMoves() {
        XCTAssertEqual(prompt(plan(removals: [bundle], removesApp: true)).title, "Move Slack to the Trash?")
        XCTAssertEqual(prompt(plan(removals: [bundle] + items(1), removesApp: true)).title,
                       "Move Slack and 1 other item to the Trash?")
        XCTAssertEqual(prompt(plan(removals: [bundle] + items(11), removesApp: true)).title,
                       "Move Slack and 11 other items to the Trash?")
    }

    func testTitleCountsTheAppsItemsWhenTheBundleStays() {
        XCTAssertEqual(prompt(plan(removals: items(1))).title, "Move 1 item of Slack to the Trash?")
        XCTAssertEqual(prompt(plan(removals: items(12))).title, "Move 12 items of Slack to the Trash?")
    }

    func testTitleCountsItemsWithoutAnApp() {
        XCTAssertEqual(prompt(plan(app: .some(nil), removals: items(1))).title, "Move 1 item to the Trash?")
        XCTAssertEqual(prompt(plan(app: .some(nil), removals: items(12))).title, "Move 12 items to the Trash?")
        XCTAssertEqual(prompt(plan()).confirm, "Move to Trash")
        XCTAssertEqual(prompt(plan()).cancel, "Cancel")
    }

    // MARK: - Notes

    func testQuitNoteNamesTheAppAndItsRunningHelpers() {
        XCTAssertEqual(prompt(plan(), running: true).notes.first, "Frog quits Slack first.")
        XCTAssertEqual(prompt(plan(), running: true, helpers: 1).notes.first, "Frog quits Slack and 1 of its helpers first.")
        XCTAssertEqual(prompt(plan(), running: true, helpers: 3).notes.first, "Frog quits Slack and 3 of its helpers first.")
        XCTAssertEqual(prompt(plan(), helpers: 2).notes.first, "Frog quits 2 of Slack's helpers first.")
        XCTAssertFalse(prompt(plan()).notes.contains { $0.hasPrefix("Frog quits") })
        XCTAssertFalse(prompt(plan(app: .some(nil)), running: true).notes.contains { $0.hasPrefix("Frog quits") })
    }

    func testStopNoteCountsLaunchAgents() {
        XCTAssertTrue(prompt(plan(stop: 1)).notes.contains("Frog stops 1 background service first."))
        XCTAssertTrue(prompt(plan(stop: 2)).notes.contains("Frog stops 2 background services first."))
    }

    func testFinderNoteCountsItemsFinderMoves() {
        XCTAssertTrue(prompt(plan(removals: [removal("a", route: .finder)])).notes
            .contains("Finder moves 1 item. macOS asks once whether Frog may control Finder."))
        XCTAssertTrue(prompt(plan(removals: [bundle, removal("a", route: .finder), removal("b", route: .finder)], removesApp: true)).notes
            .contains("Finder moves 3 items. macOS asks once whether Frog may control Finder."))
        XCTAssertFalse(prompt(plan()).notes.contains { $0.hasPrefix("Finder moves") })
    }

    func testFinderNoteLeavesOutTheQuestionOnceFrogMayControlFinder() {
        let finderItems = [bundle, removal("a", route: .finder)]
        let allowed = prompt(plan(removals: finderItems, removesApp: true), automation: .allowed)
        XCTAssertTrue(allowed.notes.contains("Finder moves 2 items."))
        XCTAssertNil(allowed.finderDenied)
        XCTAssertTrue(prompt(plan(removals: finderItems, removesApp: true), automation: .notDetermined).notes
            .contains("Finder moves 2 items. macOS asks once whether Frog may control Finder."))
    }

    func testDeniedAutomationSaysWhatStaysBeforeAnythingMoves() {
        let allow = "Allow it in System Settings → Privacy & Security → Automation."
        let app = prompt(plan(removals: [bundle] + items(2), removesApp: true), automation: .denied)
        XCTAssertEqual(app.finderDenied, "Frog may not control Finder, so Slack and its files stay where they are. \(allow)")
        XCTAssertFalse(app.notes.contains { $0.hasPrefix("Finder moves") })
        XCTAssertEqual(prompt(plan(removals: [bundle], removesApp: true), automation: .denied).finderDenied,
                       "Frog may not control Finder, so Slack stays where it is. \(allow)")
        let containers = [removal("a", kind: .container, route: .finder), removal("b", kind: .container, route: .finder)]
        XCTAssertEqual(prompt(plan(removals: containers + items(1)), automation: .denied).finderDenied,
                       "Frog may not control Finder, so 2 items stay where they are. \(allow)")
        XCTAssertEqual(prompt(plan(removals: [containers[0]]), automation: .denied).finderDenied,
                       "Frog may not control Finder, so 1 item stays where it is. \(allow)")
        XCTAssertNil(prompt(plan(), automation: .denied).finderDenied, "Nothing goes through Finder")
    }

    func testAdministratorNoteSaysFrogNeverSeesThePassword() {
        let one = [removal("a", owner: .administrator, route: .finder)]
        XCTAssertTrue(prompt(plan(removals: one)).notes
            .contains("1 item belongs to the system. Finder asks for your administrator password; Frog never sees it."))
        let two = one + [removal("b", owner: .administrator, route: .finder)]
        XCTAssertTrue(prompt(plan(removals: two)).notes
            .contains("2 items belong to the system. Finder asks for your administrator password; Frog never sees it."))
    }

    func testRestartNoteCountsDaemonsAndHelperTools() {
        XCTAssertTrue(prompt(plan(restart: 1)).notes.contains("1 background service stops after you restart your Mac."))
        XCTAssertTrue(prompt(plan(restart: 2)).notes.contains("2 background services stop after you restart your Mac."))
    }

    func testSystemExtensionNoteOnlyWhenTheBundleMoves() {
        var app = slack
        app.hasSystemExtensions = true
        let note = "Slack's system extension is removed with the app. macOS may ask you to confirm."
        XCTAssertTrue(prompt(plan(app: app, removals: [bundle], removesApp: true)).notes.contains(note))
        XCTAssertFalse(prompt(plan(app: app, removals: items(2))).notes.contains(note))
        XCTAssertFalse(prompt(plan(removals: [bundle], removesApp: true)).notes.contains(note))
    }

    func testRefusalNoteCountsItemsLeftOut() {
        XCTAssertTrue(prompt(plan(refused: 1)).notes.contains("Frog leaves out 1 item it may not move."))
        XCTAssertTrue(prompt(plan(refused: 2)).notes.contains("Frog leaves out 2 items it may not move."))
    }

    func testSpaceNoteSaysAtLeastWhenASizeIsUnknown() {
        XCTAssertTrue(prompt(plan(total: 1_400)).notes.contains("The space (1400 B) is freed when you empty the Trash."))
        XCTAssertTrue(prompt(plan(total: 1_400, incomplete: true)).notes
            .contains("The space (at least 1400 B) is freed when you empty the Trash."))
    }

    func testPutBackNoteNamesFrogForTheUsersOwnItems() {
        XCTAssertEqual(prompt(plan()).notes, [
            "The space (1400 B) is freed when you empty the Trash.",
            "You can put items back from Recently moved in Frog, or from the Trash."
        ])
    }

    func testPutBackNoteNamesFinderWhenSystemItemsMove() {
        let notes = prompt(plan(removals: [removal("a", owner: .administrator, route: .finder)])).notes
        XCTAssertEqual(notes.last,
                       "Put back items that belong to the system with Put Back in Finder's Trash; Frog puts back only your own items.")
        XCTAssertFalse(notes.contains("You can put items back from Recently moved in Frog, or from the Trash."))
    }

    func testNotesKeepTheirOrder() {
        var app = slack
        app.hasSystemExtensions = true
        let removals = [bundle, removal("a", owner: .administrator, route: .finder)] + items(1)
        let notes = prompt(plan(app: app, removals: removals, refused: 1, stop: 2, restart: 1, total: 99, incomplete: true,
                                removesApp: true), running: true, helpers: 1).notes

        XCTAssertEqual(notes, [
            "Frog quits Slack and 1 of its helpers first.",
            "Frog stops 2 background services first.",
            "Finder moves 2 items. macOS asks once whether Frog may control Finder.",
            "1 item belongs to the system. Finder asks for your administrator password; Frog never sees it.",
            "1 background service stops after you restart your Mac.",
            "Slack's system extension is removed with the app. macOS may ask you to confirm.",
            "Frog leaves out 1 item it may not move.",
            "The space (at least 99 B) is freed when you empty the Trash.",
            "Put back items that belong to the system with Put Back in Finder's Trash; Frog puts back only your own items."
        ])
    }
}
