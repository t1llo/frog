import AppKit
import FrogCore
import UniformTypeIdentifiers
import UserNotifications
import os

/// The Phone feature: pairs Android phones running Frog Companion and moves clipboard items and
/// files between them and the Mac over Wi-Fi or Bluetooth (docs/companion-protocol.md). The Phone
/// plugin makes one only while it is on, so nothing listens, advertises or asks for a permission before.
@MainActor
final class PhoneController: ObservableObject {
    enum Connection: Equatable {
        case wifi, bluetooth, offline

        var label: String {
            switch self {
            case .wifi: "Wi-Fi"
            case .bluetooth: "Bluetooth"
            case .offline: "Offline"
            }
        }
    }

    /// The QR code while it is shown, and the phone that paired with it.
    struct Pairing: Equatable {
        let secret: Data
        let url: String
        let expiresAt: Date
        var pairedPhoneName: String?

        func isPending(at date: Date = Date()) -> Bool { pairedPhoneName == nil && date < expiresAt }
    }

    static let pairingLifetime: TimeInterval = 10 * 60
    static let recentLimit = 20
    private static let outboxLimit = 20
    private static let notificationKey = "phoneFile"
    private static let fileCategory = "frog.phone.file"
    private static let showAction = "show"

    @Published private(set) var phones: [PairedPhone]
    @Published private(set) var connections: [UUID: Connection] = [:]
    @Published private(set) var recents: [PhoneRecentItem] = []
    @Published private(set) var pairing: Pairing?
    @Published private(set) var bluetooth = PhoneBluetoothPeripheral.Availability.unknown
    @Published private(set) var listeningPort: UInt16?
    /// Sends new copies of text and images; set from `auto-send` in `[phone]`.
    @Published var autoSend = true

    let store: PhonePairingStore
    let macName: String
    private let clipboard: ClipboardHistoryStore
    private let downloads: URL
    private let startsTransports: Bool
    private var tcp: PhoneTCPServer?
    private var ble: PhoneBluetoothPeripheral?
    private var sessions: [UUID: CompanionSession] = [:]
    /// Per phone, the clips it has not acknowledged yet: in flight, or waiting for a link that carries them.
    private var outbox: [UUID: [OutboxEntry]] = [:]
    /// The last 64 received clip IDs, lowercased.
    private var receivedIDs: [String] = []
    private var pairingExpiry: Task<Void, Never>?
    private var running = false
    private var askedForNotifications = false
    private let log = Logger(subsystem: "frog", category: "phone")

    private struct OutboxEntry {
        let clip: PhoneOutgoingClip
        var inFlightOn: UUID?
    }

    init(store: PhonePairingStore, clipboard: ClipboardHistoryStore, downloads: URL? = nil,
         macName: String = Host.current().localizedName ?? "Mac", startsTransports: Bool = true) {
        self.store = store
        self.clipboard = clipboard
        self.downloads = downloads ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        self.macName = macName
        self.startsTransports = startsTransports
        phones = store.phones
    }

    // MARK: Lifecycle

