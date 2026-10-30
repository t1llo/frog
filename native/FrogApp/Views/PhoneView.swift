import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import FrogCore
import SwiftUI

/// The Phone page: pairing, the paired phones, sending, and what went back and forth.
struct PhonePage: View {
    @ObservedObject var phone: PhoneController
    let plugin: PhonePlugin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var appear: AnyTransition { reduceMotion ? .opacity : .offset(y: 6).combined(with: .opacity) }

    var body: some View {
        FrogPage {
            FrogPageHeader(title: "Phone", subtitle: "Clipboard and files, shared with Frog Companion on Android.") {
                if phone.pairing == nil, !phone.phones.isEmpty {
                    Button("Pair a phone", action: pair).buttonStyle(.frog())
                }
            }
            if let pairing = phone.pairing {
                PhonePairingSection(pairing: pairing) { withAnimation(FrogMotion.exit) { phone.endPairing() } }
                    .transition(appear)
            }
            phones
            PhoneSendSection(phone: phone, plugin: plugin)
            if !phone.recents.isEmpty { PhoneRecentsSection(phone: phone).transition(appear) }
        }
        .animation(reduceMotion ? nil : FrogMotion.reveal, value: phone.pairing)
        .animation(reduceMotion ? nil : FrogMotion.reveal, value: phone.recents.isEmpty)
    }

    private func pair() { withAnimation(FrogMotion.reveal) { phone.beginPairing() } }

    @ViewBuilder private var phones: some View {
        FrogSection("Phones") {
            if phone.phones.isEmpty {
                FrogEmptyState(symbol: "iphone", title: "No phone paired", message: "Install Frog Companion on your phone, then pair it.") {
                    if phone.pairing == nil { Button("Pair a phone", action: pair).buttonStyle(.frog(.primary)) }
                }
            } else {
                ForEach(phone.phones) { paired in
                    PhoneRow(paired: paired, connection: phone.connection(for: paired)) { phone.unpair(paired) }
                }
                if let issue = Self.bluetoothIssue(phone.bluetooth) { FrogRowNote(text: issue, tone: FrogStyle.warning) }
            }
        }
    }

    private static func bluetoothIssue(_ availability: PhoneBluetoothPeripheral.Availability) -> String? {
        switch availability {
        case .off: "Bluetooth is off: your phone needs the same Wi-Fi."
        case .unauthorized: "Bluetooth is not allowed: Privacy & Security → Bluetooth."
        case .unsupported: "No Bluetooth link on this Mac: your phone needs the same Wi-Fi."
        case .on, .unknown: nil
        }
    }
}

private struct PhonePairingSection: View {
    let pairing: PhoneController.Pairing
    let close: () -> Void

    var body: some View {
        FrogSection("Pair a phone") {
            if let name = pairing.pairedPhoneName {
                FrogRow("\(name) is paired", icon: {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(FrogStyle.good)
                        .accessibilityHidden(true)
                }) {
                    Button("Done", action: close).buttonStyle(.frog(.primary, compact: true))
                }
            } else {
                HStack(alignment: .center, spacing: 20) {
                    PhoneQRCode(text: pairing.url)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Scan with Frog Companion").font(FrogType.section).foregroundStyle(FrogStyle.ink)
                        Text("The code works for 10 minutes.").font(FrogType.body).foregroundStyle(FrogStyle.muted)
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for your phone").font(FrogType.small).foregroundStyle(FrogStyle.muted)
                        }.padding(.top, 6)
                        Button("Cancel", action: close).buttonStyle(.frog(.ghost, compact: true)).padding(.top, 6)
                    }
                    Spacer(minLength: 0)
                }.padding(.vertical, 12)
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
        .frame(width: 160, height: 160).padding(10)
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

private struct PhoneRow: View {
    let paired: PairedPhone
    let connection: PhoneController.Connection
    let unpair: () -> Void

    var body: some View {
        FrogRow(paired.name, icon: { SymbolTile(symbol: "iphone", size: 28) }) {
            HStack(spacing: 8) {
                FrogBadge(text: connection.label, active: connection != .offline)
                IconAction(title: "Unpair", symbol: "xmark", destructive: true, action: unpair)
            }
        }
    }
}

private struct PhoneSendSection: View {
    @ObservedObject var phone: PhoneController
    let plugin: PhonePlugin
    @State private var notice: String?

    var body: some View {
        FrogSection("Send") {
            FrogRow("Send copies automatically", caption: "Text and images. Never passwords or keys.") {
                Toggle("Send copies automatically", isOn: Binding(get: { phone.autoSend }, set: { plugin.setAutoSend($0) }))
                    .labelsHidden().toggleStyle(.switch)
            }
            // Sending by hand needs a phone to send to.
            if !phone.phones.isEmpty {
                FrogRow("Clipboard", caption: "Also files copied in Finder") {
                    Button("Send") { notice = phone.sendClipboard() }.buttonStyle(.frog(compact: true))
                }
                FrogRow("Files", caption: "Up to 200 MB each") {
                    Button("Choose…", action: chooseFiles).buttonStyle(.frog(compact: true))
                }
            }
            if let notice { FrogRowNote(text: notice) }
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
        FrogSection("Recent", accessory: {
            Button("Clear") { withAnimation(FrogMotion.exit) { phone.clearRecents() } }.buttonStyle(.frog(.ghost, compact: true))
        }) {
            ForEach(phone.recents) { item in PhoneRecentRow(item: item) }
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
        }.padding(.vertical, 6).frame(minHeight: FrogStyle.rowHeight)
    }
}
