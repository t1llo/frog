import XCTest
@testable import FrogCore

final class AnswerPromptTests: XCTestCase {
    func testFirstMessageLayout() {
        XCTAssertEqual(AnswerPrompt.firstMessage(selection: "river bank", context: "We had a picnic on the river bank before the storm.",
                                                 application: "Safari", replyLanguage: "German"), """
        App: Safari
        Reply language: German

        Selected text:
        ```
        river bank
        ```

        Surrounding text:
        ```
        We had a picnic on the river bank before the storm.
        ```
        """)
        XCTAssertEqual(AnswerPrompt.firstMessage(selection: "river bank", context: "On the river bank.", application: nil, replyLanguage: "German"), """
        Reply language: German

        Selected text:
        ```
        river bank
        ```

        Surrounding text:
        ```
        On the river bank.
        ```
        """)
        let withoutContext = """
        App: Notes
        Reply language: English

        Selected text:
        ```
        river bank
        ```
        """
        XCTAssertEqual(AnswerPrompt.firstMessage(selection: "river bank", context: nil, application: "Notes", replyLanguage: "English"), withoutContext)
        XCTAssertEqual(AnswerPrompt.firstMessage(selection: "river bank", context: "", application: "Notes", replyLanguage: "English"), withoutContext)
        XCTAssertEqual(AnswerPrompt.firstMessage(selection: "river bank", context: " river bank\n", application: "Notes", replyLanguage: "English"),
                       withoutContext, "Context equal to the selection adds nothing")
        XCTAssertEqual(AnswerPrompt.firstMessage(selection: "river bank", context: nil, application: "", replyLanguage: "English"),
                       "Reply language: English\n\nSelected text:\n```\nriver bank\n```")
    }

    func testFenceIsLongerThanAnyBacktickRun() {
        XCTAssertEqual(AnswerPrompt.fence(for: ["plain text", "a `tick` and ``two``"]), "```")
        XCTAssertEqual(AnswerPrompt.fence(for: ["```swift\nlet a = 1\n```"]), "````")
        XCTAssertEqual(AnswerPrompt.fence(for: ["plain", "````\ncode\n````"]), "`````")
        let message = AnswerPrompt.firstMessage(selection: "```code```", context: nil, application: nil, replyLanguage: "English")
        XCTAssertTrue(message.hasSuffix("Selected text:\n````\n```code```\n````"))
    }

    func testReplyLanguageNamesThePreferredLanguageInEnglish() {
        XCTAssertEqual(AnswerPrompt.replyLanguage(preferred: ["de-CH", "en"]), "German")
        XCTAssertEqual(AnswerPrompt.replyLanguage(preferred: ["pt-BR"]), "Portuguese")
        XCTAssertEqual(AnswerPrompt.replyLanguage(preferred: ["zh-Hans-CN"]), "Chinese")
        XCTAssertEqual(AnswerPrompt.replyLanguage(preferred: []), "English")
        XCTAssertEqual(AnswerPrompt.replyLanguage(preferred: ["xx-Invalid"]), "English")
    }

    func testMessagesAlternateFromUserToUser() {
        let first = "First"
        XCTAssertEqual(AnswerPrompt.messages(firstMessage: first, turns: [], pendingQuestion: nil), [user(first)])
        let one = [AnswerTurn(question: "", answer: "A0")]
        XCTAssertEqual(AnswerPrompt.messages(firstMessage: first, turns: one, pendingQuestion: nil), [user(first)])
        XCTAssertEqual(AnswerPrompt.messages(firstMessage: first, turns: one, pendingQuestion: "Q1"),
                       [user(first), assistant("A0"), user("Q1")])
        let two = one + [AnswerTurn(question: "Q1", answer: "A1")]
        XCTAssertEqual(AnswerPrompt.messages(firstMessage: first, turns: two, pendingQuestion: nil),
                       [user(first), assistant("A0"), user("Q1")])
        let four = two + [AnswerTurn(question: "Q2", answer: "A2"), AnswerTurn(question: "Q3", answer: "A3")]
        XCTAssertEqual(AnswerPrompt.messages(firstMessage: first, turns: four, pendingQuestion: nil),
                       [user(first), assistant("A0"), user("Q1"), assistant("A1"), user("Q2"), assistant("A2"), user("Q3")])
        let pending = AnswerPrompt.messages(firstMessage: first, turns: four, pendingQuestion: "Q4")
        XCTAssertEqual(pending.suffix(2), [assistant("A3"), user("Q4")])
        XCTAssertEqual(pending.count, 9)
        for messages in [pending, AnswerPrompt.messages(firstMessage: first, turns: four, pendingQuestion: nil)] {
            XCTAssertEqual(messages.first?.role, .user)
            XCTAssertEqual(messages.last?.role, .user)
            for (earlier, later) in zip(messages, messages.dropFirst()) { XCTAssertNotEqual(earlier.role, later.role) }
        }
    }

    func testTranscriptForCodingTools() {
        XCTAssertEqual(AnswerPrompt.transcript([user("Only\ntext")]), "Only\ntext")
        XCTAssertEqual(AnswerPrompt.transcript([user("First"), assistant("Answer"), user("Why?")]), """
        Conversation so far:

        User:
        First

        Assistant:
        Answer

        User:
        Why?

        Reply to the last User message only.
        """)
    }

    func testSelectionLimitFollowsTheModel() {
        XCTAssertEqual(AnswerPrompt.selectionLimit(local: true, kind: nil), 12_000)
        XCTAssertEqual(AnswerPrompt.selectionLimit(local: true, kind: .openAI), 12_000)
        for kind in [ProviderKind.ollama, .lmStudio, .compatible] {
            XCTAssertEqual(AnswerPrompt.selectionLimit(local: false, kind: kind), 12_000, "\(kind)")
        }
        for kind in [ProviderKind.openAI, .anthropic, .gemini, .claudeCode, .codex, .opencode] {
            XCTAssertEqual(AnswerPrompt.selectionLimit(local: false, kind: kind), 100_000, "\(kind)")
        }
        XCTAssertEqual(AnswerPrompt.selectionTooLong(limit: 12_000),
                       "Selection too long for this model. Select at most 12,000 characters, or choose a model with a larger context in the rule.")
        XCTAssertTrue(AnswerPrompt.selectionTooLong(limit: 100_000).contains("at most 100,000 characters"))
    }

    func testModelLabel() {
        XCTAssertEqual(AnswerPrompt.modelLabel(modelName: "Qwen3 4B", providerName: nil, local: true), "Qwen3 4B · Frog")
        XCTAssertEqual(AnswerPrompt.modelLabel(modelName: "gpt-5-mini", providerName: "OpenAI", local: false), "gpt-5-mini · OpenAI")
    }

    private func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, text: text) }
    private func assistant(_ text: String) -> ChatMessage { ChatMessage(role: .assistant, text: text) }
}