    func start() {
        guard !running else { return }
        running = true
        NotificationRouter.shared.register(
            key: Self.notificationKey,
            category: UNNotificationCategory(identifier: Self.fileCategory,
                                             actions: [UNNotificationAction(identifier: Self.showAction, title: "Show in Finder", options: [.foreground])],
                                             intentIdentifiers: [])) { _, info in
            guard let path = info[Self.notificationKey] else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        guard startsTransports else { return }
        let tcp = PhoneTCPServer(deviceID: store.macID)
        tcp.onPortChange = { [weak self] in self?.listeningPort = $0 }
        tcp.onNewPipe = { [weak self] in self?.accept($0) }
        tcp.start()
        self.tcp = tcp
        let ble = PhoneBluetoothPeripheral()
        ble.onAvailabilityChange = { [weak self] in self?.bluetooth = $0 }
        ble.onNewPipe = { [weak self] in self?.accept($0) }
        ble.start()
        self.ble = ble
    }

    func stop() {
        guard running else { return }
        running = false
        endPairing()
        for session in Array(sessions.values) { session.close(reason: "Phone turned off") }
        sessions = [:]
        outbox = [:]
        tcp?.stop(); tcp = nil
        ble?.stop(); ble = nil
        listeningPort = nil
        bluetooth = .unknown
        connections = [:]
    }

    // MARK: Status

    func connection(for phone: PairedPhone) -> Connection { connections[phone.id] ?? .offline }

    var overall: Connection {
        if connections.values.contains(.wifi) { return .wifi }
        if connections.values.contains(.bluetooth) { return .bluetooth }
        return .offline
    }

    /// One line for the menu bar popup and the command bar. Wi-Fi or Bluetooth is a detail of the Phone page.
    var statusText: String {
        if phones.isEmpty { return "No phone paired" }
        if overall != .offline { return "Connected" }
        return phones.count == 1 ? "\(phones[0].name) is offline" : "No phone connected"
    }

    // MARK: Pairing

    func beginPairing() {
        // A Phone page still on screen after Phone was turned off holds a stopped controller: it pairs nothing.
        guard running else { return }
        let secret = CompanionBytes.random(count: CompanionProtocol.secretLength)
        let url = CompanionPairingURL(macID: store.macID, macName: macName, secret: secret,
                                      port: listeningPort ?? CompanionProtocol.defaultTCPPort,
                                      hosts: PhoneNetwork.ipv4Addresses()).string
        pairing = Pairing(secret: secret, url: url, expiresAt: Date().addingTimeInterval(Self.pairingLifetime))
        pairingExpiry?.cancel()
        pairingExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pairingLifetime))
            guard !Task.isCancelled, let self, self.pairing?.secret == secret, self.pairing?.pairedPhoneName == nil else { return }
            self.endPairing()
        }
    }

    /// Hides the QR code and forgets its secret.
    func endPairing() {
        pairingExpiry?.cancel()
        pairingExpiry = nil
        pairing = nil
    }

    private var pendingSecret: Data? {
        guard let pairing, pairing.isPending() else { return nil }
        return pairing.secret
    }

    func unpair(_ phone: PairedPhone) {
        for session in Array(sessions.values) where session.peerID == phone.id { session.sendUnpairAndClose() }
        forget(phone.id)
    }

    private func forget(_ id: UUID) {
        do { try store.remove(id) } catch { log.error("Could not forget a phone: \(error.localizedDescription, privacy: .public)") }
        outbox[id] = nil
        phones = store.phones
        for session in Array(sessions.values) where session.peerID == id && !session.isClosed { session.close(reason: "forgotten") }
        refreshConnections()
    }

    // MARK: Sessions

    /// Takes a new connection from a transport, or from a test.
    func accept(_ pipe: any CompanionPipe) {
        guard running else { pipe.close(); return }
        let session = CompanionSession(pipe: pipe, localID: store.macID, localName: macName)
        session.delegate = self
        sessions[session.id] = session
        session.start()
    }

    private func refreshConnections() {
        var result: [UUID: Connection] = [:]
        for session in sessions.values where session.isEstablished {
            guard let peer = session.peerID else { continue }
            if session.transport == .tcp { result[peer] = .wifi } else if result[peer] == nil { result[peer] = .bluetooth }
        }
        if result != connections { connections = result }
    }

    /// Wi-Fi before Bluetooth.
    private func bestSession(for phoneID: UUID) -> CompanionSession? {
        let live = sessions.values.filter { $0.isEstablished && $0.peerID == phoneID }
        return live.first { $0.transport == .tcp } ?? live.first
    }

    // MARK: Sending

    /// A new copy from Frog's clipboard watch.
    func clipboardDidCopy(_ copy: ClipboardCopy) {
        guard running, autoSend else { return }
        dispatch(PhoneOutgoingClip(copy))
    }

    /// Sends what is on the clipboard now: the files copied in Finder, or the text or image.
    /// Returns what happened, for the command bar.
    @discardableResult
    func sendClipboard() -> String {
        let pasteboard = clipboard.pasteboard
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty { return sendFiles(urls) }
        guard let item = pasteboard.pasteboardItems?.first, let copy = ClipboardCopy.read(item) else {
            return pasteboard.holdsSensitiveText || pasteboard.string(forType: .string).map { ClipboardSecret.detect($0) != nil } == true
                ? "Frog does not send passwords and keys." : "Nothing on the clipboard to send."
        }
        return dispatch(PhoneOutgoingClip(copy)) ? "Sent to your phone." : "No phone is connected."
    }

    /// Sends text, as the phone would get a copy of it. Passwords and keys are refused.
    @discardableResult
    func send(text: String) -> String {
        guard !text.isEmpty else { return "Nothing to send." }
        guard text.utf8.count <= Self.textLimit else { return "Text up to 1 MB can be sent; send a longer one as a file." }
        guard ClipboardSecret.detect(text) == nil else { return "Frog does not send passwords and keys." }
        return dispatch(PhoneOutgoingClip(.text(text))) ? "Sent to your phone." : "No phone is connected."
    }

    /// The longest text sent as text: a clip's body over Bluetooth is at most 1 MiB.
    static let textLimit = 1024 * 1024

    /// A file that looks like a key, a keystore or a secret, by its name, its folder or the text at its start.
    /// `phone.send --file` refuses these, so an agent cannot carry them off the Mac.
    nonisolated static func looksSecret(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        let path = file.path
        let homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
        for folder in [".ssh", ".gnupg", "Library/Keychains"] where path.hasPrefix(homePath + "/" + folder + "/") { return true }
        if path.hasPrefix("/Library/Keychains/") { return true }
        let name = file.lastPathComponent.lowercased()
        if name.hasPrefix(".env") || name.hasPrefix(".netrc") || name.hasPrefix(".npmrc") || name.hasPrefix(".pgpass") { return true }
        if ["pem", "key", "p8", "p12", "pfx", "jks", "keystore", "keychain", "keychain-db", "ppk", "asc", "gpg"].contains(file.pathExtension.lowercased()) {
            return true
        }
        if name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519") || name.hasPrefix("id_ecdsa") || name.hasPrefix("id_dsa") { return true }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let start = try? handle.read(upToCount: ClipboardSecret.scanLimit), !start.isEmpty else { return false }
        return ClipboardSecret.detect(String(decoding: start, as: UTF8.self)) != nil
    }

    /// Sends files, one clip each; folders and files over 200 MB are left out.
    @discardableResult
    func sendFiles(_ urls: [URL]) -> String {
        let clips = urls.compactMap(PhoneOutgoingClip.file)
        guard !clips.isEmpty else { return "Choose files up to 200 MB; folders are not sent." }
        var reached = false
        for clip in clips { reached = dispatch(clip) || reached }
        let noun = clips.count == 1 ? "1 file" : "\(clips.count) files"
        return reached ? "Sending \(noun) to your phone." : "No phone is connected."
    }

    /// Queues the clip for each connected phone and sends it. False when no phone is connected.
    @discardableResult
    private func dispatch(_ clip: PhoneOutgoingClip) -> Bool {
        guard running else { return false }
        var reached = false
        for phone in store.phones where bestSession(for: phone.id) != nil {
            reached = true
            var entries = outbox[phone.id, default: []]
            entries.append(OutboxEntry(clip: clip, inFlightOn: nil))
            if entries.count > Self.outboxLimit { entries.removeFirst(entries.count - Self.outboxLimit) }
            outbox[phone.id] = entries
        }
        insertRecent(PhoneRecentItem(id: clip.id, direction: .sent, kind: clip.kind, title: clip.title, peerName: sentPeerLabel(),
                                     date: Date(), status: reached ? .sending : .notDelivered, fileURL: clip.fileURL, size: clip.size))
        for phone in store.phones { flush(phone.id) }
        return reached
    }

    private func sentPeerLabel() -> String {
        let connected = store.phones.filter { bestSession(for: $0.id) != nil }
        switch connected.count {
        case 0: return store.phones.count == 1 ? store.phones[0].name : "your phone"
        case 1: return connected[0].name
        default: return "\(connected.count) phones"
        }
    }

    /// Sends every queued clip that is not in flight and fits the current link.
    private func flush(_ phoneID: UUID) {
        guard let session = bestSession(for: phoneID), var entries = outbox[phoneID] else { return }
        var failed = Set<String>()
        for index in entries.indices where entries[index].inFlightOn == nil {
            let clip = entries[index].clip
            guard clip.size <= session.transport.maxClipSize else { continue }
            do {
                let body = try clip.loadBody()
                guard body.count == clip.size else { throw CocoaError(.fileReadCorruptFile) }
                try session.send(.clip(clip.header, body: body))
                entries[index].inFlightOn = session.id
            } catch {
                log.error("Could not send a clip: \(error.localizedDescription, privacy: .public)")
                failed.insert(clip.id)
                updateRecent(clip.id) { $0.status = .notDelivered }
            }
        }
        outbox[phoneID] = entries.filter { !failed.contains($0.clip.id) }
        refreshSentStatuses()
    }

    private func refreshSentStatuses() {
        var waiting = Set<String>(), pending = Set<String>()
        for entries in outbox.values {
            for entry in entries {
                pending.insert(entry.clip.id)
                if entry.inFlightOn == nil, entry.clip.size > CompanionTransport.bluetooth.maxClipSize { waiting.insert(entry.clip.id) }
            }
        }
        for item in recents where item.direction == .sent && (item.status == .sending || item.status == .waitingForWiFi) && pending.contains(item.id) {
            let status: PhoneRecentItem.Status = waiting.contains(item.id) ? .waitingForWiFi : .sending
            if item.status != status { updateRecent(item.id) { $0.status = status } }
        }
    }

    // MARK: Receiving

    private func save(_ header: CompanionClipHeader, body: Data, from session: CompanionSession) -> CompanionReceiveResult {
        let peer = session.peerName.isEmpty ? "Phone" : session.peerName
        var savedURL: URL?
        var title = PhoneRecentItem.title(kind: header.kind, name: header.name, text: nil)
        switch header.kind {
        case .text:
            guard let text = String(data: body, encoding: .utf8) else { return .failed }
            guard clipboard.writeReceived(.text(text)) else { return .failed }
            // A password from the phone goes on the clipboard, but neither into the history nor onto the page.
            title = ClipboardSecret.detect(text) == nil ? PhoneRecentItem.title(kind: .text, name: nil, text: text) : "Hidden text"
        case .image:
            guard clipboard.writeReceived(.image(body), mime: header.mime) else { return .failed }
        case .file:
            do {
                savedURL = try CompanionFileSaver.save(body, suggestedName: header.name, in: downloads)
            } catch {
                log.error("Could not save a received file: \(error.localizedDescription, privacy: .public)")
                return .failed
            }
            title = savedURL!.lastPathComponent
            notifyFileSaved(savedURL!, from: peer)
        }
        insertRecent(PhoneRecentItem(id: header.id, direction: .received, kind: header.kind, title: title, peerName: peer,
                                     date: Date(), status: .received, fileURL: savedURL, size: body.count))
        return .stored
    }

    private func notifyFileSaved(_ url: URL, from phoneName: String) {
        guard NotificationRouter.available else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Received from \(phoneName)"
        content.body = "Saved \u{201C}\(url.lastPathComponent)\u{201D} to \(url.deletingLastPathComponent().lastPathComponent)."
        content.categoryIdentifier = Self.fileCategory
        content.userInfo = [Self.notificationKey: url.path]
        let request = UNNotificationRequest(identifier: "phone." + UUID().uuidString, content: content, trigger: nil)
        // macOS asks once, when the first file arrives.
        let ask = !askedForNotifications
        askedForNotifications = true
        Task {
            if ask { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
            try? await center.add(request)
        }
    }

    // MARK: Recents

    private func insertRecent(_ item: PhoneRecentItem) {
        recents = Array(([item] + recents.filter { $0.id != item.id }).prefix(Self.recentLimit))
    }

    private func updateRecent(_ id: String, _ change: (inout PhoneRecentItem) -> Void) {
        guard let index = recents.firstIndex(where: { $0.id == id }) else { return }
        change(&recents[index])
    }

    func clearRecents() { recents = [] }
}

