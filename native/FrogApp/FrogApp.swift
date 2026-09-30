import AppKit
import Carbon
import SwiftUI

@main
struct FrogApp: App {
    @NSApplicationDelegateAdaptor(FrogApplicationDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            FrogStatusMenu(model: delegate.model)
                .environment(\.locale, L10n.locale)
        } label: {
            Image(nsImage: FrogMenuIcon.image)
                .renderingMode(.template)
                .accessibilityLabel("Frog")
        }
        .menuBarExtraStyle(.window)
    }
}

private struct FrogStatusMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                FrogMark().scaleEffect(0.78).frame(width: 36, height: 36)
                Text("frog").font(.system(size: 22, weight: .semibold, design: .rounded))
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(model.dictation.phase == .recording ? Color.red : FrogStyle.accent).frame(width: 6, height: 6)
                    Text(model.dictation.active ? model.dictation.phase.rawValue.capitalized : model.isProcessing ? "Working…" : "Ready")
                        .font(.system(size: 11)).foregroundStyle(FrogStyle.muted)
                }
            }
            if model.dictation.active {
                HStack {
                    if model.dictation.phase == .recording {
                        Button("Stop recording", systemImage: "stop.fill") { model.dictation.stop(models: model.localModels) }
                            .buttonStyle(FrogButtonStyle(primary: true))
                    }
                    Button("Cancel", systemImage: "xmark") { model.dictation.interrupt() }
                }
            }
            if model.isProcessing { Button("Cancel processing", systemImage: "xmark") { model.cancelProcessing() } }
            if let error = model.errorMessage {
                HStack(alignment: .top) {
                    Text(error).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.dismissError() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss error")
                }
            }
            if model.configuration.preferences.shortcutsEnabled {
                VStack(alignment: .leading, spacing: 5) {
                    Toggle(isOn: Binding(get: { model.configuration.preferences.windowSwitcherEnabled }, set: { enabled in
                        var preferences = model.configuration.preferences; preferences.windowSwitcherEnabled = enabled
                        do { try model.savePreferences(preferences) } catch { model.report(error) }
                    })) {
                        HStack { Image(systemName: "rectangle.on.rectangle").foregroundStyle(FrogStyle.muted); Text("Window switcher"); Spacer(); Text("⌘Tab").foregroundStyle(FrogStyle.muted) }
                    }.toggleStyle(.switch)
                    if model.configuration.preferences.windowSwitcherEnabled && !model.windowSwitcherReady {
                        Text(model.windowSwitcherStatus).font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                    }
                }.padding(12).frogTableSurface()
            }
            MemorySparkline(showUsage: true).frame(height: 66).padding(12).frogTableSurface()
            VStack(spacing: 6) {
                Button { dismiss(); model.showSettings() } label: {
                    Label("Open Frog", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity, alignment: .leading)
                }.keyboardShortcut(",")
            }
            HStack {
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")").font(.system(size: 10)).foregroundStyle(FrogStyle.muted)
                Spacer()
                Button("Quit Frog") { model.shutdown(); NSApplication.shared.terminate(nil) }.keyboardShortcut("q").buttonStyle(.plain).foregroundStyle(FrogStyle.muted)
            }
        }.font(.system(size: 12)).foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent)
            .buttonStyle(FrogButtonStyle()).controlSize(.small).padding(18).frame(width: 320)
            .background(FrogStyle.canvas).background(FrogWindowMaterial())
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .task { await model.monitorSystemStatus() }
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
    private var window: NSWindow?
    private var observer: NSObjectProtocol?
    private var launchedAtLogin = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        DesktopNotifications.clearPreviousNotifications()
        NSApplication.shared.setActivationPolicy(.regular)
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        model.openSettings = { [weak self] in self?.showWindow() }
        // Register at application launch, even if SwiftUI never mounts the menu label.
        model.start()
        UpdateService.shared.start()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak model] _ in
            Task { @MainActor in model?.refreshSystemStatus() }
        }
        if !launchedAtLogin && !ProcessInfo.processInfo.arguments.contains("--background") {
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
            created.delegate = self
            created.center()
            window = created
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
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
