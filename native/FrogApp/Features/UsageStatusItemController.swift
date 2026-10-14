import AppKit
import Combine
import SwiftUI
import FrogUsage

/// A second, independently positioned status item owned by the optional Usage feature.
/// It presents Frog's existing model; no helper app or second collector is launched.
@MainActor final class UsageStatusItemController: NSObject {
    private let usage: UsageDashboardModel
    private let openDashboard: () -> Void
    private var item: NSStatusItem?
    private var observation: AnyCancellable?
    private var timer: Timer?
    private var updateTask: Task<Void, Never>?
    /// What the item shows, so that a check finding the readout unchanged draws nothing.
    private var shownFace: UsageStatusReadout.Face?
    private var shownDescription: String?
    /// Borderless like Frog's own menu-bar popup: the same panel surface, no popover arrow.
    private(set) var popup: NSPanel?
    private var localClick: Any?
    private var outsideClick: Any?
    private var deactivation: NSObjectProtocol?
    private var otherPopup: NSObjectProtocol?
    var isInstalled: Bool { item != nil }
    var isPopupShown: Bool { popup?.isVisible == true }

    init(usage: UsageDashboardModel, openDashboard: @escaping () -> Void) {
        self.usage = usage; self.openDashboard = openDashboard
        super.init()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "Frog.MrUsage"
        self.item = item
        item.button?.target = self
        item.button?.action = #selector(togglePopup)
        observation = usage.objectWillChange.sink { [weak self] _ in
            // ObservableObject emits before mutation. Coalesce and draw the new snapshot.
            self?.updateTask?.cancel()
            self?.updateTask = Task { @MainActor [weak self] in
                guard !Task.isCancelled else { return }
                self?.updateReadout()
            }
        }
        // Also expire server windows when no new request has completed.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateReadout() }
        }
        timer?.tolerance = 3
        updateReadout()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        observation?.cancel(); observation = nil
        updateTask?.cancel(); updateTask = nil
        closePopup()
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    private func updateReadout() {
        guard let button = item?.button else { return }
        let provider = usage.preferences.provider
        let windows = usage.windows(provider: provider)
        // Without a plan reading the item still says something: the period's API estimate.
        let estimate = windows.isEmpty ? UsageStatusReadout.estimate(usage, provider: provider) : nil
        // Most checks find the readout as it was; only what changed is drawn or set again.
        let face = UsageStatusReadout.Face(provider: provider, windows: windows, estimate: estimate,
                                           dimmed: usage.planWarning(provider: provider) != nil)
        if face != shownFace { button.image = UsageStatusReadout.image(face); shownFace = face }
        let description = ([UsageStatusReadout.description(provider: provider, windows: windows, estimate: estimate),
                            usage.planName(provider: provider).map { "\($0) plan" },
                            usage.status(provider: provider)]).compactMap { $0 }.joined(separator: "\n")
        guard description != shownDescription else { return }
        shownDescription = description
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    @objc private func togglePopup() {
        guard let button = item?.button else { return }
        if isPopupShown { closePopup() } else { showPopup(relativeTo: button) }
    }

    func showPopup(relativeTo anchor: NSView) {
        closePopup()
        // Frog's own menu-bar popup closes itself when this one opens, and the reverse.
        NotificationCenter.default.post(name: .frogMenuPopupWillOpen, object: UsageStatusPopover.popupName)
        let host = NSHostingView(rootView: UsageStatusPopover(usage: usage, openDashboard: { [weak self] in
            self?.closePopup(); self?.openDashboard()
        }, signIn: { [weak self] in
            self?.closePopup()
            if let usage = self?.usage { ClaudeSignIn.start(usage) }
        }, installUpdate: { [weak self] in
            self?.closePopup(); UpdateService.shared.installReadyUpdate()
        }).background(MenuWindowSizing()))
        let size = host.fittingSize
        let panel = UsagePopupPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.onCancel = { [weak self] in self?.closePopup() }
        panel.contentView = host
        panel.setFrameOrigin(Self.popupOrigin(size: size, anchor: anchor))
        popup = panel
        panel.makeKeyAndOrderFront(nil)
        localClick = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self, weak anchor] event in
            guard let self, let popup = self.popup else { return event }
            // The popup and the menus it opens are inside; everything else in Frog dismisses it.
            var window = event.window
            while let current = window { if current === popup { return event }; window = current.parent }
            // Let the status button's own action toggle once, rather than close/reopen.
            if let anchor, event.window === anchor.window,
               anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) { return event }
            self.closePopup()
            return event
        }
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.closePopup()
        }
        deactivation = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePopup() }
        }
        otherPopup = NotificationCenter.default.addObserver(forName: .frogMenuPopupWillOpen, object: nil, queue: .main) { [weak self] note in
            let other = note.object as? String != UsageStatusPopover.popupName
            MainActor.assumeIsolated { if other { self?.closePopup() } }
        }
    }

    /// Directly beneath the status item and left-aligned with it, like a MenuBarExtra window,
    /// kept inside the item's display.
    private static func popupOrigin(size: NSSize, anchor: NSView) -> NSPoint {
        let button = anchor.window?.convertToScreen(anchor.convert(anchor.bounds, to: nil)) ?? .zero
        var origin = NSPoint(x: button.minX, y: button.minY - 5 - size.height)
        if let visible = (anchor.window?.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))
            origin.y = max(visible.minY + 8, origin.y)
        }
        return origin
    }

    func closePopup() {
        if let localClick { NSEvent.removeMonitor(localClick) }; localClick = nil
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }; outsideClick = nil
        for observer in [deactivation, otherPopup].compactMap({ $0 }) { NotificationCenter.default.removeObserver(observer) }
        deactivation = nil; otherPopup = nil
        guard let popup else { return }
        self.popup = nil
        popup.orderOut(nil)
        // Popup content is created when opened; releasing it ends its visible refresh.
        popup.contentView = nil
    }

    isolated deinit { stop() }
}

