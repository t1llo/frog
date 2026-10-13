import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class IdleUnloadChoicesTests: XCTestCase {
    func testLocalModelsCanStayLoadedForHalfAnHourOrAnHour() throws {
        XCTAssertEqual(PreferencesView.idleUnloadChoices, [120, 300, 900, 1800, 3600],
                       "Dictating a few times an hour must not reload the speech model every time")
        for seconds in PreferencesView.idleUnloadChoices {
            var configuration = Configuration()
            var workflow = configuration.preferences.workflowSettings
            workflow.idleUnloadSeconds = seconds
            configuration.preferences.workflows = workflow
            XCTAssertNoThrow(try ConfigurationFile.validate(configuration), "\(seconds) seconds must be a delay the configuration accepts")
            let saved = try ConfigurationFile.decode(ConfigurationFile.encode(configuration))
            XCTAssertEqual(saved.preferences.workflowSettings.idleUnloadSeconds, seconds)
        }
    }
}
