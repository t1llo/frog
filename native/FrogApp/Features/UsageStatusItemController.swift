import AppKit
import Combine
import SwiftUI
import FrogUsage

/// LLM usage's own menu-bar item, positioned on its own; it shows the plugin's model.
/// The autosave name is kept from the Mr. Usage days, so the item stays where it was put.
@MainActor final class UsageStatusItemController: NSObject {
    private let usage: UsageDashboardModel
    private let openDashboard: () -> Void
    private var item: NSStatusItem?
    private var observation: AnyCancellable?
    private var appearance: NSKeyValueObservation?
    private var timer: Timer?
    private var updateTask: Task<Void, Never>?
    /// What the item shows, so that a check finding the readout unchanged draws nothing.
    private var shownFace: UsageStatusReadout.Face?
    private var shownDescription: String?
    /// Borderless like Frog's own menu-bar popup: the same panel surface, no popover arrow.
    private let presenter = StatusItemPopup(name: UsageStatusPopover.popupName)
    var popup: NSPanel? { presenter.panel }
    var isInstalled: Bool { item != nil }
    var isPopupShown: Bool { presenter.isShown }

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
        // A coloured design draws its text for the menu bar's light or dark look.
        appearance = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.updateReadout() }
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
        appearance?.invalidate(); appearance = nil
        updateTask?.cancel(); updateTask = nil
        closePopup()
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    private func updateReadout() {
        guard let button = item?.button else { return }
        let (face, description) = UsageStatusReadout.readout(usage, dark: button.effectiveAppearance.isDark)
        // Most checks find the readout as it was; only what changed is drawn or set again.
        if face != shownFace { button.image = UsageStatusReadout.image(face); shownFace = face }
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
        let host = NSHostingView(rootView: UsageStatusPopover(usage: usage, openDashboard: { [weak self] in
            self?.closePopup(); self?.openDashboard()
        }, signIn: { [weak self] in
            self?.closePopup()
            if let usage = self?.usage { ClaudeSignIn.start(usage) }
        }, installUpdate: { [weak self] in
            self?.closePopup(); UpdateService.shared.installReadyUpdate()
        }, liveSetup: { [weak self] account in
            self?.closePopup(); self?.confirmLiveSetup(account)
        }, accountSignIn: { [weak self] account in
            self?.closePopup()
            if let usage = self?.usage { ClaudeSignIn.start(usage, account: account.id) }
        }).background(MenuWindowSizing()))
        presenter.show(host, relativeTo: anchor)
    }

    /// The popup has closed; the explanation comes first, then Terminal opens on request.
    private func confirmLiveSetup(_ account: UsageAccountSummary) {
        let alert = NSAlert()
        alert.messageText = ClaudeSignIn.liveSetupTitle(account.label)
        alert.informativeText = ClaudeSignIn.liveSetupMessage(account.label)
        alert.addButton(withTitle: "Open Terminal")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ClaudeSignIn.startLiveSetup(usage, account: account.id)
    }

    func closePopup() { presenter.close() }

    isolated deinit { stop() }
}

/// Two plan windows as a template readout with tiny tracks, or
/// draws the limits as one of the shared menu-bar meters.
enum UsageStatusReadout {
    /// Shown in place of plan windows: the selected period and its API-equivalent value.
    struct Estimate { let range: String; let value: String }

    /// Each Claude account side by side or combined, when Frog shows several; otherwise the one
    /// account or provider as always. Drawn in the look chosen on the LLM usage page.
    @MainActor static func readout(_ usage: UsageDashboardModel, dark: Bool) -> (Face, String) {
        var (face, description) = readout(usage)
        face.style = MenuBarMeterStyle(choice: usage.preferences.menuBarStyle)
        face.palette = MenuBarMeterPalette(choice: usage.preferences.menuBarPalette)
        // A clean design is a template, which macOS tints; only colours depend on the menu bar.
        face.dark = face.palette != .clean && dark
        return (face, description)
    }

