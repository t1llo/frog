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

    func testHelperProcessIsNamedAfterItsApplication() {
        let helper = URL(fileURLWithPath: "/Applications/Vault.app/Contents/Frameworks/Vault Helper (Renderer).app")
        XCTAssertEqual(SecureInput.application(helper).path, "/Applications/Vault.app")
        XCTAssertEqual(SecureInput.application(URL(fileURLWithPath: "/Applications/Vault.app")).path, "/Applications/Vault.app")
        XCTAssertEqual(SecureInput.summary(waiting), "Window switcher paused — Bitwarden is asking for a password")
        XCTAssertTrue(SecureInput.status(SecureInput.Holder()).hasPrefix("Paused — another app is asking for a password."))
    }
}
