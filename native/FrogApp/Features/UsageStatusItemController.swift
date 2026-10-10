import AppKit
import Combine
import SwiftUI
import FrogUsage

/// A second, independently positioned status item owned by the optional Usage feature.
/// It presents Frog's existing model; no helper app or second collector is launched.
@MainActor final class UsageStatusItemController: NSObject, NSPopoverDelegate {
    private let usage: UsageDashboardModel
    private let openDashboard: () -> Void
    private var item: NSStatusItem?
    private var observation: AnyCancellable?
    private var timer: Timer?
    private var updateTask: Task<Void, Never>?
    let popover = NSPopover()
    private var localClick: Any?
    private var outsideClick: Any?
    private var deactivation: NSObjectProtocol?
    static func popupSize(availableHeight: CGFloat) -> NSSize {
        NSSize(width: 360, height: min(360, max(180, availableHeight - 28)))
    }
    var isInstalled: Bool { item != nil }

    init(usage: UsageDashboardModel, openDashboard: @escaping () -> Void) {
        self.usage = usage; self.openDashboard = openDashboard
        super.init()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "Frog.MrUsage"
        self.item = item
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
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
        updateReadout()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        observation?.cancel(); observation = nil
        updateTask?.cancel(); updateTask = nil
        removeDismissalObservers()
        popover.close(); popover.contentViewController = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    private func updateReadout() {
        guard let button = item?.button else { return }
        let provider = usage.preferences.provider
        let windows = usage.windows(provider: provider)
        button.image = UsageStatusReadout.image(provider: provider, windows: windows)
        let description = ([UsageStatusReadout.description(provider: provider, windows: windows),
                            usage.planName(provider: provider).map { "\($0) plan" },
                            usage.status(provider: provider)]).compactMap { $0 }.joined(separator: "\n")
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    @objc private func togglePopover() {
        guard let button = item?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { showPopover(relativeTo: button) }
    }

    func showPopover(relativeTo anchor: NSView) {
        let size = Self.popupSize(availableHeight: anchor.window?.screen?.visibleFrame.height ?? 760)
        popover.contentViewController = NSHostingController(rootView: UsageStatusPopover(usage: usage, height: size.height) { [weak self] in
            self?.popover.close(); self?.openDashboard()
        })
        popover.contentSize = size
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        removeDismissalObservers()
        localClick = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self, weak anchor] event in
            guard let self, self.popover.isShown else { return event }
            if event.window === self.popover.contentViewController?.view.window { return event }
            // Let the status button's own action toggle once, rather than close/reopen.
            if let anchor, event.window === anchor.window,
               anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) { return event }
            self.popover.performClose(nil)
            return event
        }
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
        }
        deactivation = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
    }

    func popoverDidClose(_ notification: Notification) { removeDismissalObservers(); popover.contentViewController = nil }
    private func removeDismissalObservers() {
        if let localClick { NSEvent.removeMonitor(localClick) }; localClick = nil
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }; outsideClick = nil
        if let deactivation { NotificationCenter.default.removeObserver(deactivation) }; deactivation = nil
    }

    isolated deinit { stop() }
}

/// Matches standalone Mr. Usage's two-window template readout, including its tiny tracks.
enum UsageStatusReadout {
    static func image(provider: String, windows: [UsageWindow]) -> NSImage {
        let labelFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let windows = Array(windows.prefix(2))
        let labels = windows.map { shortWindow($0) }
        let values = windows.map { percentage($0.percentage) }
        let widths = zip(labels, values).map { width($0, font: labelFont) + 4 + width($1, font: valueFont) }
        let total = ceil(windows.isEmpty ? width(provider, font: valueFont) : widths.reduce(0, +) + CGFloat(max(0, windows.count - 1)) * 10)
        let image = NSImage(size: NSSize(width: total, height: 22), flipped: false) { _ in
            if windows.isEmpty { draw(provider, at: NSPoint(x: 0, y: 4), font: valueFont) }
            else {
                var x: CGFloat = 0
                for index in windows.indices {
                    draw(labels[index], at: NSPoint(x: x, y: 7), font: labelFont, opacity: 0.7)
                    draw(values[index], at: NSPoint(x: x + width(labels[index], font: labelFont) + 4, y: 5), font: valueFont)
                    let track = NSRect(x: x, y: 2, width: widths[index], height: 2)
                    NSColor.black.withAlphaComponent(0.18).setFill()
                    NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
                    let value = windows[index].percentage
                    let fraction = value.isFinite ? min(1, max(0, value / 100)) : 0
                    if fraction > 0 {
                        NSColor.black.withAlphaComponent(0.85).setFill()
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
    static func description(provider: String, windows: [UsageWindow]) -> String {
        (["Mr. Usage · \(provider)"] + windows.map {
            "\($0.title): \(percentage($0.percentage)) used" + ($0.resetsAt.map { " · resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
        }).joined(separator: "\n")
    }
    private static func shortWindow(_ window: UsageWindow) -> String {
        guard let seconds = window.duration, seconds.isFinite, seconds > 0 else { return String(window.title.prefix(1)) }
        let divisor: Double = seconds >= 86400 ? 86400 : seconds >= 3600 ? 3600 : 60
        let unit = seconds >= 86400 ? "d" : seconds >= 3600 ? "h" : "m"
        let value = seconds / divisor
        return (value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)) + unit
    }
    private static func percentage(_ value: Double) -> String { value.isFinite ? String(format: "%.0f%%", value.rounded(.towardZero)) : "—" }
    private static func width(_ text: String, font: NSFont) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
    private static func draw(_ text: String, at point: NSPoint, font: NSFont, opacity: Double = 1) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: NSColor.black.withAlphaComponent(opacity)])
    }
}
