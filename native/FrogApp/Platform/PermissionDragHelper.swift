import AppKit
import ApplicationServices
import IOKit.hid
import SwiftUI
import FrogCore

/// A privacy list in System Settings that Frog has to be added to by hand: opening it is one call, and the helper
/// below carries Frog's icon to drop into it. Checks reuse the system's own preflight calls.
enum PrivacyPane: String, CaseIterable {
    case accessibility, screenRecording, inputMonitoring, fullDiskAccess

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .inputMonitoring: "Input Monitoring"
        case .fullDiskAccess: "Full Disk Access"
        }
    }

    var url: URL {
        let anchor = switch self {
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .fullDiskAccess: "Privacy_AllFiles"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?" + anchor)!
    }

    /// nil when macOS offers no way to ask without a prompt (Full Disk Access).
    var granted: Bool? {
        switch self {
        case .accessibility: AXIsProcessTrusted()
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .inputMonitoring: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        case .fullDiskAccess: nil
        }
    }

    func open() { NSWorkspace.shared.open(url) }
}

/// The small floating panel that sits by the System Settings window while a privacy list is open: Frog's icon to
/// drag into the list, as other Mac apps do. It closes itself when the permission is granted, when System Settings
/// quits, or from its close button. It polls only while it is on screen.
@MainActor
final class PermissionDragHelper {
    enum Reason { case granted, dismissed, settingsQuit, replaced, hidden }

    static let shared = PermissionDragHelper()
    private static let settingsBundleID = "com.apple.systempreferences"
    static let panelSize = CGSize(width: 308, height: 64)

    private(set) var pane: PrivacyPane?
    private var panel: NSPanel?
    private var watcher: Task<Void, Never>?
    private var onFinish: ((Reason) -> Void)?

    /// Opens the pane and shows the helper. `onFinish` says why the helper went away.
    func present(_ pane: PrivacyPane, onFinish: ((Reason) -> Void)? = nil) {
        finish(.replaced)
        self.pane = pane
        self.onFinish = onFinish
        pane.open()
        let panel = makePanel(for: pane)
        self.panel = panel
        place(panel, window: Self.settingsWindowFrame())
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        watch(pane)
    }

    func hide() { finish(.hidden) }

    private func finish(_ reason: Reason) {
        watcher?.cancel(); watcher = nil
        let callback = onFinish
        onFinish = nil; pane = nil
        if let panel { panel.fadeOut(); self.panel = nil }
        callback?(reason)
    }

    // MARK: Watching

