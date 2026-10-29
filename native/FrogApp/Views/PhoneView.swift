import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import FrogCore
import SwiftUI

/// The Phone page: the switch, pairing, paired phones and their status, and what went back and forth.
struct PhoneView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let phone = model.phone {
            PhonePage(phone: phone)
        } else {
            PageScroll {
                PageHeader(title: "Phone", subtitle: "Share the clipboard and files with your Android phone.")
                PhoneSwitches(phone: nil)
            }
        }
    }
}

private struct PhonePage: View {
    @ObservedObject var phone: PhoneController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var appear: AnyTransition { reduceMotion ? .opacity : .offset(y: 8).combined(with: .opacity) }

    var body: some View {
        PageScroll {
            PageHeader(title: "Phone", subtitle: "Share the clipboard and files with your Android phone.") {
                if phone.pairing == nil {
                    Button("Pair a phone") { withAnimation(FrogMotion.reveal) { phone.beginPairing() } }
                        .buttonStyle(.frog(.primary))
                }
            }
            if let pairing = phone.pairing {
                PhonePairingCard(pairing: pairing) { withAnimation(FrogMotion.exit) { phone.endPairing() } }
                    .transition(appear)
            }
            PhoneSwitches(phone: phone)
            PhonesSection(phone: phone)
            PhoneSendSection(phone: phone)
            if !phone.recents.isEmpty { PhoneRecentsSection(phone: phone).transition(appear) }
        }
        .animation(FrogMotion.reveal, value: phone.pairing)
        .animation(FrogMotion.reveal, value: phone.recents.isEmpty)
    }
}

private struct PhoneSwitches: View {
    @EnvironmentObject private var model: AppModel
    let phone: PhoneController?

    var body: some View {
        SettingsSection(title: "Phone") {
            CompactRow(title: "Use Phone", detail: "Frog listens for your phone on Wi-Fi and Bluetooth only while this is on.") {
                Toggle("Use Phone", isOn: Binding(
                    get: { model.configuration.preferences.featureEnabled(.phone) },
                    set: { value in Task { do { try await model.setFeature(.phone, enabled: value) } catch { model.report(error) } } }))
                    .toggleStyle(.switch).labelsHidden()
            }
            CompactRow(title: "Send copies automatically", detail: "Text and images you copy go to a connected phone. Passwords, keys and files stay on this Mac.") {
                Toggle("Send copies automatically", isOn: Binding(
                    get: { model.configuration.preferences.toolkitSettings.phoneAutoSend ?? true },
                    set: { model.setPhoneAutoSend($0) }))
                    .toggleStyle(.switch).labelsHidden()
            }
            if let issue = phone.flatMap({ Self.bluetoothIssue($0.bluetooth) }) {
                InlineIssue(message: issue)
            }
        }
    }

    private static func bluetoothIssue(_ availability: PhoneBluetoothPeripheral.Availability) -> String? {
        switch availability {
        case .off: "Bluetooth is off, so your phone can reach this Mac only on the same Wi-Fi."
        case .unauthorized: "Frog may not use Bluetooth. Allow it in System Settings → Privacy & Security → Bluetooth."
        case .unsupported: "This Mac cannot offer the Bluetooth link, so your phone needs the same Wi-Fi."
        case .on, .unknown: nil
        }
    }
}

private struct PhonePairingCard: View {
    let pairing: PhoneController.Pairing
    let close: () -> Void

    var body: some View {
        SettingsSection(title: "Pair a phone") {
            if let name = pairing.pairedPhoneName {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(FrogStyle.good)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(name) is paired").font(FrogType.bodyMedium).foregroundStyle(FrogStyle.ink)
                        Text("Copies now go both ways while the phone is near.").font(FrogType.small).foregroundStyle(FrogStyle.muted)
                    }
                    Spacer()
                    Button("Done", action: close).buttonStyle(.frog(.primary, compact: true))
                }
            } else {
                HStack(alignment: .top, spacing: 20) {
                    PhoneQRCode(text: pairing.url)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Open Frog Companion on your Android phone and scan this code.")
                            .font(FrogType.bodyMedium).foregroundStyle(FrogStyle.ink).fixedSize(horizontal: false, vertical: true)
                        Text("The code works for 10 minutes, and only while it is shown. Keep the phone on the same Wi-Fi, or near this Mac for Bluetooth.")
                            .font(FrogType.small).foregroundStyle(FrogStyle.muted).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for your phone…").font(FrogType.small).foregroundStyle(FrogStyle.muted)
                        }.padding(.top, 2)
                        Spacer(minLength: 0)
                        Button("Cancel", action: close).buttonStyle(.frog(.ghost, compact: true))
                    }
                }
            }
        }
    }
}

/// A crisp black-on-white QR code, drawn without smoothing.
private struct PhoneQRCode: View {
    let text: String

