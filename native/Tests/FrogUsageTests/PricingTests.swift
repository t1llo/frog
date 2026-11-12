import XCTest
@testable import FrogUsage

final class PricingTests: XCTestCase {
    /// Claude Fable 5.2: $8 input, $40 output, $0.20 cache reads per million; fast mode doubles it.
    func testFableFiveTwoIsPriced() throws {
        let million = 1_000_000
        let cost = try XCTUnwrap(apiCost(model: "claude-fable-5-2", input: million, output: million, cacheWrite5m: million,
                                         cacheWrite1h: million, cacheRead: million, fast: false))
        XCTAssertEqual(cost, 8 + 40 + 10 + 16 + 0.20, accuracy: 1e-9)
        let fast = try XCTUnwrap(apiCost(model: "claude-fable-5-2", input: million, output: 0, cacheWrite5m: 0,
                                         cacheWrite1h: 0, cacheRead: 0, fast: true))
        XCTAssertEqual(fast, 16, accuracy: 1e-9)
        XCTAssertNotNil(apiPrices["claude-mythos-5-2"])
        XCTAssertEqual(modelName("claude-fable-5-2"), "Fable 5.2")
    }
}
