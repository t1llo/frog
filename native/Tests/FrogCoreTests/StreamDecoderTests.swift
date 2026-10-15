import XCTest
@testable import FrogCore

final class StreamDecoderTests: XCTestCase {
    func testOpenAIStyleDeltasArriveInOrderAndReasoningIsOnlyThinking() throws {
        for kind in [ProviderKind.openAI, .compatible, .lmStudio] {
            let events = try decode(kind, [
                ": keep-alive",
                "",
                #"data: {"choices":[{"delta":{"role":"assistant","content":""}}]}"#,
                #"data: {"choices":[{"delta":{"reasoning_content":"secret plan"}}]}"#,
                #"data: {"choices":[{"delta":{"reasoning":"more"}}]}"#,
                #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#,
                #"data:{"choices":[{"delta":{"content":", world"},"finish_reason":"stop"}]}"#,
                #"data: {"choices":[],"usage":{"total_tokens":3}}"#,
                "data: [DONE]",
                #"data: {"choices":[{"delta":{"content":"after done"}}]}"#
            ])
            XCTAssertEqual(events, [.thinking, .thinking, .text("Hello"), .text(", world")], "\(kind)")
        }
    }

    func testOpenAILengthIsTruncatedAndContentFilterIsDeclined() throws {
        XCTAssertEqual(try decode(.openAI, [#"data: {"choices":[{"delta":{"content":"Part"},"finish_reason":"length"}]}"#, "data: [DONE]"]),
                       [.text("Part"), .truncated])
        XCTAssertEqual(try decode(.openAI, [#"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"#]), [.truncated],
                       "A truncated answer without text is not an empty answer")
        assertError(.openAI, [#"data: {"choices":[{"delta":{},"finish_reason":"content_filter"}]}"#],
                    "The provider declined to answer this request.")
        assertError(.compatible, [#"data: {"error":{"message":"private text","type":"server_error"}}"#],
                    "The provider stopped with an error.")
        assertError(.compatible, [#"{"error":{"message":"private text","code":"rate_limit_exceeded"}}"#],
                    "The provider's rate limit was reached.")
    }

    func testAnthropicEventsDecodeTextThinkingAndStop() throws {
        let events = try decode(.anthropic, [
            "event: message_start",
            #"data: {"type":"message_start","message":{"id":"m","content":[]}}"#,
            "event: ping",
            #"data: {"type":"ping"}"#,
            "event: content_block_start",
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"private"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"One"}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":" two"}}"#,
            #"data: {"type":"content_block_stop","index":1}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            "event: message_stop",
            #"data: {"type":"message_stop"}"#
        ])
        XCTAssertEqual(events, [.thinking, .thinking, .text("One"), .text(" two")])
        XCTAssertEqual(try decode(.anthropic, [#"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Cut"}}"#,
                                               #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#]),
                       [.text("Cut"), .truncated])
    }

    func testAnthropicErrorsNameTheirKindWithoutTheirMessage() {
        assertError(.anthropic, ["event: error", #"data: {"type":"error","error":{"type":"overloaded_error","message":"private text"}}"#],
                    "The provider is overloaded. Try again shortly.")
        assertError(.anthropic, ["event: error", #"data: {"type":"error","error":{"type":"rate_limit_error","message":"private text"}}"#],
                    "The provider's rate limit was reached.")
        assertError(.anthropic, ["event: error", #"data: {"type":"error","error":{"type":"api_error","message":"private text"}}"#],
                    "The provider stopped with an error.")
        // The event name alone identifies an error whose payload has no type.
        assertError(.anthropic, ["event: error", #"data: {"error":{"type":"overloaded_error"}}"#],
                    "The provider is overloaded. Try again shortly.")
    }

    func testGeminiSeparatesThoughtsTruncatesAndDeclines() throws {
        let events = try decode(.gemini, [
            #"data: {"candidates":[{"content":{"role":"model","parts":[{"text":"hidden","thought":true}]}}]}"#,
            "",
            #"data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Bon"}]}}]}"#,
            #"data: {"candidates":[{"content":{"role":"model","parts":[{"text":"jour"}]},"finishReason":"STOP"}]}"#
        ])
        XCTAssertEqual(events, [.thinking, .text("Bon"), .text("jour")])
        XCTAssertEqual(try decode(.gemini, [#"data: {"candidates":[{"content":{"parts":[{"text":"Cut"}]},"finishReason":"MAX_TOKENS"}]}"#]),
                       [.text("Cut"), .truncated])
        for reason in ["SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "RECITATION"] {
            assertError(.gemini, [#"data: {"candidates":[{"content":{"parts":[{"text":"x"}]},"finishReason":"\#(reason)"}]}"#],
                        "The provider declined to answer this request.")
        }
        assertError(.gemini, [#"data: {"promptFeedback":{"blockReason":"SAFETY"}}"#], "The provider declined to answer this request.")
        assertError(.gemini, [#"data: {"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message":"private"}}"#],
                    "The provider's rate limit was reached.")
    }

    func testOllamaLinesDecodeTextThinkingLengthAndErrors() throws {
        let events = try decode(.ollama, [
            #"{"message":{"role":"assistant","content":"","thinking":"hmm"},"done":false}"#,
            #"{"message":{"role":"assistant","content":"Hi"},"done":false}"#,
            "",
            #"{"message":{"role":"assistant","content":" there"},"done":false}"#,
            #"{"message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}"#,
            #"{"message":{"role":"assistant","content":"ignored"},"done":false}"#
        ])
        XCTAssertEqual(events, [.thinking, .text("Hi"), .text(" there")])
        XCTAssertEqual(try decode(.ollama, [#"{"message":{"content":"Cut"},"done":false}"#, #"{"message":{"content":""},"done":true,"done_reason":"length"}"#]),
                       [.text("Cut"), .truncated])
        assertError(.ollama, [#"{"error":"model 'private' not found"}"#], "The provider stopped with an error.")
    }

    func testMalformedJSONAndMissingTextFail() {
        assertError(.openAI, ["data: {not json"], "The provider returned malformed JSON.")
        assertError(.ollama, ["not json"], "The provider returned malformed JSON.")
        assertError(.anthropic, ["data: [1, 2]"], "The provider returned malformed JSON.")
        assertError(.openAI, ["data: [DONE]"], "The provider returned no text. Check the model and try again.")
        assertError(.openAI, [#"data: {"choices":[{"delta":{"content":" \n"}}]}"#], "The provider returned no text. Check the model and try again.")
        assertError(.gemini, [], "The provider returned no text. Check the model and try again.")
    }

    func testUnicodeAndCarriageReturnsSurvive() throws {
        let events = try decode(.openAI, [#"data: {"choices":[{"delta":{"content":"🐸 蛙 "}}]}"# + "\r",
                                          #"data: {"choices":[{"delta":{"content":"grenouilleé"}}]}"#])
        XCTAssertEqual(events, [.text("🐸 蛙 "), .text("grenouilleé")])
    }

    func testTooMuchTextEndsTheAnswer() throws {
        var decoder = StreamDecoder(kind: .ollama)
        let chunk = String(repeating: "a", count: 1_024 * 1_024)
        let line = #"{"message":{"content":"\#(chunk)"},"done":false}"#
        for _ in 0..<8 { _ = try decoder.feed(line: line) }
        XCTAssertThrowsError(try decoder.feed(line: line)) { XCTAssertEqual($0.localizedDescription, "The answer was too long.") }
    }

    // MARK: Helpers

    private func decode(_ kind: ProviderKind, _ lines: [String]) throws -> [AnswerEvent] {
        var decoder = StreamDecoder(kind: kind)
        var events: [AnswerEvent] = []
        for line in lines { events += try decoder.feed(line: line) }
        events += try decoder.finish()
        return events
    }

    private func assertError(_ kind: ProviderKind, _ lines: [String], _ message: String, line: UInt = #line) {
        XCTAssertThrowsError(try decode(kind, lines), line: line) { error in
            XCTAssertEqual(error.localizedDescription, message, line: line)
            XCTAssertFalse(error.localizedDescription.contains("private"), line: line)
        }
    }
}
