import AppKit
import SwiftUI
import FrogCore

/// `[phone]` in config.toml.
struct PhoneSettings: ConfigSection {
    var autoSend = true

    static let comments = [
        "": "Phone: the clipboard and files, shared with Frog Companion on your Android phone.",
        "auto-send": "Sends text and images you copy to a connected phone",
    ]

    /// The table the first time the plugin runs, from the switch on the old Phone page.
    static func seed(from preferences: Preferences) -> PhoneSettings {
        var settings = PhoneSettings()
        settings.autoSend = preferences.toolkitSettings.phoneAutoSend ?? true
        return settings
    }
}

/// Phone: while it is on, a listener with its Bonjour advert and a Bluetooth peripheral wait for paired phones.
/// Off, none of them exists. Copies reach the phone through the clipboard store's one watch, never a second.
final class PhonePlugin: LegacyPlugin, FrogPlugin {
    static let info = PluginInfo(id: "phone", name: "Phone", symbol: "iphone", tint: .green, category: .devices,
                                 summary: "Share the clipboard with your phone",
                                 permissions: [.localNetwork, .bluetooth, .notifications])

    private(set) var phone: PhoneController?
    private var clipboard: ClipboardHistoryStore { model.clipboardHistoryStore }

    func start() async {
        seedSettingsIfNeeded()
        // The running app keeps pairings in the Keychain and opens the transports; a test gets neither.
        let live = model.runsLiveServices
        let pairings = PhonePairingStore(fileURL: PhonePairingStore.defaultFile(in: model.dataDirectory),
                                         secrets: live ? KeychainPhoneSecretStore() : InMemoryPhoneSecretStore())
        let phone = PhoneController(store: pairings, clipboard: clipboard,
                                    downloads: live ? nil : model.dataDirectory.appendingPathComponent("Downloads", isDirectory: true),
                                    startsTransports: live)
        phone.autoSend = context.settings(PhoneSettings.self).autoSend
        phone.start()
        self.phone = phone
        clipboard.onCopy = { [weak phone] in phone?.clipboardDidCopy($0) }
        forwardCopies()
    }

    func stop() async {
        clipboard.configure(forwardingCopies: false, automaticallyPoll: model.runsLiveServices)
        clipboard.onCopy = nil
        phone?.stop()
        phone = nil
    }

    func settingsChanged() {
        guard let phone else { return }
        let autoSend = context.settings(PhoneSettings.self).autoSend
        guard autoSend != phone.autoSend else { return }
        phone.autoSend = autoSend
        forwardCopies()
    }

    func setAutoSend(_ enabled: Bool) {
        var settings = context.settings(PhoneSettings.self)
        settings.autoSend = enabled
        do { try context.save(settings) } catch { return context.report(error) }
        phone?.autoSend = enabled
        forwardCopies()
    }

    private func forwardCopies() {
        clipboard.configure(forwardingCopies: phone?.autoSend == true, automaticallyPoll: model.runsLiveServices)
    }

    private func seedSettingsIfNeeded() {
        let file = model.settingsFile
        guard file.document.value(at: [Self.info.id]) == nil else { return }
        let seed = PhoneSettings.seed(from: model.configuration.preferences)
        do { try file.edit { try $0.update(Self.info.id, seed, all: true) } } catch { context.report(error) }
    }

    // MARK: Surfaces

    func page() -> AnyView? {
        guard let phone else { return nil }
        return legacyPage(PhonePage(phone: phone, plugin: self))
    }

    var menu: [MenuContribution] {
        [MenuContribution(id: "phone.status", order: 30) { [weak self] in
            guard let self, let phone = self.phone else { return AnyView(EmptyView()) }
            return AnyView(PhoneMenuRow(phone: phone) { [weak self] in self?.context.openPage() })
        }]
    }

    var actions: [PluginAction] {
        [
            PluginAction(id: "phone.status", title: "Phone status", symbol: "iphone", surfaces: .agent) { [weak self] _ in
                guard let self else { throw CancellationError() }
                return Self.status(try self.running())
            },
            PluginAction(id: "phone.send", title: "Send clipboard to phone", symbol: "iphone",
                         keywords: "phone android companion send share files finder copy",
                         parameters: [ActionParameter(name: "text", help: "Text to send; standard input works too"),
                                      ActionParameter(name: "file", help: "A file to send, by its full path, up to 200 MB")],
                         surfaces: [.commandBar, .agent]) { [weak self] input in
                guard let self else { throw CancellationError() }
                let phone = try self.running()
                let outcome: String
                if let path = input.value("file") {
                    let path = (path as NSString).expandingTildeInPath
                    guard path.hasPrefix("/") else { throw ActionError.invalid("file", "a full path") }
                    outcome = phone.sendFiles([URL(fileURLWithPath: path)])
                } else if let text = input.value("text") ?? input.text.flatMap({ $0.isEmpty ? nil : $0 }) {
                    outcome = phone.send(text: text)
                } else {
                    outcome = phone.sendClipboard()
                }
                guard outcome.hasPrefix("Sent") || outcome.hasPrefix("Sending") else { throw ActionError.failed(outcome) }
                return .done(outcome)
            },
            PluginAction(id: "phone.pair", title: "Pair a phone", symbol: "qrcode", keywords: "phone android companion connect",
                         surfaces: [.commandBar, .agent]) { [weak self] _ in
                guard let self else { throw CancellationError() }
                let phone = try self.running()
                phone.beginPairing()
                self.context.openPage()
                // The code holds the pairing secret, so it is shown on screen and never printed.
                let expires = phone.pairing?.expiresAt ?? Date()
                return ActionResult(PairingShown(expires: expires),
                                    text: "The pairing code is on the Phone page in Frog. Scan it with Frog Companion within 10 minutes.")
            },
            PluginAction(id: "phone.unpair", title: "Unpair a phone", symbol: "xmark",
                         parameters: [ActionParameter(name: "phone", required: true, help: "The phone's name or ID, from phone.status")],
                         surfaces: .agent) { [weak self] input in
                guard let self else { throw CancellationError() }
                let phone = try self.running()
                let key = try input.required("phone")
                let matches = phone.phones.filter { $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame || $0.name.localizedCaseInsensitiveCompare(key) == .orderedSame }
                guard matches.count == 1, let paired = matches.first else {
                    throw ActionError.failed(matches.isEmpty ? "No paired phone “\(key)”. Run `frog run phone.status` for the list."
                                                             : "More than one phone is called “\(key)”; give its ID.")
                }
                phone.unpair(paired)
                return .done("Unpaired \(paired.name).")
            },
        ]
    }

    private func running() throws -> PhoneController {
        guard let phone else { throw ActionError.pluginOff(Self.info.name) }
        return phone
    }

    private struct PairingShown: Encodable {
        var shown = true
        let expires: Date
    }

    private struct Status: Encodable {
        struct Phone: Encodable {
            let id: String
            let name: String
            let connection: String
            let paired: Date
        }
        let status: String
        let autoSend: Bool
        let bluetooth: String
        let phones: [Phone]
    }

    private static func status(_ phone: PhoneController) -> ActionResult {
        let phones = phone.phones.map {
            Status.Phone(id: $0.id.uuidString.lowercased(), name: $0.name, connection: phone.connection(for: $0).label, paired: $0.pairedAt)
        }
        let lines = [phone.statusText] + phones.map { "\($0.name)  \($0.connection)  \($0.id)" }
        return ActionResult(Status(status: phone.statusText, autoSend: phone.autoSend, bluetooth: "\(phone.bluetooth)", phones: phones),
                            text: lines.joined(separator: "\n"))
    }
}
