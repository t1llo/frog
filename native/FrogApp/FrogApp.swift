import AppKit
import SwiftUI

@main
struct FrogApp: App {
    @NSApplicationDelegateAdaptor(FrogApplicationDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            FrogStatusMenu(model: delegate.model)
                .environment(\.locale, L10n.locale)
        } label: {
            FrogMenuLabel(power: delegate.power)
        }
        .menuBarExtraStyle(.window)
    }
}

/// A template frog face stays legible in both light and dark macOS menu bars.
enum FrogMenuIcon {
    static let image: NSImage = {
        let image = FrogResources.bundle.url(forResource: "FrogMenuIcon", withExtension: "png").flatMap { NSImage(contentsOf: $0) } ?? NSImage(size: NSSize(width: 18, height: 15))
        image.size = NSSize(width: 18, height: 15)
        image.isTemplate = true
        return image
    }()
}

@MainActor
final class FrogApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    var power: StayAwakeController { model.power }
    private var window: NSWindow?
    /// The key in Frog's defaults under which AppKit keeps the main window's frame.
    private static let windowFrameName = "FrogMainWindow"
    private var termination: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var finishedLaunching = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Frog 1.0.0 to 1.0.2 posted notifications; remove any they left in Notification Center, once, so
        // plugin notifications that are waiting stay.
        DesktopNotifications.clearPreviousNotifications()
        model.openSettings = { [weak self] in self?.showWindow() }
        // Register at application launch, even if SwiftUI never mounts the menu label.
        model.start()
        power.start()
        UpdateService.shared.start()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak model] _ in
            // The person may come back from approving Frog under Login Items.
            Task { @MainActor in model?.refreshSystemStatus(forceLoginStatus: true); await model?.power.refresh(); await model?.power.refreshAccessUnlessReady() }
        }
        // Login, session restoration and updater relaunches do not reliably carry
        // the login-item Apple event. All initial launches are menu-bar-only.
        finishedLaunching = true
        if ProcessInfo.processInfo.arguments.contains("--settings") && !ProcessInfo.processInfo.arguments.contains("--background") {
            showWindow()
        }
    }

    private func showWindow() {
        if window == nil {
            let content = FrogHostingView(rootView: MainView().environmentObject(model))
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 580), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            created.contentView = content
            created.title = "Frog"
            created.titleVisibility = .hidden
            created.titlebarAppearsTransparent = true
            created.toolbarStyle = .unified
            created.backgroundColor = .clear
            created.isOpaque = false
            created.setContentSize(NSSize(width: 800, height: 580))
            created.contentMinSize = NSSize(width: 740, height: 520)
            created.isReleasedWhenClosed = false
            created.isRestorable = false
            created.delegate = self
            created.center()
            // The size and place the window last had come back after Frog restarts, such as after an update or a
            // login; the first time it opens centered.
            created.setFrameAutosaveName(Self.windowFrameName)
            created.setFrameUsingName(Self.windowFrameName)
            window = created
        }
        // Frog joins the Dock and Command-Tab while its window is open, like any app with a window, and leaves
        // them when it closes. Popups and panels never change this.
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApplication.shared.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        // After the window has gone, so AppKit hands the focus to the app that was in front before.
        DispatchQueue.main.async {
            guard self.window?.isVisible != true else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// `frog://plugins/install?…` links from the plugin directory, and `frog://dictate` from apps that dictate through Frog.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls.prefix(1) { model.openLink(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard termination == nil else { return .terminateLater }
        // Plugins close what they hold, such as phone sessions, once quitting is certain; the bound keeps one from blocking it.
        guard power.needsQuitCleanup || model.hasPendingDocumentWrites || model.scripts.needsQuitCleanup else {
            termination = Task {
                await model.pluginHost.stopAll(timeout: .seconds(2))
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        termination = Task {
            await model.scripts.stopAndWait()
            guard await model.flushDocuments() else {
                sender.reply(toApplicationShouldTerminate: false); termination = nil
                let alert = NSAlert()
                alert.messageText = "Notes could not be saved"
                alert.informativeText = "Review the storage error in Notes before quitting."
                alert.runModal()
                return
            }
            let restored = await power.prepareToQuit()
            if restored { await model.pluginHost.stopAll(timeout: .seconds(2)) }
            sender.reply(toApplicationShouldTerminate: restored)
            if !restored {
                termination = nil
                let alert = NSAlert()
                alert.messageText = "Restore sleep before quitting"
                alert.informativeText = power.error ?? "Turn off Stay awake, then quit Frog."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if finishedLaunching { showWindow() }
        return false
    }
    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

/// The SwiftUI surfaces and the behind-window material own the background.
/// AppKit's hosting layer must not fill the content with an opaque window color.
private final class FrogHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}
