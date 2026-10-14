import AppKit
import SwiftUI
import XCTest
import WhisperKit
@testable import FrogApp

@MainActor
final class MicrophoneSettingsTests: XCTestCase {
    /// Each read of the microphones asks Core Audio about every device. The Settings page draws
    /// again for every change of the app, once a second while dictating.
    func testTheMicrophonesAreReadWhenTheRowAppearsAndNotWhenItDrawsAgain() async throws {
        let audio = Audio(devices: [AudioDevice(id: 42, name: "Desk microphone")])
        let dictation = audio.controller()
        let page = Page()
        let (host, window) = place(Screen(page: page, dictation: dictation, changes: audio.changes))
        defer { window.close() }
        await settle()
        XCTAssertEqual(audio.reads, 1, "The row reads the microphones once when it appears")
        XCTAssertEqual(dictation.microphones.map(\.name), ["Desk microphone"])

        let passes = page.passes
        for _ in 0..<5 { page.objectWillChange.send(); host.layoutSubtreeIfNeeded(); await settle() }
        XCTAssertGreaterThan(page.passes, passes, "The page must have drawn again")
        XCTAssertEqual(audio.reads, 1, "Drawing again must not read the microphones")
    }

    func testAConnectedMicrophoneAppearsWithoutLeavingThePage() async throws {
        let audio = Audio(devices: [AudioDevice(id: 42, name: "Desk microphone")])
        let dictation = audio.controller()
        let (_, window) = place(Screen(page: Page(), dictation: dictation, changes: audio.changes))
        defer { window.close() }
        await settle()
        audio.devices.append(AudioDevice(id: 43, name: "Headset"))
        audio.continuation.yield()
        for _ in 0..<200 where dictation.microphones.count < 2 { await settle() }
        XCTAssertEqual(dictation.microphones.map(\.name), ["Desk microphone", "Headset"])
        XCTAssertEqual(audio.reads, 2)
    }

    /// The window is never shown. A view appears, and starts its work, only in a window.
    private func place(_ view: Screen) -> (NSHostingView<Screen>, NSWindow) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    private func settle() async { for _ in 0..<5 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(5)) }

    private final class Page: ObservableObject { var passes = 0 }

    private struct Screen: View {
        @ObservedObject var page: Page
        let dictation: DictationController
        let changes: AsyncStream<Void>
        var body: some View {
            let _ = page.passes += 1
            MicrophoneRow(dictation: dictation, selection: "42", deviceChanges: { changes }) { _ in }
        }
    }

    @MainActor
    private final class Audio {
        var devices: [AudioDevice]
        var reads = 0
        let changes: AsyncStream<Void>
        let continuation: AsyncStream<Void>.Continuation
        init(devices: [AudioDevice]) {
            self.devices = devices
            (changes, continuation) = AsyncStream<Void>.makeStream()
        }
        func controller() -> DictationController {
            DictationController(authorize: { true }, copy: { _ in }, monitorKeys: false, inputDevices: { [unowned self] in reads += 1; return devices })
        }
    }
}