    var body: some View {
        Group {
            if let image = Self.image(for: text) {
                Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
            } else {
                Image(systemName: "qrcode").font(.system(size: 40)).foregroundStyle(FrogStyle.muted)
            }
        }
        .frame(width: 168, height: 168).padding(10)
        .background(Color.white, in: RoundedRectangle(cornerRadius: FrogStyle.controlRadius))
        .accessibilityLabel("Pairing code")
    }

    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

private struct PhonesSection: View {
    @ObservedObject var phone: PhoneController

    var body: some View {
        SettingsSection(title: "Paired phones") {
            if phone.phones.isEmpty {
                FrogEmptyState(symbol: "iphone", title: "No phone paired",
                               message: "Install Frog Companion on your Android phone, then pair it here.") {
                    if phone.pairing == nil {
                        Button("Pair a phone") { withAnimation(FrogMotion.reveal) { phone.beginPairing() } }.buttonStyle(.frog(.primary))
                    }
                }
            } else {
                VStack(spacing: 2) {
                    ForEach(phone.phones) { paired in
                        PhoneRow(paired: paired, connection: phone.connection(for: paired)) { phone.unpair(paired) }
                    }
                }
            }
        }
    }
}

private struct PhoneRow: View {
    let paired: PairedPhone
    let connection: PhoneController.Connection
    let unpair: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            SymbolTile(symbol: "iphone", size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(paired.name).font(FrogType.bodyMedium).foregroundStyle(FrogStyle.ink).lineLimit(1)
                Text("Paired \(paired.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(FrogType.small).foregroundStyle(FrogStyle.muted)
            }
            Spacer(minLength: 8)
            FrogBadge(text: connection.label, active: connection != .offline)
            IconAction(title: "Unpair", symbol: "xmark", destructive: true, action: unpair)
        }.padding(.horizontal, 6).padding(.vertical, 4).frogHoverRow()
    }
}

private struct PhoneSendSection: View {
    @ObservedObject var phone: PhoneController
    @State private var notice: String?

    var body: some View {
        SettingsSection(title: "Send to phone") {
            CompactRow(title: "Files", detail: "Up to 200 MB each. Files copied in Finder go with Send clipboard to phone in the command bar.") {
                Button("Send files…", action: chooseFiles).buttonStyle(.frog(.secondary, compact: true))
            }
            CompactRow(title: "Clipboard", detail: "Sends what is copied now, also files copied in Finder.") {
                Button("Send clipboard") { notice = phone.sendClipboard() }.buttonStyle(.frog(.secondary, compact: true))
            }
            if let notice { Text(L10n.text(notice)).font(FrogType.small).foregroundStyle(FrogStyle.muted) }
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = L10n.text("Send")
        guard panel.runModal() == .OK else { return }
        notice = phone.sendFiles(panel.urls)
    }
}

private struct PhoneRecentsSection: View {
    @ObservedObject var phone: PhoneController

    var body: some View {
        SettingsSection(title: "Recent", accessory: {
            Button("Clear") { withAnimation(FrogMotion.exit) { phone.clearRecents() } }.buttonStyle(.frog(.ghost, compact: true))
        }) {
            VStack(spacing: 2) {
                ForEach(phone.recents) { item in PhoneRecentRow(item: item) }
            }
        }
    }
}

private struct PhoneRecentRow: View {
    let item: PhoneRecentItem

    private var symbol: String {
        switch item.kind {
        case .text: "text.alignleft"
        case .image: "photo"
        case .file: "doc"
        }
    }

    private var status: String {
        switch item.status {
        case .sending: "Sending to \(item.peerName)"
        case .delivered: "Sent to \(item.peerName)"
        case .waitingForWiFi: "Waiting for Wi-Fi"
        case .notDelivered: "Not sent: no phone connected"
        case .received: "From \(item.peerName)"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.direction == .sent ? "arrow.up.right" : "arrow.down.left")
                .font(FrogType.label).foregroundStyle(item.direction == .sent ? FrogStyle.muted : FrogStyle.accent)
                .frame(width: 16).accessibilityLabel(item.direction == .sent ? "Sent" : "Received")
            Image(systemName: symbol).font(FrogType.label).foregroundStyle(FrogStyle.muted).frame(width: 16).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(FrogType.body).foregroundStyle(FrogStyle.ink).lineLimit(1).truncationMode(.middle)
                Text("\(L10n.text(status)) · \(item.date.formatted(date: .omitted, time: .shortened))")
                    .font(FrogType.small).foregroundStyle(item.status == .notDelivered ? FrogStyle.warning : FrogStyle.muted)
            }
            Spacer(minLength: 8)
            if let url = item.fileURL, item.direction == .received {
                IconAction(title: "Show in Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }.padding(.horizontal, 6).padding(.vertical, 3).frogHoverRow()
    }
}