extension PhoneController: CompanionSessionDelegate {
    func session(_ session: CompanionSession, secretsForClient clientID: UUID) -> [CompanionSecretCandidate] {
        var candidates: [CompanionSecretCandidate] = []
        if let stored = store.secret(for: clientID) { candidates.append(.init(secret: stored, isPending: false)) }
        if let pending = pendingSecret { candidates.append(.init(secret: pending, isPending: true)) }
        return candidates
    }

    func sessionDidEstablish(_ session: CompanionSession, using candidate: CompanionSecretCandidate) {
        guard let peer = session.peerID else { return }
        let name = session.peerName.isEmpty ? "Android phone" : session.peerName
        if candidate.isPending {
            do {
                try store.save(id: peer, name: name, secret: candidate.secret)
            } catch {
                log.error("Could not store a pairing: \(error.localizedDescription, privacy: .public)")
                session.close(reason: "pairing not stored")
                return
            }
            pairing?.pairedPhoneName = name
            pairingExpiry?.cancel()
        } else {
            store.rename(peer, to: name)
        }
        phones = store.phones
        // One session per phone and link: the newest wins.
        for other in Array(sessions.values) where other !== session && other.peerID == peer && other.transport == session.transport {
            other.close(reason: "replaced by a newer connection")
        }
        refreshConnections()
        flush(peer)
    }

