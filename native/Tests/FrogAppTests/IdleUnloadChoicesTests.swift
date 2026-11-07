import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class IdleUnloadChoicesTests: XCTestCase {
    func testLocalModelsCanStayLoadedForHoursOrUntilUnloadedByHand() throws {
        XCTAssertEqual(LocalModelSettingsView.idleUnloadChoices, [0, 120, 300, 900, 1800, 3600, 7200, 14400, 28800, WorkflowPreferences.keepLoaded],
                       "Dictating a few times a day must not reload the speech model every time")
        for seconds in LocalModelSettingsView.idleUnloadChoices {
            var configuration = Configuration()
            var workflow = configuration.preferences.workflowSettings
            workflow.idleUnloadSeconds = seconds
            workflow.speechIdleUnloadSeconds = seconds
            configuration.preferences.workflows = workflow
            XCTAssertNoThrow(try ConfigurationFile.validate(configuration), "\(seconds) seconds must be a delay the configuration accepts")
            let saved = try ConfigurationFile.decode(ConfigurationFile.encode(configuration))
            XCTAssertEqual(saved.preferences.workflowSettings.idleUnloadSeconds, seconds)
            XCTAssertEqual(saved.preferences.workflowSettings.speechIdleUnloadSeconds, seconds)
        }
    }

    func testTheSpeechModelFollowsTheOtherModelsUntilItHasItsOwnDelay() throws {
        var workflow = WorkflowPreferences()
        workflow.idleUnloadSeconds = 300
        XCTAssertEqual(workflow.effectiveSpeechIdleUnloadSeconds, 300, "Settings saved before the speech delay existed keep their behaviour")
        workflow.speechIdleUnloadSeconds = WorkflowPreferences.keepLoaded
        XCTAssertEqual(workflow.effectiveSpeechIdleUnloadSeconds, WorkflowPreferences.keepLoaded)
        var configuration = Configuration()
        workflow.speechIdleUnloadSeconds = 28801
        configuration.preferences.workflows = workflow
        XCTAssertThrowsError(try ConfigurationFile.validate(configuration), "Longer than eight hours is not a delay Frog offers")
    }
}
