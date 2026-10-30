import AppKit
import FrogCore
import XCTest
@testable import FrogApp

/// A pipe the test drives: what Frog sends is collected, the test feeds the phone's bytes.
@MainActor
private final class TestPipe: CompanionPipe {
    let transport: CompanionTransport
    let label = "test"
    var onReceive: ((Data) -> Void)?
    var onClose: (() -> Void)?
    var sent = Data()
    var closed = false
    init(_ transport: CompanionTransport = .tcp) { self.transport = transport }
    func start() {}
    func send(_ data: Data) { sent.append(data) }
    func close() { closed = true; onClose?() }
    func feed(_ data: Data) { onReceive?(data) }
    func takeSent() -> Data { defer { sent = Data() }; return sent }
}

/// The phone's side, from docs/companion-protocol.md.
private struct TestPhone {
    var id = UUID()
    let secret: Data
    let nonce = CompanionBytes.random(count: 32)
    var sealer: CompanionFrameSealer?
    var opener: CompanionFrameOpener?
    var reader = CompanionFrameReader()

    @MainActor mutating func connect(_ pipe: TestPipe) throws {
        pipe.feed(CompanionHandshake(deviceID: id, nonce: nonce).encoded())
        reader.append(pipe.takeSent())
        let server = try XCTUnwrap(try reader.readHandshake())
        let keys = CompanionKeys.derive(secret: secret, clientNonce: nonce, serverNonce: server.nonce)
        sealer = CompanionFrameSealer(key: keys.clientToServer)
        opener = CompanionFrameOpener(key: keys.serverToClient)
        pipe.feed(try frame(.hello(name: "Test phone", platform: "android", version: 1)))
    }

    mutating func frame(_ message: CompanionMessage) throws -> Data { try sealer!.seal(message.encoded()) }

    mutating func messages(_ bytes: Data) throws -> [CompanionMessage] {
        reader.append(bytes)
        var out: [CompanionMessage] = []
        while let sealed = try reader.readSealedFrame() { out.append(try CompanionMessage.decode(try opener!.open(sealed))) }
        return out
    }
}