    @MainActor private static func readout(_ usage: UsageDashboardModel) -> (Face, String) {
        let provider = usage.preferences.provider
        let accounts = provider == "Claude" && usage.claudeAccountsEnabled ? usage.accounts() : []
        if accounts.count >= 2 {
            let preferences = usage.preferences
            guard preferences.claudeAccountsView == "combined" else {
                return (Face(accounts: accounts, window: preferences.claudeAccountsMenuBar), description(accounts: accounts))
            }
            let combined = usage.combinedWindows()
            let counted = combined.prefix(2)
            return (Face(provider: provider, windows: counted.map(\.window), dimmed: counted.contains { !$0.missing.isEmpty }),
                    description(accounts: accounts, combined: combined))
        }
        let windows = usage.windows(provider: provider)
        // Without a plan reading the item still says something: the period's API estimate.
        let estimate = windows.isEmpty ? self.estimate(usage, provider: provider) : nil
        let face = Face(provider: provider, windows: windows, estimate: estimate, dimmed: usage.planWarning(provider: provider) != nil)
        let description = ([description(provider: provider, windows: windows, estimate: estimate),
                            usage.planName(provider: provider).map { "\($0) plan" },
                            usage.status(provider: provider)]).compactMap { $0 }.joined(separator: "\n")
        return (face, description)
    }

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
        /// One per entry while each Claude account is shown: a stale account recedes on its own.
        let dimmedEntries: [Bool]
        var style: MenuBarMeterStyle = .numbers
        var palette: MenuBarMeterPalette = .clean
        /// Whether the menu bar is dark; only a coloured design depends on it.
        var dark = false

        /// The limits as a shared meter, for every design but numbers. Without a plan reading
        /// (a name or an estimate) the readout stays text.
        var meter: MenuBarMeterFace? {
            guard style != .numbers, !fractions.isEmpty else { return nil }
            let rows = labels.indices.map { index in
                MenuBarMeterRow(label: labels[index], fraction: values[index] == "—" ? nil : fractions[index], value: values[index],
                                dimmed: dimmedEntries.indices.contains(index) && dimmedEntries[index])
            }
            return MenuBarMeterFace(rows: rows, style: style, palette: palette, dimmed: dimmed, dark: dark)
        }

        init(provider: String, windows: [UsageWindow], estimate: Estimate? = nil, dimmed: Bool = false) {
            let windows = Array(windows.prefix(2))
            self.provider = provider
            labels = windows.isEmpty ? [estimate?.range].compactMap { $0 } : windows.map { UsageStatusReadout.shortWindow($0) }
            values = windows.isEmpty ? [estimate?.value].compactMap { $0 } : windows.map(\.usedText)
            fractions = windows.map(UsageStatusReadout.fraction)
            self.dimmed = dimmed
            dimmedEntries = []
        }

