import XCTest
@testable import FrogCore

final class ReasoningFilterTests: XCTestCase {
    func testTextWithoutAThinkBlockPassesThrough() {
        let run = filter(["Hello", " world"])
        XCTAssertEqual(run.visible, "Hello world")
        XCTAssertEqual(run.thinking, [false, false])
        XCTAssertFalse(run.hid)
    }

    func testThinkBlockInOneChunkIsSwallowed() {
        let run = filter(["<think>plan the answer</think>\n\nAnswer."])
        XCTAssertEqual(run.visible, "Answer.")
        XCTAssertTrue(run.hid)
    }

    func testTagsSplitAcrossChunks() {
        let run = filter(["<th", "ink>pl", "an</thi", "nk>Answer"])
        XCTAssertEqual(run.visible, "Answer")
        XCTAssertEqual(run.thinking, [false, true, true, false])
    }

    func testWhitespaceBeforeTheBlock() {
        XCTAssertEqual(filter(["\n  ", "<think>x</think>", " Hi"]).visible, "Hi")
        XCTAssertEqual(filter(["  Hi"]).visible, "  Hi")
        XCTAssertEqual(filter(["<", "b>bold</b>"]).visible, "<b>bold</b>", "A tag that is not <think> is shown")
    }

    func testUnclosedBlockYieldsNothing() {
        let run = filter(["<think>long reasoning", " that never ends"])
        XCTAssertEqual(run.visible, "")
        XCTAssertTrue(run.hid)
        XCTAssertEqual(ReasoningFilter.onlyReasoning, "The model returned only its reasoning. Try again or choose another model.")
    }

    func testLaterThinkTagStaysVisible() {
        XCTAssertEqual(filter(["Answer <think>x</think> end"]).visible, "Answer <think>x</think> end")
        XCTAssertEqual(filter(["Answer ", "<think>x</think>"]).visible, "Answer <think>x</think>")
    }

    /// Streaming must end with the same text `LocalModels.textResult` keeps for Writing.
    func testVisibleTextMatchesTheWritingResult() {
        let fixtures = ["<think>\nLet me think.\n</think>\n\nThe answer.", "  Plain answer.\n", "\n<think>reasoning only"]
        for output in fixtures {
            let expected = textResult(output)
            var splits = [Array(output).map(String.init)]
            for index in 0...output.count {
                let cut = output.index(output.startIndex, offsetBy: index)
                splits.append([String(output[..<cut]), String(output[cut...])])
            }
            for chunks in splits {
                let visible = filter(chunks).visible.trimmingCharacters(in: .whitespacesAndNewlines)
                if let expected { XCTAssertEqual(visible, expected, "\(chunks)") } else { XCTAssertEqual(visible, "", "\(chunks)") }
            }
        }
    }

    /// The three outcomes of `LocalModels.textResult` for a completed generation; nil where it throws.
    private func textResult(_ output: String) -> String? {
        var output = output
        if let end = output.range(of: "</think>") { output = String(output[end.upperBound...]) }
        else if output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<think>") { return nil }
        let result = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private func filter(_ chunks: [String]) -> (visible: String, thinking: [Bool], hid: Bool) {
        var filter = ReasoningFilter()
        var visible = "", thinking: [Bool] = []
        for chunk in chunks {
            let result = filter.feed(chunk)
            visible += result.visible
            thinking.append(result.thinking)
        }
        visible += filter.finish()
        return (visible, thinking, filter.hidReasoning)
    }
}