    /// Quick at first, while System Settings opens and its window appears; then once a second.
    private func watch(_ pane: PrivacyPane) {
        watcher = Task { [weak self] in
            let start = ContinuousClock.now
            var sawSettings = false
            // Ticks in a row with System Settings running but no window of it on screen.
            var windowless = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(ContinuousClock.now - start < .seconds(4) ? 400 : 1000))
                guard !Task.isCancelled, let self, self.pane == pane, let panel = self.panel else { return }
                if pane.granted == true { self.finish(.granted); return }
                if Self.settingsRunning { sawSettings = true }
                else if sawSettings || ContinuousClock.now - start > .seconds(10) { self.finish(.settingsQuit); return }
                let window = Self.settingsWindowFrame()
                windowless = window == nil ? windowless + 1 : 0
                // Its window closed while the app stays open: the user is done with it.
                if sawSettings, windowless >= 3, ContinuousClock.now - start > .seconds(4) { self.finish(.dismissed); return }
                self.place(panel, window: window)
            }
        }
    }

    private static var settingsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID).isEmpty
    }

    private func place(_ panel: NSPanel, window: CGRect?) {
        let screen = window.flatMap { rect in NSScreen.screens.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) } }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let frame = PermissionHelperPlacement.frame(panel: Self.panelSize, settingsWindow: window, screen: screen.visibleFrame)
        if abs(panel.frame.minX - frame.minX) > 1 || abs(panel.frame.minY - frame.minY) > 1 { panel.setFrame(frame, display: true) }
    }

    /// The largest on-screen System Settings window in AppKit coordinates. Owner PIDs and bounds need no
    /// Screen Recording permission; matching the process, not its localized name, works in every language.
    static func settingsWindowFrame() -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let height = NSScreen.screens.first?.frame.height else { return nil }
        let owners = Set(NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID).map(\.processIdentifier))
        guard !owners.isEmpty else { return nil }
        let rects = list.compactMap { info -> CGRect? in
            guard let owner = info[kCGWindowOwnerPID as String] as? Int32, owners.contains(owner),
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width >= 300, rect.height >= 200 else { return nil }
            return rect
        }
        return rects.max { $0.width * $0.height < $1.width * $1.height }
            .map { PermissionHelperPlacement.appKitRect(fromQuartz: $0, mainDisplayHeight: height) }
    }

    // MARK: Panel

    private func makePanel(for pane: PrivacyPane) -> NSPanel {
        let panel = HelperPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        let target = PermissionHelperPlacement.dragURL(bundleURL: Bundle.main.bundleURL, executableURL: Bundle.main.executableURL)
        panel.contentView = NSHostingView(rootView: PermissionDragHelperView(
            pane: pane, url: target.url, image: Self.icon(bundled: target.isBundle),
            open: { [weak self] in self?.pane?.open() }, close: { [weak self] in self?.finish(.dismissed) }
        ).frame(width: Self.panelSize.width, height: Self.panelSize.height))
        return panel
    }

    /// The app icon when running as an app; the Frog mark when running unbundled, where the icon is generic.
    static func icon(bundled: Bool) -> NSImage {
        if bundled { return NSApp.applicationIconImage }
        return FrogResources.bundle.url(forResource: "FrogLogo", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
            ?? NSApp.applicationIconImage
    }
}

/// Never takes focus, so System Settings stays the active app while the icon is dragged.
private final class HelperPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct PermissionDragHelperView: View {
    let pane: PrivacyPane
    let url: URL
    let image: NSImage
    let open: () -> Void
    let close: () -> Void
    @State private var closeHover = false

    var body: some View {
        HStack(spacing: 12) {
            DragIcon(url: url, image: image)
                .frame(width: 44, height: 44)
                .accessibilityLabel(L10n.text("Frog app icon, drag it into the \(pane.title) list"))
                .accessibilityHint(L10n.text("Drops Frog into the list in System Settings"))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: Text(L10n.text("Open \(pane.title) settings")), open)
                .help(L10n.text("Drag into the list"))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(L10n.text("Drag Frog into the list")).font(FrogType.rowMedium).lineLimit(1)
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .semibold)).foregroundStyle(FrogStyle.accent)
                        .accessibilityHidden(true)
                }
                Text(L10n.text("Then switch it on.")).font(FrogType.small).foregroundStyle(FrogStyle.muted)
            }
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(closeHover ? FrogStyle.ink : FrogStyle.muted)
                    .frame(width: 22, height: 22).contentShape(Circle())
            }
            .buttonStyle(.plain).onHover { closeHover = $0 }
            .accessibilityLabel(L10n.text("Close helper"))
        }
        .padding(FrogStyle.panelInset)
        .frogPanel()
    }
}

/// Frog's icon as a drag source: dragging provides the app's file URL, which a privacy list accepts.
private struct DragIcon: NSViewRepresentable {
    let url: URL
    let image: NSImage

    func makeNSView(context: Context) -> DragIconView { DragIconView(url: url, image: image) }
    func updateNSView(_ view: DragIconView, context: Context) { view.url = url; view.image = image }
}

private final class DragIconView: NSView, NSDraggingSource {
    var url: URL
    var image: NSImage { didSet { needsDisplay = true } }

    init(url: URL, image: NSImage) {
        self.url = url; self.image = image
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func draw(_ dirtyRect: NSRect) { image.draw(in: bounds) }

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