        /// `A 37%  B 81%`: one entry per included account, for its session or its week
        /// (`window` is "session" or "week"). At most three; the description lists every one.
        init(accounts: [UsageAccountSummary], window: String) {
            let accounts = Array(accounts.filter(\.included).prefix(UsageStatusReadout.maximumAccounts))
            let id = UsageStatusReadout.windowID(window)
            let windows = accounts.map { $0.windows.first { $0.id == id } }
            provider = "Claude"
            labels = accounts.map(\.shortLabel)
            values = windows.map { $0?.usedText ?? "—" }
            fractions = windows.map { $0.map(UsageStatusReadout.fraction) ?? 0 }
            dimmed = false
            dimmedEntries = accounts.map(\.stale)
        }
    }

    static let maximumAccounts = 3

    /// The account window the menu bar shows: "session" or "week".
    static func windowID(_ choice: String) -> String { choice == "week" ? "seven_day" : "five_hour" }

    /// How full a window's track is, 0 to 1. A window without a reading has a NaN percentage,
    /// which never equals itself, so it is kept as 0.
    private static func fraction(_ window: UsageWindow) -> Double {
        window.percentage.isFinite ? min(1, max(0, window.percentage / 100)) : 0
    }

    static func image(provider: String, windows: [UsageWindow], estimate: Estimate? = nil, dimmed: Bool = false) -> NSImage {
        image(Face(provider: provider, windows: windows, estimate: estimate, dimmed: dimmed))
    }

    static func image(_ face: Face) -> NSImage {
        if let meter = face.meter { return MenuBarMeter.image(meter) }
        let ink = MenuBarMeter.Ink(palette: face.palette, dark: face.dark)
        let labelFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let (labels, values, fractions) = (face.labels, face.values, face.fractions)
        let widths = zip(labels, values).map { width($0, font: labelFont) + 4 + width($1, font: valueFont) }
        let total = ceil(widths.isEmpty ? width(face.provider, font: valueFont) : widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * 10)
        // A reading that could not be refreshed stays readable but recedes.
        let strength = face.dimmed ? 0.55 : 1
        let image = NSImage(size: NSSize(width: total, height: 22), flipped: false) { _ in
            if widths.isEmpty { draw(face.provider, at: NSPoint(x: 0, y: 4), font: valueFont, color: ink.text(1)) }
            else {
                var x: CGFloat = 0
                for index in widths.indices {
                    let strength = face.dimmedEntries.indices.contains(index) && face.dimmedEntries[index] ? strength * 0.55 : strength
                    draw(labels[index], at: NSPoint(x: x, y: fractions.isEmpty ? 6 : 7), font: labelFont, color: ink.text(0.7 * strength))
                    draw(values[index], at: NSPoint(x: x + width(labels[index], font: labelFont) + 4, y: fractions.isEmpty ? 4 : 5), font: valueFont, color: ink.text(strength))
                    guard fractions.indices.contains(index) else { continue }
                    let track = NSRect(x: x, y: 2, width: widths[index], height: 2)
                    ink.track(face.palette == .clean ? 1 : strength).setFill()
                    NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
                    let fraction = fractions[index]
                    if fraction > 0 {
                        ink.fill(fraction: fraction, position: fraction, strength: face.palette == .clean ? 0.85 / 0.88 * strength : strength).setFill()
                        NSBezierPath(roundedRect: NSRect(x: x, y: 2, width: max(2, widths[index] * fraction), height: 2), xRadius: 1, yRadius: 1).fill()
                    }
                    x += widths[index] + 10
                }
            }
            return true
        }
        image.isTemplate = face.palette == .clean
        return image
    }
    static func description(provider: String, windows: [UsageWindow], estimate: Estimate? = nil) -> String {
        (["LLM usage · \(provider)"] + windows.map {
            !$0.percentage.isFinite ? "\($0.title): no reading since it renewed"
                : "\($0.title): \($0.usedText) used" + ($0.resetsAt.map { " · resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
        } + (windows.isEmpty ? [estimate.map { "API estimate, last \($0.range): \($0.value)" }].compactMap { $0 } : [])).joined(separator: "\n")
    }
    /// One line per account and window, such as "B · Session 81% used · resets 17:10 · Claude app,
    /// 2h ago". Combined values come first, under "A + B combined" and how they are weighted.
    /// Never an e-mail address: the summaries carry none.
    static func description(accounts: [UsageAccountSummary], combined: [UsageCombinedWindow]? = nil,
                            now: Date = Date()) -> String {
        let accounts = accounts.filter(\.included)
        var lines: [String]
        if let combined {
            lines = [accounts.map(\.label).joined(separator: " + ") + " combined"]
            lines += combined.map { entry in
                let window = entry.window
                guard window.percentage.isFinite else { return "\(window.title): no current reading" }
                return "\(window.title): \(window.usedText) used" + (entry.breakdown.isEmpty ? "" : " · \(entry.breakdown)")
                    + (entry.missing.isEmpty ? "" : " · \(entry.missing.joined(separator: ", ")): no current reading")
            }
            if let basis = combined.first?.basisDescription { lines.append(basis) }
        } else {
            lines = ["LLM usage · Claude"]
        }
        for account in accounts {
            let origin = [account.readingSource, account.age.map { UsageStatusPopover.age(of: $0, at: now) }]
                .compactMap { $0 }.joined(separator: ", ")
            let suffix = origin.isEmpty ? "" : " · \(origin)"
            guard !account.windows.isEmpty else { lines.append("\(account.label) · no current reading"); continue }
            for window in account.windows {
                let reading = window.percentage.isFinite
                    ? "\(window.title) \(window.usedText) used" + (window.resetText(now: now).map { " · resets \($0)" } ?? "")
                    : "\(window.title): no reading since it renewed"
                lines.append("\(account.label) · \(reading)\(suffix)")
            }
        }
        return lines.joined(separator: "\n")
    }
    private static func shortWindow(_ window: UsageWindow) -> String {
        guard let seconds = window.duration, seconds.isFinite, seconds > 0 else { return String(window.title.prefix(1)) }
        let divisor: Double = seconds >= 86400 ? 86400 : seconds >= 3600 ? 3600 : 60
        let unit = seconds >= 86400 ? "d" : seconds >= 3600 ? "h" : "m"
        let value = seconds / divisor
        return (value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)) + unit
    }
    private static func width(_ text: String, font: NSFont) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
    private static func draw(_ text: String, at point: NSPoint, font: NSFont, color: NSColor) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }
}