@MainActor
final class PhoneControllerTests: XCTestCase {
    private var directory: URL!
    private var pasteboard: NSPasteboard!
    private var history: ClipboardHistoryStore!
    private var phone: PhoneController!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("frog-phone-\(UUID().uuidString)", isDirectory: true)
        pasteboard = NSPasteboard.withUniqueName()
        history = ClipboardHistoryStore(pasteboard: pasteboard, gate: ClipboardHistoryCaptureGate())
        let store = PhonePairingStore(fileURL: PhonePairingStore.defaultFile(in: directory), secrets: InMemoryPhoneSecretStore())
        phone = PhoneController(store: store, clipboard: history, downloads: directory.appendingPathComponent("Downloads"),
                                macName: "Test Mac", startsTransports: false)
        phone.start()
    }

    override func tearDown() async throws {
        phone.stop()
        history.configure(enabled: false)
        history.configure(forwardingCopies: false)
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Pairs a phone with the QR code's secret and returns it connected.
    private func pairedPhone() throws -> (TestPhone, TestPipe) {
        phone.beginPairing()
        let url = try XCTUnwrap(CompanionPairingURL(string: try XCTUnwrap(phone.pairing?.url)))
        XCTAssertEqual(url.macID, phone.store.macID)
        XCTAssertEqual(url.macName, "Test Mac")
        let pipe = TestPipe()
        phone.accept(pipe)
        var client = TestPhone(secret: url.secret)
        try client.connect(pipe)
        XCTAssertEqual(try client.messages(pipe.takeSent()), [.hello(name: "Test Mac", platform: "macos", version: 1)])
        return (client, pipe)
    }

    func testPairingStoresThePhoneAndShowsSuccess() throws {
        _ = try pairedPhone()
        XCTAssertEqual(phone.phones.map(\.name), ["Test phone"])
        XCTAssertEqual(phone.pairing?.pairedPhoneName, "Test phone")
        XCTAssertEqual(phone.overall, .wifi)
        XCTAssertEqual(phone.statusText, "Connected")
    }

    func testUnknownPhoneIsRefusedWithoutAPairingCode() throws {
        let pipe = TestPipe()
        phone.accept(pipe)
        pipe.feed(CompanionHandshake.random(deviceID: UUID()).encoded())
        XCTAssertTrue(pipe.closed)
        XCTAssertTrue(phone.phones.isEmpty)
    }

    func testReceivedTextGoesOnTheClipboardAndIsNotSentBack() async throws {
        var (client, pipe) = try pairedPhone()
        history.configure(enabled: true, automaticallyPoll: false)
        history.configure(forwardingCopies: true, automaticallyPoll: false)
        var forwarded: [ClipboardCopy] = []
        history.onCopy = { forwarded.append($0) }

        let body = Data("Fixture from the phone".utf8)
        pipe.feed(try client.frame(.clip(CompanionClipHeader(id: "clip-1", kind: .text, mime: "text/plain", size: body.count), body: body)))
        XCTAssertEqual(pasteboard.string(forType: .string), "Fixture from the phone")
        XCTAssertEqual(try client.messages(pipe.takeSent()), [.ack(id: "clip-1")])
        XCTAssertEqual(history.entries.first?.text, "Fixture from the phone", "Received text joins the history")
        await history.poll()
        XCTAssertTrue(forwarded.isEmpty, "Frog's own write is not a new copy")
        XCTAssertEqual(phone.recents.first?.direction, .received)
    }

    func testReceivedFileIsSavedToDownloads() throws {
        var (client, pipe) = try pairedPhone()
        let body = Data([1, 2, 3])
        pipe.feed(try client.frame(.clip(CompanionClipHeader(id: "file-1", kind: .file, mime: "application/octet-stream", name: "../notes.bin", size: 3), body: body)))
        let saved = directory.appendingPathComponent("Downloads/-notes.bin")
        XCTAssertEqual(try Data(contentsOf: saved), body)
        XCTAssertEqual(try client.messages(pipe.takeSent()), [.ack(id: "file-1")])
        XCTAssertEqual(phone.recents.first?.fileURL?.lastPathComponent, "-notes.bin")
    }

    func testCopiesGoToTheConnectedPhoneUntilAcknowledged() throws {
        var (client, pipe) = try pairedPhone()
        phone.clipboardDidCopy(.text("Fixture copy"))
        let messages = try client.messages(pipe.takeSent())
        guard case let .clip(header, body)? = messages.first else { return XCTFail("Expected a clip, got \(messages)") }
        XCTAssertEqual(String(data: body, encoding: .utf8), "Fixture copy")
        XCTAssertEqual(phone.recents.first?.status, .sending)
        pipe.feed(try client.frame(.ack(id: header.id)))
        XCTAssertEqual(phone.recents.first?.status, .delivered)

        phone.autoSend = false
        phone.clipboardDidCopy(.text("Not sent"))
        XCTAssertTrue(pipe.sent.isEmpty, "Auto-send off sends nothing")
    }

    func testUnacknowledgedClipIsSentAgainOnReconnect() throws {
        var (client, pipe) = try pairedPhone()
        phone.clipboardDidCopy(.text("Fixture again"))
        _ = try client.messages(pipe.takeSent())
        pipe.close()
        XCTAssertEqual(phone.overall, .offline)

        let second = TestPipe()
        phone.accept(second)
        // The same phone comes back with the secret it stored.
        var again = TestPhone(id: client.id, secret: client.secret)
        try again.connect(second)
        let messages = try again.messages(second.takeSent())
        XCTAssertEqual(messages.count, 2, "Its hello, then the clip again: \(messages)")
        guard case let .clip(_, body)? = messages.last else { return XCTFail("Expected the clip again") }
        XCTAssertEqual(String(data: body, encoding: .utf8), "Fixture again")
    }

    func testLargeClipWaitsForWiFiOnBluetooth() throws {
        phone.beginPairing()
        let url = try XCTUnwrap(CompanionPairingURL(string: try XCTUnwrap(phone.pairing?.url)))
        let pipe = TestPipe(.bluetooth)
        phone.accept(pipe)
        var client = TestPhone(secret: url.secret)
        try client.connect(pipe)
        _ = try client.messages(pipe.takeSent())
        XCTAssertEqual(phone.overall, .bluetooth)
        phone.clipboardDidCopy(.image(Data(count: CompanionProtocol.maxClipBluetooth + 1)))
        XCTAssertTrue(try client.messages(pipe.takeSent()).isEmpty)
        XCTAssertEqual(phone.recents.first?.status, .waitingForWiFi)
    }

    func testSentTextReachesThePhoneButPasswordsDoNot() throws {
        var (client, pipe) = try pairedPhone()
        XCTAssertEqual(phone.send(text: "Fixture note"), "Sent to your phone.")
        guard case let .clip(_, body)? = try client.messages(pipe.takeSent()).first else { return XCTFail("Expected a clip") }
        XCTAssertEqual(String(data: body, encoding: .utf8), "Fixture note")

        XCTAssertEqual(phone.send(text: "Tr0ub4dor&3"), "Frog does not send passwords and keys.")
        XCTAssertTrue(pipe.sent.isEmpty)
    }

    func testUnpairTellsThePhoneAndForgetsIt() throws {
        var (client, pipe) = try pairedPhone()
        phone.unpair(try XCTUnwrap(phone.phones.first))
        XCTAssertEqual(try client.messages(pipe.takeSent()), [.unpair])
        XCTAssertTrue(pipe.closed)
        XCTAssertTrue(phone.phones.isEmpty)
    }
}

