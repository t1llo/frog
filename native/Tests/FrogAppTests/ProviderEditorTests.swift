import AppKit
import SwiftUI
import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class ProviderEditorTests: XCTestCase {
    /// Each look at the saved key is a Keychain query. The editor draws again for every keystroke
    /// and for every change in Frog, about ten times a second while a model downloads.
    func testTheKeychainIsAskedOnceWhenTheEditorOpensAndNotWhenItDrawsAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychain = Keychain()
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, readKey: { _ in keychain.reads += 1; return "saved-key" })
        defer { model.shutdown() }
        // The Connection step is the one that shows whether a key is saved.
        let (host, window) = place(ProviderEditor(provider: ProviderConfiguration(kind: .openAI), step: 1).environmentObject(model))
        defer { window.close() }
        await settle()
        XCTAssertEqual(keychain.reads, 1, "The editor asks once when it opens")

        for _ in 0..<5 { model.objectWillChange.send(); host.layoutSubtreeIfNeeded(); await settle() }
        XCTAssertEqual(keychain.reads, 1, "Drawing again must not ask the Keychain")
    }

    private final class Keychain { var reads = 0 }

    private func settle() async { for _ in 0..<5 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(5)) }

    /// The window is never shown. A view appears only in a window.
    private func place<Content: View>(_ view: Content) -> (NSHostingView<Content>, NSWindow) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }
}
