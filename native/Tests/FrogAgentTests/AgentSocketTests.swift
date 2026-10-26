import Foundation
import XCTest
@testable import FrogAgent

final class AgentSocketTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        // Short, because a socket path must fit in 104 bytes.
        folder = URL(fileURLWithPath: "/tmp/frog-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func testARequestIsAnsweredOverTheSocketAndOnlyItsUserCanOpenIt() throws {
        let socket = folder.appendingPathComponent("agent.sock")
        let listener = try AgentListener(socket: socket) { request in
            .success(request.arguments.joined(separator: " ") + (request.json ? " as json" : ""))
        }
        defer { listener.stop() }
        let response = try AgentClient.send(AgentRequest(arguments: ["windows", "list"], json: true), to: socket, timeout: 5)
        XCTAssertEqual(response, .success("windows list as json"))
        let mode = try FileManager.default.attributesOfItem(atPath: socket.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testLargeAnswersArriveWhole() throws {
        let socket = folder.appendingPathComponent("agent.sock")
        let text = String(repeating: "frog\n", count: 200_000)
        let listener = try AgentListener(socket: socket) { _ in .success(text) }
        defer { listener.stop() }
        XCTAssertEqual(try AgentClient.send(AgentRequest(arguments: ["help"]), to: socket, timeout: 5).output, text)
    }

    func testAToolThatGoesAwayCancelsItsCommand() throws {
        let socket = folder.appendingPathComponent("agent.sock")
        let started = expectation(description: "started"), cancelled = expectation(description: "cancelled")
        let listener = try AgentListener(socket: socket) { _ in
            started.fulfill()
            try? await Task.sleep(for: .seconds(30))
            if Task.isCancelled { cancelled.fulfill() }
            return .success("too late")
        }
        defer { listener.stop() }
        let client = try UnixSocket.make()
        try UnixSocket.connect(client, to: socket.path)
        try UnixSocket.writeAll(client, AgentWire.encode(AgentRequest(arguments: ["scripts", "run", "Slow"])))
        wait(for: [started], timeout: 5)
        close(client)
        wait(for: [cancelled], timeout: 5)
    }

    func testAToolThatWaitsIsAnsweredAfterALongCommand() throws {
        let socket = folder.appendingPathComponent("agent.sock")
        let listener = try AgentListener(socket: socket) { _ in
            try? await Task.sleep(for: .milliseconds(300))
            return .success(Task.isCancelled ? "cancelled" : "finished")
        }
        defer { listener.stop() }
        XCTAssertEqual(try AgentClient.send(AgentRequest(arguments: ["rules", "run"]), to: socket, timeout: 5).output, "finished")
    }

    func testNothingListeningIsUnavailable() {
        XCTAssertThrowsError(try AgentClient.send(AgentRequest(arguments: ["help"]), to: folder.appendingPathComponent("agent.sock"))) {
            XCTAssertEqual($0 as? AgentSocketError, .unavailable)
        }
    }

    func testStoppingRemovesTheSocketAndAStaleOneIsReplaced() throws {
        let socket = folder.appendingPathComponent("agent.sock")
        let first = try AgentListener(socket: socket) { _ in .success("first") }
        // A second Frog takes the path over; the first one stopping must not remove it.
        let second = try AgentListener(socket: socket) { _ in .success("second") }
        first.stop()
        XCTAssertEqual(try AgentClient.send(AgentRequest(arguments: []), to: socket, timeout: 5).output, "second")
        second.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
    }

    func testAnotherFileInTheWayIsLeftAlone() throws {
        let socket = folder.appendingPathComponent("agent.sock")
        try Data("notes".utf8).write(to: socket)
        XCTAssertThrowsError(try AgentListener(socket: socket) { _ in .success("") })
        XCTAssertEqual(try String(contentsOf: socket, encoding: .utf8), "notes")
    }

    func testTheSocketFollowsTheDataDirectory() {
        XCTAssertEqual(AgentSocketPath.socket(environment: ["FROG_DATA_DIRECTORY": "/tmp/frog-data"]).path, "/tmp/frog-data/agent.sock")
        XCTAssertTrue(AgentSocketPath.socket(environment: [:]).path.hasSuffix("Library/Application Support/Frog/agent.sock"))
    }
}