/// The Phone plugin: nothing exists while it is off; its actions, run as `frog run` runs them.
@MainActor
final class PhonePluginTests: XCTestCase {
    private var directory: URL!
    private var pasteboard: NSPasteboard!
    private var history: ClipboardHistoryStore!
    private var model: AppModel!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("frog-phone-plugin-\(UUID().uuidString)", isDirectory: true)
        try ConfigurationStore(directory: directory).save(Configuration())
        pasteboard = NSPasteboard.withUniqueName()
        history = ClipboardHistoryStore(pasteboard: pasteboard, gate: ClipboardHistoryCaptureGate())
        model = AppModel(dataDirectory: directory, registerShortcuts: false, complete: { text, _, _, _ in text }, readKey: { _ in nil },
                         writeClipboard: { _ in }, clipboardHistoryStore: history)
        model.start()
        await model.pluginHost.syncAndWait()
    }

    override func tearDown() async throws {
        await model.pluginHost.stopAll()
        model.shutdown()
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
    }

    private var plugin: PhonePlugin? { model.pluginHost.running["phone"] as? PhonePlugin }

    private func run(_ id: String, _ values: [String: String] = [:], text: String? = nil) async throws -> ActionResult {
        try await model.pluginHost.run(id, ActionInput(values: values, text: text, source: .agent))
    }

    func testOffHoldsNothingAndOnSeedsItsTable() async throws {
        try await model.pluginHost.setEnabled("phone", false)
        XCTAssertNil(plugin)
        XCTAssertFalse(history.forwardsCopies)
        do { _ = try await run("phone.status"); XCTFail("Phone is off") } catch ActionError.pluginOff {}

        try await model.pluginHost.setEnabled("phone", true)
        XCTAssertNotNil(plugin?.phone)
        XCTAssertTrue(history.forwardsCopies, "Auto-send is on by default")
        XCTAssertEqual(model.settingsFile.document.value(at: ["phone", "auto-send"]), .bool(true))

        plugin?.setAutoSend(false)
        XCTAssertFalse(history.forwardsCopies)
        XCTAssertEqual(model.settingsFile.document.value(at: ["phone", "auto-send"]), .bool(false))

        try await model.pluginHost.setEnabled("phone", false)
        XCTAssertNil(plugin)
        XCTAssertFalse(history.forwardsCopies)
        XCTAssertNil(history.onCopy)
    }

    func testActions() async throws {
        try await model.pluginHost.setEnabled("phone", true)
        let phone = try XCTUnwrap(plugin?.phone)
        do { let text = try await run("phone.status").text; XCTAssertEqual(text, "No phone paired") }

        let shown = try await run("phone.pair")
        let url = try XCTUnwrap(CompanionPairingURL(string: try XCTUnwrap(phone.pairing?.url)))
        XCTAssertFalse(shown.text.contains(url.string) || shown.json.contains(url.string), "The code's secret is never printed")
        let pipe = TestPipe()
        phone.accept(pipe)
        var client = TestPhone(secret: url.secret)
        try client.connect(pipe)
        _ = try client.messages(pipe.takeSent())

        let status = try await run("phone.status")
        XCTAssertTrue(status.text.hasPrefix("Connected\nTest phone  Wi-Fi  "), status.text)
        XCTAssertTrue(status.json.contains("\"name\" : \"Test phone\""), status.json)

        do { let text = try await run("phone.send", text: "Fixture from stdin").text; XCTAssertEqual(text, "Sent to your phone.") }
        do { let text = try await run("phone.send", ["text": "Fixture option"]).text; XCTAssertEqual(text, "Sent to your phone.") }
        let bodies = try client.messages(pipe.takeSent()).compactMap { message -> String? in
            if case let .clip(_, body) = message { return String(data: body, encoding: .utf8) }
            return nil
        }
        XCTAssertEqual(bodies, ["Fixture from stdin", "Fixture option"])
        do { _ = try await run("phone.send", ["text": "Tr0ub4dor&3"]); XCTFail("A password is refused") } catch ActionError.failed {}
        do { _ = try await run("phone.send", ["file": "relative.txt"]); XCTFail("A relative path is refused") } catch ActionError.invalid {}

        do { _ = try await run("phone.unpair", ["phone": "Other phone"]); XCTFail("Unknown phone") } catch ActionError.failed {}
        do { let text = try await run("phone.unpair", ["phone": "test phone"]).text; XCTAssertEqual(text, "Unpaired Test phone.") }
        XCTAssertTrue(phone.phones.isEmpty)
    }
}
