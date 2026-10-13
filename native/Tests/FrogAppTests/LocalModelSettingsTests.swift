import XCTest
import FrogCore
@testable import FrogApp

final class LocalModelSettingsTests: XCTestCase {
    /// `model-idle-seconds` takes any number of seconds up to an hour, not only the menu's choices.
    func testTheIdleTimeIsShownAsItIsSaved() {
        XCTAssertEqual(LocalModelSettings.idleTitle(seconds: 0), "Immediately")
        XCTAssertEqual(LocalModelSettings.idleTitle(seconds: 45), "45 sec", "Less than a minute is not 0 min")
        XCTAssertEqual(LocalModelSettings.idleTitle(seconds: 90), "1 min 30 sec", "A minute and a half is not 1 min")
        XCTAssertEqual(LocalModelSettings.idleTitle(seconds: 3599), "59 min 59 sec")
        XCTAssertEqual(LocalModelSettings.idleTitle(seconds: 3600), "60 min")
    }

    func testTheChoicesOfTheMenuReadAsBefore() {
        XCTAssertEqual([120, 300, 900].map(LocalModelSettings.idleTitle), ["2 min", "5 min", "15 min"])
    }

    func testTheModelsInMemoryAreNamedInTheOrderOfTheCatalog() {
        let catalog = LocalModelDescriptor.catalog
        XCTAssertNil(LocalModelSettings.inMemory([], catalog: catalog), "Nothing is loaded, so the row has nothing to add")
        XCTAssertEqual(LocalModelSettings.inMemory(["qwen-1.7b"], catalog: catalog), "Qwen3 1.7B · 4-bit")
        XCTAssertEqual(LocalModelSettings.inMemory(["qwen-1.7b", "parakeet-v3"], catalog: catalog), "NVIDIA Parakeet TDT v3, Qwen3 1.7B · 4-bit")
    }

    func testAModelThatLeftTheCatalogIsStillNamed() {
        XCTAssertEqual(LocalModelSettings.inMemory(["hf-gone", "whisper-tiny"], catalog: LocalModelDescriptor.catalog), "Whisper Tiny, hf-gone")
    }
}
