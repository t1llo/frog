import XCTest
import FrogCore
@testable import FrogApp

final class DownloadMeterTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: TimeInterval = 100
        var now: TimeInterval { lock.withLock { time } }
        func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
    }
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }
    private func land(_ name: String, bytes: Int) throws {
        let file = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: file)
    }
    /// Like the libraries' snapshot: one unit per file, whatever its size.
    private func snapshotProgress(files: Int) -> (Progress, [Progress]) {
        let parent = Progress(totalUnitCount: Int64(files))
        return (parent, (0..<files).map { _ in Progress(totalUnitCount: 100, parent: parent, pendingUnitCount: 1) })
    }

    func testTheBarFollowsTheBytesAndNotTheNumberOfFiles() throws {
        let clock = Clock()
        let meter = DownloadMeter(folder: folder, expected: 1_000_000, now: { clock.now })
        let (progress, files) = snapshotProgress(files: 4)
        // Three small configuration files land before the weights.
        for (index, file) in files.prefix(3).enumerated() { try land("config-\(index).json", bytes: 100); file.completedUnitCount = 100 }
        var update = meter.snapshot(progress)
        XCTAssertEqual(progress.fractionCompleted, 0.75, accuracy: 0.001)
        XCTAssertEqual(update.bytesReceived, 300)
        XCTAssertLessThan(update.fraction, 0.01, "Three small files are not three quarters of the model")

        // The weights stream in: the library reports their speed, not their bytes.
        files[3].completedUnitCount = 10
        progress.setUserInfoObject(100_000.0, forKey: .throughputKey)
        clock.advance(1)
        update = meter.snapshot(progress)
        XCTAssertEqual(update.bytesReceived, 100_300)
        XCTAssertEqual(update.bytesExpected, 1_000_000)
        XCTAssertEqual(update.fraction, 0.1003, accuracy: 0.0001)
    }

    func testTheSpeedIsAveragedOverSecondsAndAStallSaysSo() throws {
        let clock = Clock()
        let meter = DownloadMeter(folder: folder, expected: 10_000_000, now: { clock.now })
        let (progress, files) = snapshotProgress(files: 1)
        progress.setUserInfoObject(100_000.0, forKey: .throughputKey)
        var update = meter.snapshot(progress)
        for second in 1...Int(DownloadMeter.window) {
            files[0].completedUnitCount = Int64(second)
            clock.advance(1); update = meter.snapshot(progress)
            if Double(second) < DownloadMeter.steady { XCTAssertNil(update.bytesPerSecond, "A first burst promises no time left") }
        }
        XCTAssertEqual(try XCTUnwrap(update.bytesPerSecond), 100_000, accuracy: 1)
        XCTAssertTrue(update.summary?.hasSuffix("min left") == true, update.summary ?? "no line")

        // Nothing arrives: the library sends heartbeats without a speed.
        progress.setUserInfoObject(nil, forKey: .throughputKey)
        for _ in 0...Int(DownloadMeter.window) { clock.advance(1); update = meter.snapshot(progress) }
        XCTAssertEqual(update.bytesPerSecond, 0)
        XCTAssertEqual(update.summary, "500 kB of 10 MB · stalled")
    }

    func testOnlyTheLibraryCanSayThatTheFilesAreIn() throws {
        let clock = Clock()
        let meter = DownloadMeter(folder: folder, expected: 1_000, now: { clock.now })
        let (progress, files) = snapshotProgress(files: 2)
        try land("weights", bytes: 2_000); files[0].completedUnitCount = 100
        var update = meter.snapshot(progress)
        XCTAssertEqual(update.bytesReceived, 1_000, "More than the expected size is not shown")
        XCTAssertEqual(update.fraction, 0.999, "A model whose size is off must not claim to be complete")
        XCTAssertFalse(update.hasAllFiles)
        files[1].completedUnitCount = 100
        update = meter.snapshot(progress)
        XCTAssertTrue(update.hasAllFiles)
    }

    func testADownloadLargerThanItsSizeKeepsItsSpeed() throws {
        let clock = Clock()
        let meter = DownloadMeter(folder: folder, expected: 1_000, now: { clock.now })
        var update = meter.written(fraction: 0.5)
        // The weights on the source grew since their size was recorded.
        for second in 1...2 * Int(DownloadMeter.window) {
            try land("weights", bytes: 1_000 * second)
            clock.advance(1); update = meter.written(fraction: 0.5)
        }
        XCTAssertEqual(update.bytesReceived, 1_000)
        XCTAssertEqual(update.fraction, 0.999)
        XCTAssertEqual(try XCTUnwrap(update.bytesPerSecond), 1_000, accuracy: 1, "Bytes still arrive: the download has not stalled")
        XCTAssertFalse(update.summary?.contains("stalled") == true, update.summary ?? "no line")
    }

    func testAnUnknownSizeKeepsTheLibrarysFraction() throws {
        let meter = DownloadMeter(folder: folder, expected: nil)
        let (progress, files) = snapshotProgress(files: 2)
        try land("weights", bytes: 500); files[0].completedUnitCount = 100
        let update = meter.snapshot(progress)
        XCTAssertEqual(update.fraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(update.bytesReceived, 500)
        XCTAssertNil(update.bytesExpected)
    }

    func testAWrittenDownloadCountsItsHiddenPartialFile() throws {
        // WhisperKit appends to a partial file under the model folder's hidden cache.
        let meter = DownloadMeter(folder: folder, expected: 10_000)
        try land("models/config.json", bytes: 1_000)
        try land(".cache/huggingface/download/weights.bin.etag.incomplete", bytes: 3_000)
        let update = meter.written(fraction: 0.5)
        XCTAssertEqual(update.bytesReceived, 4_000)
        XCTAssertEqual(update.fraction, 0.4, accuracy: 0.0001)
    }
}
