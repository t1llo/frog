import XCTest
@testable import FrogApp

/// Random-looking stand-ins for keys, made at run time. Every key-like text in these tests is joined
/// from parts, so that the source holds nothing a secret scanner, or a reader, could take for a real key.
enum SyntheticKey {
    static let mixed = "aB3cD4eF5gH6iJ7kL8mN9oP0qRsTuVwXyZ"
    static let lower = "a1b2c3d4e5f6g7h8i9j0klmnopqrstuvwxyz"
    static let upper = "A1B2C3D4E5F6G7H8J9K0LMNPQRSTUVWXYZ"
    static let hex = "0123456789abcdef"

    /// The same text for the same arguments, with digits spread through it as in a real key.
    static func make(_ count: Int, from alphabet: String = mixed, seed: UInt64 = 7) -> String {
        let characters = Array(alphabet)
        var state = seed
        return String((0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return characters[Int((state >> 33) % UInt64(characters.count))]
        })
    }
}

/// Which copied texts clipboard history masks, and which it leaves readable.
final class ClipboardSecretTests: XCTestCase {
    private func key(_ count: Int, _ alphabet: String = SyntheticKey.mixed) -> String { SyntheticKey.make(count, from: alphabet) }

    func testKnownKeyShapesAreFound() {
        let cases: [(String, ClipboardSecret, String)] = [
            ("sk-" + "ant-" + "api03-" + key(90), .apiKey, "Anthropic"),
            ("sk-" + "proj-" + key(60), .apiKey, "OpenAI"),
            ("sk-" + "or-v1-" + key(64, SyntheticKey.hex), .apiKey, "OpenRouter"),
            ("AI" + "za" + key(35), .apiKey, "Google"),
            ("hf" + "_" + key(34), .apiKey, "Hugging Face"),
            ("gs" + "k_" + key(52), .apiKey, "Groq"),
            ("AK" + "IA" + key(16, SyntheticKey.upper), .apiKey, "AWS"),
            ("sk" + "_live_" + key(24), .apiKey, "Stripe"),
            ("SG" + "." + key(22) + "." + key(43), .apiKey, "SendGrid"),
            ("gh" + "p_" + key(36), .token, "GitHub"),
            ("github" + "_pat_" + key(82), .token, "GitHub fine-grained"),
            ("gl" + "pat-" + key(20), .token, "GitLab"),
            ("np" + "m_" + key(36), .token, "npm"),
            ("xo" + "xb-" + key(12, "0123456789") + "-" + key(24), .token, "Slack"),
            ("ey" + "J" + key(20) + ".ey" + "J" + key(30) + "." + key(43), .token, "JSON Web Token"),
            ("ya" + "29." + key(60), .token, "Google access token"),
            ("-----BEGIN " + "OPENSSH PRIVATE KEY-----\n" + key(64) + "\n-----END OPENSSH PRIVATE KEY-----", .privateKey, "SSH"),
            ("-----BEGIN " + "RSA PRIVATE KEY-----", .privateKey, "RSA"),
            ("-----BEGIN PGP " + "PRIVATE KEY BLOCK-----", .privateKey, "PGP"),
            ("AGE-SECRET" + "-KEY-1" + key(58, SyntheticKey.upper), .privateKey, "age"),
            ("postgres://app:" + "Synth3ticPass" + "@db.example.com:5432/app", .credentials, "database address"),
            ("Authorization: " + "Basic " + key(28), .credentials, "header"),
        ]
        for (text, kind, name) in cases {
            XCTAssertEqual(ClipboardSecret.detect(text), kind, name)
            // Inside a longer copy, such as a line of a config file or a sentence.
            XCTAssertNotNil(ClipboardSecret.detect("Use this one:\n" + text + "\nthanks"), name)
        }
    }

    func testAPrefixInsideALongerWordIsNotOne() {
        XCTAssertNil(ClipboardSecret.detect("disk-" + "utility-overview-and-tips"))
        XCTAssertNil(ClipboardSecret.detect("the task-" + "runner-configuration-guide"))
    }

    func testNamedValuesAreFound() {
        let cases: [(String, ClipboardSecret)] = [
            ("API_KEY=" + key(32), .apiKey),
            ("DB_PASSWORD=" + "Synth3tic&Pass", .password),
            ("\"password\": \"" + "correct-horse" + "\"", .password),
            ("Passwort: " + "Sommer2024!", .password),
            ("client_secret: '" + key(30) + "'", .apiKey),
            ("access_token=" + key(40), .token),
            ("X-Api-Key: " + key(32), .apiKey),
            ("SECRET_KEY = \"" + key(40) + "\"", .apiKey),
            ("let apiToken = \"" + key(32) + "\"", .token),
        ]
        for (text, kind) in cases { XCTAssertEqual(ClipboardSecret.detect(text), kind, text.prefix(14) + "…") }
    }

    func testAWordAloneThatReadsLikeAPasswordOrAKey() {
        XCTAssertEqual(ClipboardSecret.detect("Tr0ub4dor&3"), .password)
        XCTAssertEqual(ClipboardSecret.detect("  Summer2024!\n"), .password)
        XCTAssertEqual(ClipboardSecret.detect(key(40)), .token)
        XCTAssertEqual(ClipboardSecret.detect("here it is: " + key(40)), .token)
    }

    func testOrdinaryTextStaysReadable() {
        let texts = [
            "", "Hello, world", "See you at 10:30 tomorrow", "Reset your password in Settings.",
            "8803af4", key(40, SyntheticKey.hex), "E7A2D4E5-1CBC-41DB-8B3A-7114DC77943D",
            "https://github.com/t1llo/frog/commit/8803af4", "someone@example.com",
            "/Users/someone/Documents/Report2024.pdf", "~/.ssh/config", "README.md", "Frog-macOS.zip",
            "v1.0.41", "macOS 14.4.1", "x86_64-apple-macosx14.0", "1,234.56", "2026-10-28", "+41 79 123 45 67",
            "#WWDC2026", "#FF00AA", "@frogapp", "MacBookPro18,3", "items[0]", "getItem(12)", "=SUM(A1:B2)",
            "ClipboardHistoryControllerTests", "testSensitiveEntryIsCopiedForThisMacOnly",
            "let apiKey = config.apiKey", "password: String", "token: optional", "token_type: bearer",
            "let token = try await fetchToken()", "static let keyName = \"OPENAI_API_KEY\"",
            "let apiKey = UserDefaults.standard.string(forKey: \"apiKey\")",
            "\"password_label\" = \"Password\";", "secretName: my-app-secret", "tokenizer: GPT2Tokenizer1",
            "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}", "export PATH=$HOME/bin:$PATH",
            "SecureField(\"Password\", text: $password)", "[Frog](https://example.com)",
            "The bearer of this letter is a friend.",
        ]
        for text in texts { XCTAssertNil(ClipboardSecret.detect(text), text) }
    }

    func testALongCopyIsReadOnlyAtItsStart() {
        let log = String(repeating: "Line of an ordinary build log, nothing to hide here.\n", count: 12_000)
        let start = Date()
        XCTAssertNil(ClipboardSecret.detect(log))
        XCTAssertNotNil(ClipboardSecret.detect("gh" + "p_" + key(36) + "\n" + log))
        XCTAssertNil(ClipboardSecret.detect(log + "gh" + "p_" + key(36)), "Past the first 64 KB nothing is read")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "A long copy does not hold up the next one")
    }
}