/// A borderless panel takes no key focus by default; the popup's controls and Escape need it.
private final class UsagePopupPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Matches standalone Mr. Usage's two-window template readout, including its tiny tracks.
enum UsageStatusReadout {
    /// Shown in place of plan windows: the selected period and its API-equivalent value.
    struct Estimate { let range: String; let value: String }

    @MainActor static func estimate(_ usage: UsageDashboardModel, provider: String) -> Estimate? {
        let chart = usage.chart(provider: provider, range: usage.preferences.range, metric: "API cost")
        guard chart.hasActivity, let cost = chart.totals.first(where: { $0.name == "API cost" })?.value, cost >= 0.5 else { return nil }
        return Estimate(range: chart.range, value: usage.axisLabel(cost.rounded(), metric: "API cost"))
    }

    /// Everything the image shows. Two equal faces draw the same image.
    struct Face: Equatable {
        let provider: String
        let labels: [String]
        let values: [String]
        /// How full each plan window's track is, 0 to 1; none for the estimate. A window without
        /// a reading has a NaN percentage, which never equals itself, so it is kept as 0 here.
        let fractions: [Double]
        let dimmed: Bool

        init(provider: String, windows: [UsageWindow], estimate: Estimate? = nil, dimmed: Bool = false) {
            let windows = Array(windows.prefix(2))
            self.provider = provider
            labels = windows.isEmpty ? [estimate?.range].compactMap { $0 } : windows.map { UsageStatusReadout.shortWindow($0) }
            values = windows.isEmpty ? [estimate?.value].compactMap { $0 } : windows.map(\.usedText)
            fractions = windows.map { $0.percentage.isFinite ? min(1, max(0, $0.percentage / 100)) : 0 }
            self.dimmed = dimmed
        }
    }

    static func image(provider: String, windows: [UsageWindow], estimate: Estimate? = nil, dimmed: Bool = false) -> NSImage {
        image(Face(provider: provider, windows: windows, estimate: estimate, dimmed: dimmed))
    }

    static func image(_ face: Face) -> NSImage {
        let labelFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let (labels, values, fractions) = (face.labels, face.values, face.fractions)
        let widths = zip(labels, values).map { width($0, font: labelFont) + 4 + width($1, font: valueFont) }
        let total = ceil(widths.isEmpty ? width(face.provider, font: valueFont) : widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * 10)
        // A reading that could not be refreshed stays readable but recedes.
        let strength = face.dimmed ? 0.55 : 1
        let image = NSImage(size: NSSize(width: total, height: 22), flipped: false) { _ in
            if widths.isEmpty { draw(face.provider, at: NSPoint(x: 0, y: 4), font: valueFont) }
            else {
                var x: CGFloat = 0
                for index in widths.indices {
                    draw(labels[index], at: NSPoint(x: x, y: fractions.isEmpty ? 6 : 7), font: labelFont, opacity: 0.7 * strength)
                    draw(values[index], at: NSPoint(x: x + width(labels[index], font: labelFont) + 4, y: fractions.isEmpty ? 4 : 5), font: valueFont, opacity: strength)
                    guard fractions.indices.contains(index) else { continue }
                    let track = NSRect(x: x, y: 2, width: widths[index], height: 2)
                    NSColor.black.withAlphaComponent(0.18).setFill()
                    NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
                    let fraction = fractions[index]
                    if fraction > 0 {
                        NSColor.black.withAlphaComponent(0.85 * strength).setFill()
                        NSBezierPath(roundedRect: NSRect(x: x, y: 2, width: max(2, widths[index] * fraction), height: 2), xRadius: 1, yRadius: 1).fill()
                    }
                    x += widths[index] + 10
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
    static func description(provider: String, windows: [UsageWindow], estimate: Estimate? = nil) -> String {
        (["Mr. Usage · \(provider)"] + windows.map {
            !$0.percentage.isFinite ? "\($0.title): no reading since it renewed"
                : "\($0.title): \($0.usedText) used" + ($0.resetsAt.map { " · resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
        } + (windows.isEmpty ? [estimate.map { "API estimate, last \($0.range): \($0.value)" }].compactMap { $0 } : [])).joined(separator: "\n")
    }
    private static func shortWindow(_ window: UsageWindow) -> String {
        guard let seconds = window.duration, seconds.isFinite, seconds > 0 else { return String(window.title.prefix(1)) }
        let divisor: Double = seconds >= 86400 ? 86400 : seconds >= 3600 ? 3600 : 60
        let unit = seconds >= 86400 ? "d" : seconds >= 3600 ? "h" : "m"
        let value = seconds / divisor
        return (value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)) + unit
    }
    private static func width(_ text: String, font: NSFont) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
    private static func draw(_ text: String, at point: NSPoint, font: NSFont, opacity: Double = 1) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: NSColor.black.withAlphaComponent(opacity)])
    }
}