    func session(_ session: CompanionSession, didReceiveClip header: CompanionClipHeader, body: Data) -> CompanionReceiveResult {
        let key = header.id.lowercased()
        if receivedIDs.contains(key) { return .duplicate }
        let result = save(header, body: body, from: session)
        if result == .stored {
            receivedIDs.append(key)
            if receivedIDs.count > CompanionProtocol.rememberedClipIDs { receivedIDs.removeFirst() }
        }
        return result
    }

    func session(_ session: CompanionSession, didReceiveAck clipID: String) {
        guard let peer = session.peerID else { return }
        let id = clipID.lowercased()
        outbox[peer]?.removeAll { $0.clip.id == id }
        updateRecent(id) { if $0.direction == .sent { $0.status = .delivered } }
        refreshSentStatuses()
    }

    func sessionDidReceiveUnpair(_ session: CompanionSession) {
        guard let peer = session.peerID else { return }
        forget(peer)
    }

    func sessionDidClose(_ session: CompanionSession) {
        sessions[session.id] = nil
        guard let peer = session.peerID else { return }
        if var entries = outbox[peer] {
            for index in entries.indices where entries[index].inFlightOn == session.id { entries[index].inFlightOn = nil }
            outbox[peer] = entries
        }
        refreshConnections()
        flush(peer)
        refreshSentStatuses()
    }
}

