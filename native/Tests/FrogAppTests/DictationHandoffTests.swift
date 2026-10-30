import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class DictationHandoffTests: XCTestCase {
    func testLinkNamesTheCallerTheRuleAndWhereTheTextGoes() throws {
        let link = URL(string: "frog://dictate?reply=yappa%3A%2F%2Ffrog%3Fkind%3Dtodo&caller=Yappa&rule=Dictation&state=abc")!
        let handoff = try XCTUnwrap(DictationHandoff.parse(link))
        XCTAssertEqual(handoff.command, .toggle)
        XCTAssertEqual(handoff.caller, "Yappa")
        XCTAssertEqual(handoff.reply.absoluteString, "yappa://frog?kind=todo")
        XCTAssertEqual(handoff.rule, "Dictation")
        XCTAssertEqual(handoff.state, "abc")
        XCTAssertEqual(try DictationHandoff.parse(URL(string: "frog://dictate/stop?reply=yappa://frog")!)?.command, .stop)
        XCTAssertEqual(try DictationHandoff.parse(URL(string: "frog://dictate/cancel?reply=yappa://frog")!)?.command, .cancel)
        // Without a name, the caller is named after its scheme.
        XCTAssertEqual(try DictationHandoff.parse(URL(string: "frog://dictate?reply=yappa://frog")!)?.caller, "Yappa")
        XCTAssertNil(try DictationHandoff.parse(URL(string: "frog://plugins/install?url=https://example.com")!))
    }

    func testTranscriptsNeverGoToWebPagesFilesOrFrogItself() {
        for reply in ["https://example.com/collect", "http://localhost", "file:///tmp/x", "frog://dictate", "javascript:alert(1)"] {
            let link = URL(string: "frog://dictate?reply=" + reply.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)!
            XCTAssertThrowsError(try DictationHandoff.parse(link), reply)
        }
        XCTAssertThrowsError(try DictationHandoff.parse(URL(string: "frog://dictate")!), "A reply link is required")
        XCTAssertThrowsError(try DictationHandoff.parse(URL(string: "frog://dictate/record?reply=yappa://frog")!))
    }

    func testReplyKeepsTheCallersQueryAndCarriesTextExactly() throws {
        let handoff = try XCTUnwrap(DictationHandoff.parse(URL(string: "frog://dictate?reply=yappa%3A%2F%2Ffrog%3Fkind%3Dnote&state=s1")!))
        let text = "Buy milk + eggs & call Ana? 100% 日本語 👩🏽‍💻\nSecond line"
        let items = URLComponents(url: handoff.reply(.text(text)), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "kind" }?.value, "note")
        XCTAssertEqual(items.first { $0.name == "status" }?.value, "done")
        XCTAssertEqual(items.first { $0.name == "text" }?.value, text)
        XCTAssertEqual(items.first { $0.name == "state" }?.value, "s1")
        let failed = URLComponents(url: handoff.reply(.failed("No model")), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(failed.first { $0.name == "status" }?.value, "failed")
        XCTAssertEqual(failed.first { $0.name == "error" }?.value, "No model")
    }
}
