import XCTest
@testable import FrogCore

final class LocalToolTests: XCTestCase {
    func testToolConnectionsRoundTripWithoutEndpointsAndResolveExplicitDefault() throws {
        for kind: ProviderKind in [.claudeCode, .codex, .opencode] {
            let provider = ProviderConfiguration(name: kind.title, kind: kind)
            var configuration = Configuration()
            configuration.providers = [provider]
            configuration.rules = [Rule(name: "Rewrite", providerID: provider.id, model: provider.model)]
            configuration.explicitRuleModels = true
            let roundTrip = try ConfigurationFile.decode(ConfigurationFile.encode(configuration))
            XCTAssertEqual(roundTrip.providers, [provider])
            XCTAssertEqual(provider.endpoint, "")
            let request = try LocalToolRequest(kind: XCTUnwrap(kind.localTool), text: "Synthetic input",
                                              rule: configuration.rules[0], providerModel: "other-model")
            XCTAssertEqual(request.model, "", "Explicit tool default must not inherit another provider model")
            var invalid = provider
            invalid.endpoint = "https://example.invalid"
            XCTAssertThrowsError(try ConfigurationFile.validate(provider: invalid))
            invalid = provider
            invalid.models.append(ProviderModel(id: "speech", category: .audio))
            XCTAssertThrowsError(try ConfigurationFile.validate(provider: invalid))
        }
    }

    func testPortableKindsAndDefaultOrCustomModels() throws {
        for kind in LocalToolKind.allCases {
            XCTAssertEqual(try JSONDecoder().decode(LocalToolKind.self, from: JSONEncoder().encode(kind)), kind)
            XCTAssertEqual(kind.suggestedModels.first?.id, "")
        }
        for model in ["", "sonnet", "openai/gpt-5.4#low", "provider/custom-model"] {
            XCTAssertNoThrow(try LocalToolRequest(kind: .opencode, model: model, instructions: "Rewrite", text: "Text"))
        }
        for model in ["--auto", "bad\nmodel", "$(command)", String(repeating: "a", count: 257)] {
            XCTAssertThrowsError(try LocalToolRequest(kind: .opencode, model: model, instructions: "Rewrite", text: "Text"))
        }
    }

    func testRequestBoundsAndLanguageExpansion() throws {
        XCTAssertThrowsError(try LocalToolRequest(kind: .claudeCode, instructions: "Rewrite", text: " "))
        XCTAssertThrowsError(try LocalToolRequest(kind: .claudeCode, instructions: "Rewrite", text: String(repeating: "a", count: 1_000_001)))
        var rule = Rule(name: "Translate", instructions: "Translate to {{language}}")
        rule.targetLanguage = "French"; rule.model = "sonnet"
        let request = try LocalToolRequest(kind: .claudeCode, text: "Hallo", rule: rule, providerModel: "haiku")
        XCTAssertEqual(request.instructions, "Translate to French")
        XCTAssertEqual(request.model, "sonnet")
        rule.targetLanguage = ""
        XCTAssertThrowsError(try LocalToolRequest(kind: .claudeCode, text: "Hallo", rule: rule))
    }
}
