import AppKit
import Carbon
import SwiftUI

@main
struct FrogApp: App {
    @NSApplicationDelegateAdaptor(FrogApplicationDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            Text(model.status).font(.caption)
            if let error = model.errorMessage { Text(error).font(.caption) }
            if model.isProcessing { Button("Cancel Processing") { model.cancelProcessing() } }
            Divider()
            Button("Open Frog…") { model.showSettings() }.keyboardShortcut(",")
            Divider()
            Button("Quit Frog") { model.shutdown(); NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(systemName: model.isProcessing ? "ellipsis.circle" : "text.badge.checkmark")
                .accessibilityLabel(model.isProcessing ? "Frog is processing" : "Frog")
                .onAppear { delegate.install(model: model) }
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class FrogApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel?
    private var window: NSWindow?
    private var observer: NSObjectProtocol?
    private var launchedAtLogin = false
    private var applicationLaunched = false
    private var started = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        applicationLaunched = true
        startIfReady()
    }

    func install(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        model.openSettings = { [weak self] in self?.showWindow() }
        startIfReady()
    }

    private func startIfReady() {
        guard applicationLaunched, !started, let model else { return }
        started = true
        model.start()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak model] _ in
            Task { @MainActor in model?.refreshSystemStatus() }
        }
        if model.configuration.providers.isEmpty && !launchedAtLogin && !ProcessInfo.processInfo.arguments.contains("--background") {
            showWindow()
        }
    }

    private func showWindow() {
        guard let model else { return }
        if window == nil {
            let controller = NSHostingController(rootView: MainView().environmentObject(model))
            let created = NSWindow(contentViewController: controller)
            created.title = "Frog"
            created.titleVisibility = .hidden
            created.titlebarAppearsTransparent = true
            created.toolbarStyle = .unified
            created.backgroundColor = .windowBackgroundColor
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            created.setContentSize(NSSize(width: 1000, height: 720))
            created.minSize = NSSize(width: 760, height: 560)
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.center()
            window = created
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
