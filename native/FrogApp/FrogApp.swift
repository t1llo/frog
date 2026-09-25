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
                .resizable()
                .frame(width: 22, height: 18)
                .accessibilityLabel("Frog")
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct FrogStatusMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text(L10n.text(model.status)).font(.caption)
        Text("\(model.configuration.rules.filter { $0.enabled && $0.hotkey != nil }.count) active shortcuts").font(.caption)
        if !model.accessibilityGranted { Button("Set up Accessibility…") { SelectionService.requestAccess(); SelectionService.openAccessibilitySettings() } }
        if !DictationController.microphoneGranted { Button("Set up microphone…") { Task { _ = await DictationController.requestMicrophone(); model.objectWillChange.send() } } }
        if let error = model.errorMessage { Text(error).font(.caption) }
        if model.isProcessing { Button("Cancel Processing") { model.cancelProcessing() } }
        if model.dictation.active {
            Text("Dictation · \(model.dictation.phase.rawValue.capitalized)")
            if model.dictation.phase == .recording { Button("Stop recording") { model.dictation.stop(models: model.localModels) } }
            Button("Cancel dictation") { model.dictation.cancel() }
        }
        if !model.localModels.loaded.isEmpty { Text("Local models in memory: \(model.localModels.loaded.count)") }
        Button("Show shortcuts…") { model.showShortcuts() }
        Divider()
        Toggle("Window switcher (⌘Tab)", isOn: Binding(get: { model.configuration.preferences.windowSwitcherEnabled }, set: { enabled in
            var preferences = model.configuration.preferences
            preferences.windowSwitcherEnabled = enabled
            do { try model.savePreferences(preferences) } catch { model.report(error) }
        }))
        if model.configuration.preferences.windowSwitcherEnabled && !model.windowSwitcherReady {
            Text(model.windowSwitcherStatus).font(.caption)
        }
        Divider()
        Button("Open Frog…") { model.showSettings() }.keyboardShortcut(",")
        Divider()
        Button("Quit Frog") { model.shutdown(); NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}

/// A template frog face stays legible in both light and dark macOS menu bars.
private enum FrogMenuIcon {
    static let image: NSImage = {
        // Render into an isolated bitmap, rather than using a lazy drawing handler
        // with destination-out compositing inside SwiftUI's status-item renderer.
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size)
        for scale in [1, 2, 3] {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 22 * scale, pixelsHigh: 18 * scale,
                                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let transform = NSAffineTransform()
            transform.scale(by: CGFloat(scale)); transform.concat()
            drawFace()
            NSGraphicsContext.restoreGraphicsState()
            bitmap.size = size
            image.addRepresentation(bitmap)
        }
        image.isTemplate = true
        return image
    }()

    private static func drawFace() {
        NSColor.black.setStroke()
        NSColor.black.setFill()
        let outline = NSBezierPath()
        outline.move(to: NSPoint(x: 3, y: 11))
        outline.curve(to: NSPoint(x: 9, y: 14), controlPoint1: NSPoint(x: 1, y: 18), controlPoint2: NSPoint(x: 9, y: 18))
        outline.line(to: NSPoint(x: 13, y: 14))
        outline.curve(to: NSPoint(x: 19, y: 11), controlPoint1: NSPoint(x: 13, y: 18), controlPoint2: NSPoint(x: 21, y: 18))
        outline.curve(to: NSPoint(x: 11, y: 1.5), controlPoint1: NSPoint(x: 25, y: 5), controlPoint2: NSPoint(x: 17, y: 1.5))
        outline.curve(to: NSPoint(x: 3, y: 11), controlPoint1: NSPoint(x: 5, y: 1.5), controlPoint2: NSPoint(x: -3, y: 5))
        outline.close()
        outline.lineWidth = 1.4
        outline.stroke()
        for x in [CGFloat(5), CGFloat(15)] {
            NSBezierPath(ovalIn: NSRect(x: x, y: 12, width: 2, height: 2.5)).fill()
        }
        let smile = NSBezierPath()
        smile.move(to: NSPoint(x: 6, y: 7.5))
        smile.curve(to: NSPoint(x: 16, y: 7.5), controlPoint1: NSPoint(x: 8, y: 3.5), controlPoint2: NSPoint(x: 14, y: 3.5))
        smile.lineWidth = 1.2
        smile.lineCapStyle = .round
        smile.stroke()
    }
}

@MainActor
final class FrogApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var window: NSWindow?
    private var observer: NSObjectProtocol?
    private var launchedAtLogin = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        model.openSettings = { [weak self] in self?.showWindow() }
        // Register at application launch, even if SwiftUI never mounts the menu label.
        model.start()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak model] _ in
            Task { @MainActor in model?.refreshSystemStatus() }
        }
        if !launchedAtLogin && !ProcessInfo.processInfo.arguments.contains("--background") {
            showWindow()
        }
    }

    private func showWindow() {
        if window == nil {
            let controller = NSHostingController(rootView: MainView().environmentObject(model))
            let created = NSWindow(contentViewController: controller)
            created.title = "Frog"
            created.titleVisibility = .hidden
            created.titlebarAppearsTransparent = true
            created.toolbarStyle = .unified
            created.backgroundColor = .clear
            created.isOpaque = false
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
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
