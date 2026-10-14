import XCTest
@testable import FrogCore

final class DownloadProgressTests: XCTestCase {
    func testTheLineGivesTheBytesOfTheSizeTheSpeedAndTheTimeLeft() {
        let progress = DownloadProgress(fraction: 0.412, bytesReceived: 412_000_000, bytesExpected: 1_000_000_000, bytesPerSecond: 8_100_000)
        XCTAssertEqual(progress.summary, "412 MB of 1 GB · 8.1 MB/s · about 1 min left")
    }
    func testTheTimeLeftIsRoundedToWholeMinutesOrHours() {
        XCTAssertEqual(DownloadProgress.timeLeft(20), "less than a minute left")
        XCTAssertEqual(DownloadProgress.timeLeft(14 * 60 + 40), "about 15 min left")
        XCTAssertEqual(DownloadProgress.timeLeft(3 * 3600 + 100), "about 3 h left")
    }
    func testAnUnknownTotalLeavesOutTheSizeAndTheTimeLeft() {
        let progress = DownloadProgress(fraction: 0.3, bytesReceived: 5_000_000, bytesPerSecond: 1_000_000)
        XCTAssertEqual(progress.summary, "5 MB · 1 MB/s")
    }
    func testASpeedThatIsNotSteadyYetPromisesNoTimeLeft() {
        let progress = DownloadProgress(fraction: 0.01, bytesReceived: 10_000_000, bytesExpected: 1_000_000_000)
        XCTAssertEqual(progress.summary, "10 MB of 1 GB")
    }
    func testADownloadThatReceivesNothingSaysThatItHasStalled() {
        let progress = DownloadProgress(fraction: 0.2, bytesReceived: 200_000_000, bytesExpected: 1_000_000_000, bytesPerSecond: 0)
        XCTAssertEqual(progress.summary, "200 MB of 1 GB · stalled", "A speed of zero must not promise a time left")
    }
    func testADownloadThatReportsOnlyAFractionHasNoLine() {
        XCTAssertNil(DownloadProgress(fraction: 0.5).summary)
        XCTAssertEqual(DownloadProgress(fraction: 0, bytesReceived: 0, bytesExpected: 1_000_000).summary, "0 bytes of 1 MB")
        XCTAssertTrue(DownloadProgress.filesAreIn.hasAllFiles)
        XCTAssertFalse(DownloadProgress(fraction: 0.999).hasAllFiles)
    }
}
