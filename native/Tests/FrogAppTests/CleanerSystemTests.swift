import Darwin
import FrogCore
import XCTest
@testable import FrogApp

/// The decisions behind quitting apps, stopping launch jobs and the Full Disk Access probe. No app is
/// quit and `launchctl` never runs; the process runner is tried with harmless system tools.
final class CleanerSystemTests: XCTestCase {
    func testBootoutArgumentsUseTheGuiDomainAndRefuseOddLabels() {
        XCTAssertEqual(LaunchJobCommand.bootout(label: "com.example.agent", uid: 501), ["bootout", "gui/501/com.example.agent"])
        XCTAssertEqual(LaunchJobCommand.bootout(label: "com.example.Agent_2-helper", uid: 502)?.last,
                       "gui/502/com.example.Agent_2-helper")
        for label in ["", "a b", "x;rm", "../system", "com.example/agent", "a\nb", "é", String(repeating: "a", count: 256)] {
            XCTAssertNil(LaunchJobCommand.bootout(label: label, uid: 501), label)
        }
        XCTAssertNotNil(LaunchJobCommand.bootout(label: String(repeating: "a", count: 255), uid: 501))
    }

    func testNotLoadedCountsAsStopped() {
        XCTAssertTrue(LaunchJobCommand.stopped(status: 0))
        XCTAssertTrue(LaunchJobCommand.stopped(status: 3))
        XCTAssertTrue(LaunchJobCommand.stopped(status: 113))
        XCTAssertFalse(LaunchJobCommand.stopped(status: 1))
        XCTAssertFalse(LaunchJobCommand.stopped(status: 5))
        XCTAssertFalse(LaunchJobCommand.stopped(status: 15))
    }

    func testFullDiskAccessProbeOrder() {
        XCTAssertEqual(FullDiskAccessProbe.evaluate([0]), true)
        XCTAssertEqual(FullDiskAccessProbe.evaluate([EPERM]), false)
        XCTAssertEqual(FullDiskAccessProbe.evaluate([ENOENT, EACCES]), false)
        XCTAssertEqual(FullDiskAccessProbe.evaluate([ENOENT, 0]), true)
        XCTAssertNil(FullDiskAccessProbe.evaluate([ENOENT, ENOENT, ENOENT]))
        XCTAssertNil(FullDiskAccessProbe.evaluate([]))
    }

    func testOnlyTheAppsOwnProcessesAreQuitAndNeverFrog() {
        let ids: Set<String> = ["com.example.sample", "com.example.sample.helper"]
        let bundle = "/Applications/Cleaner Sample.app"
        XCTAssertTrue(SystemCleanerControl.matches(pid: 10, bundleID: "com.example.sample.helper", paths: [], bundleIDs: ids,
                                                   inside: nil, ownPID: 1))
        XCTAssertTrue(SystemCleanerControl.matches(pid: 10, bundleID: nil,
                                                   paths: ["/Applications/Cleaner Sample.app/Contents/MacOS/agent"],
                                                   bundleIDs: ids, inside: bundle, ownPID: 1))
        XCTAssertTrue(SystemCleanerControl.matches(pid: 10, bundleID: "com.other", paths: [bundle + "/"], bundleIDs: ids,
                                                   inside: bundle, ownPID: 1))
        // A sibling whose name only starts the same is another app.
        XCTAssertFalse(SystemCleanerControl.matches(pid: 10, bundleID: "com.other",
                                                    paths: ["/Applications/Cleaner Sample.app 2/Contents/MacOS/x"],
                                                    bundleIDs: ids, inside: bundle, ownPID: 1))
        XCTAssertFalse(SystemCleanerControl.matches(pid: 10, bundleID: "com.other", paths: [bundle], bundleIDs: ids,
                                                    inside: nil, ownPID: 1))
        XCTAssertFalse(SystemCleanerControl.matches(pid: 1, bundleID: "com.example.sample", paths: [bundle], bundleIDs: ids,
                                                    inside: bundle, ownPID: 1))
    }

    func testProcessRunnerTimesOutKillsAndCapsOutput() async throws {
        let started = ContinuousClock.now
        do {
            _ = try await CleanerProcessRunner.run("/bin/sleep", ["5"], timeout: .milliseconds(300))
            XCTFail("sleep must time out")
        } catch {
            XCTAssertEqual(error as? CleanerProcessRunner.Failure, .timedOut)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))

        // A tool that writes without end is drained while it runs, then stopped at the timeout.
        let yesStarted = ContinuousClock.now
        do {
            _ = try await CleanerProcessRunner.run("/usr/bin/yes", [], timeout: .milliseconds(300))
            XCTFail("yes must time out")
        } catch {
            XCTAssertEqual(error as? CleanerProcessRunner.Failure, .timedOut)
        }
        XCTAssertLessThan(ContinuousClock.now - yesStarted, .seconds(3))

        // 200 KB of output finishes and comes back cut at the limit.
        let chatty = try await CleanerProcessRunner.run("/usr/bin/jot", ["-b", "y", "100000"])
        XCTAssertEqual(chatty.status, 0)
        XCTAssertEqual(chatty.output.utf8.count, CleanerProcessRunner.outputLimit)

        let environment = try await CleanerProcessRunner.run("/usr/bin/env", [])
        XCTAssertEqual(environment.status, 0)
        XCTAssertTrue(environment.output.split(separator: "\n").contains("LC_ALL=C"))

        let status = try await CleanerProcessRunner.run("/usr/bin/false", [])
        XCTAssertEqual(status.status, 1)

        do {
            _ = try await CleanerProcessRunner.run("env", [])
            XCTFail("a relative executable must be refused")
        } catch {
            XCTAssertEqual(error as? CleanerProcessRunner.Failure, .notAbsolute)
        }
    }
}