/// A clip ready to send. Files stay on disk until a session sends them.
struct PhoneOutgoingClip: Identifiable {
    enum Payload {
        case data(Data)
        case file(URL)
    }

    let id = UUID().companionString
    let kind: CompanionClipKind
    let mime: String
    let name: String?
    let size: Int
    let payload: Payload
    let title: String

    var header: CompanionClipHeader { CompanionClipHeader(id: id, kind: kind, mime: mime, name: name, size: size) }
    var fileURL: URL? { if case .file(let url) = payload { url } else { nil } }

    func loadBody() throws -> Data {
        switch payload {
        case .data(let data): data
        case .file(let url): try Data(contentsOf: url, options: .mappedIfSafe)
        }
    }

    init(kind: CompanionClipKind, mime: String, name: String? = nil, size: Int, payload: Payload, title: String) {
        self.kind = kind; self.mime = mime; self.name = name; self.size = size; self.payload = payload; self.title = title
    }

    init(_ copy: ClipboardCopy) {
        switch copy {
        case .text(let text):
            let data = Data(text.utf8)
            self.init(kind: .text, mime: "text/plain", size: data.count, payload: .data(data),
                      title: PhoneRecentItem.title(kind: .text, name: nil, text: text))
        case .image(let png):
            self.init(kind: .image, mime: "image/png", size: png.count, payload: .data(png), title: "Image")
        }
    }

    /// A regular file up to the Wi-Fi limit; nil for folders, packages and larger files.
    static func file(_ url: URL) -> PhoneOutgoingClip? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= CompanionProtocol.maxClipTCP else { return nil }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return PhoneOutgoingClip(kind: .file, mime: mime, name: url.lastPathComponent, size: size, payload: .file(url),
                                 title: url.lastPathComponent)
    }
}
