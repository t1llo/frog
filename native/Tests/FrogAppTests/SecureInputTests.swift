import XCTest
@testable import FrogApp

final class SecureInputTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let waiting = SecureInput.Holder(pid: 700, name: "Bitwarden")

    func testPromptLeftInTheBackgroundIsExplainedOnceAfterItSettles() {
        var notice = SecureInputNotice()
        XCTAssertFalse(notice.poll(waiting, own: 1, now: start))
        XCTAssertFalse(notice.poll(waiting, own: 1, now: start.addingTimeInterval(1)))
        XCTAssertTrue(notice.poll(waiting, own: 1, now: start.addingTimeInterval(1.6)))
        XCTAssertFalse(notice.poll(waiting, own: 1, now: start.addingTimeInterval(2)))
        XCTAssertFalse(notice.poll(waiting, own: 1, now: start.addingTimeInterval(900)))
    }

    func testPromptTheUserIsTypingIntoAndFrogsOwnFieldsStaySilent() {
        var notice = SecureInputNotice()
        let typing = SecureInput.Holder(pid: 700, name: "Bitwarden", frontmost: true)
        for offset in [0.0, 2, 60] {
            XCTAssertFalse(notice.poll(typing, own: 1, now: start.addingTimeInterval(offset)))
            XCTAssertFalse(notice.poll(SecureInput.Holder(pid: 1, name: "Frog"), own: 1, now: start.addingTimeInterval(offset)))
        }
        XCTAssertFalse(notice.applicationChanged(now: start.addingTimeInterval(600)))
        // Leaving the prompt unanswered starts the wait from that moment.
        XCTAssertFalse(notice.poll(waiting, own: 1, now: start.addingTimeInterval(61)))
        XCTAssertTrue(notice.poll(waiting, own: 1, now: start.addingTimeInterval(63)))
    }

    func testReminderFollowsAnAppSwitchButNotOften() {
        var notice = SecureInputNotice()
        XCTAssertFalse(notice.applicationChanged(now: start))
        _ = notice.poll(waiting, own: 1, now: start)
        XCTAssertTrue(notice.poll(waiting, own: 1, now: start.addingTimeInterval(2)))
        XCTAssertFalse(notice.applicationChanged(now: start.addingTimeInterval(60)))
        XCTAssertTrue(notice.applicationChanged(now: start.addingTimeInterval(310)))
        XCTAssertFalse(notice.applicationChanged(now: start.addingTimeInterval(400)))
    }

    func testAnsweredPromptStartsANewEpisode() {
        var notice = SecureInputNotice()
        _ = notice.poll(waiting, own: 1, now: start)
        XCTAssertTrue(notice.poll(waiting, own: 1, now: start.addingTimeInterval(2)))
        XCTAssertFalse(notice.poll(nil, own: 1, now: start.addingTimeInterval(3)))
        XCTAssertFalse(notice.applicationChanged(now: start.addingTimeInterval(900)))
        XCTAssertFalse(notice.poll(waiting, own: 1, now: start.addingTimeInterval(10)))
        XCTAssertTrue(notice.poll(waiting, own: 1, now: start.addingTimeInterval(12)))
    }

    func testHolderIsNamedOnceWhileTheSameProcessKeepsTheKeyboard() {
        var cache = SecureInput.IdentityCache()
        var lookups: [pid_t] = []
        let lookup: (pid_t) -> SecureInput.Identity = { pid in
            lookups.append(pid)
            return SecureInput.Identity(application: URL(fileURLWithPath: "/Applications/App \(pid).app"), name: "App \(pid)")
        }
        // The switcher asks on every pass of its monitor, typing or not.
        for _ in 0..<5 { XCTAssertEqual(cache.identity(of: 700, lookup: lookup).name, "App 700") }
        XCTAssertEqual(lookups, [700])
        XCTAssertEqual(cache.identity(of: 701, lookup: lookup).application?.path, "/Applications/App 701.app")
        XCTAssertEqual(cache.identity(of: 701, lookup: lookup).name, "App 701")
        XCTAssertEqual(lookups, [700, 701])
        // Once the prompt is answered a later one is looked up afresh; process ids are reused.
        cache.forget()
        XCTAssertEqual(cache.identity(of: 701, lookup: lookup).name, "App 701")
        XCTAssertEqual(lookups, [700, 701, 701])
    }

    func testHolderThatCannotBeNamedYetIsAskedAboutAgain() {
        var cache = SecureInput.IdentityCache()
        var answers = [SecureInput.Identity(), SecureInput.Identity(application: URL(fileURLWithPath: "/Applications/Vault.app"), name: "Vault")]
        var lookups = 0
        let lookup: (pid_t) -> SecureInput.Identity = { _ in lookups += 1; return answers.count > 1 ? answers.removeFirst() : answers[0] }
        XCTAssertNil(cache.identity(of: 700, lookup: lookup).name)
        XCTAssertEqual(cache.identity(of: 700, lookup: lookup).name, "Vault")
        XCTAssertEqual(cache.identity(of: 700, lookup: lookup).name, "Vault")
        XCTAssertEqual(lookups, 2)
    }

    func testHelperProcessIsNamedAfterItsApplication() {
        let helper = URL(fileURLWithPath: "/Applications/Vault.app/Contents/Frameworks/Vault Helper (Renderer).app")
        XCTAssertEqual(SecureInput.application(helper).path, "/Applications/Vault.app")
        XCTAssertEqual(SecureInput.application(URL(fileURLWithPath: "/Applications/Vault.app")).path, "/Applications/Vault.app")
        XCTAssertEqual(SecureInput.summary(waiting), "Window switcher paused — Bitwarden is asking for a password")
        XCTAssertTrue(SecureInput.status(SecureInput.Holder()).hasPrefix("Paused — another app is asking for a password."))
    }
}
