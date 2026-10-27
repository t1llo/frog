import AppKit
import Combine
import SwiftUI
import FrogCore

/// CPU and GPU load as an item of its own in the menu bar, while System monitor is on and its
/// menu-bar item is chosen. Clicking it opens the system overview beneath it.
@MainActor final class SystemMonitorStatusItemController: NSObject {
    static let popupName = "System"
    private let monitor: SystemMonitor
    private let openFrog: () -> Void
    private var preferences: SystemMonitorPreferences
    private var item: NSStatusItem?
    private var readings: AnyCancellable?
    private var appearance: NSKeyValueObservation?
    private var reading: SystemMonitorReading?
    private var shownFace: MenuBarMeterFace?
    private var shownDescription: String?
    private let presenter = StatusItemPopup(name: SystemMonitorStatusItemController.popupName)
    var isPopupShown: Bool { presenter.isShown }

    init(monitor: SystemMonitor, preferences: SystemMonitorPreferences, openFrog: @escaping () -> Void) {
        self.monitor = monitor; self.preferences = preferences; self.openFrog = openFrog
        super.init()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "Frog.SystemMonitor"
        self.item = item
        item.button?.target = self
        item.button?.action = #selector(togglePopup)
        appearance = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.update() }
        }
        monitor.setLiveReadout(true)
        readings = monitor.readings.sink { [weak self] reading in
            self?.reading = reading
            self?.update()
        }
    }

    func apply(_ preferences: SystemMonitorPreferences) {
        guard self.preferences != preferences else { return }
        self.preferences = preferences
        update()
    }

    func stop() {
        readings?.cancel(); readings = nil
        appearance?.invalidate(); appearance = nil
        monitor.setLiveReadout(false)
        presenter.close()
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    private func update() {
        guard let button = item?.button else { return }
        let face = Self.face(reading, preferences: preferences, dark: button.effectiveAppearance.isDark)
        if face != shownFace { button.image = MenuBarMeter.image(face); shownFace = face }
        let description = Self.description(reading)
        guard description != shownDescription else { return }
        shownDescription = description
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    /// CPU above GPU. A Mac whose GPU driver gives no load shows CPU alone.
    nonisolated static func face(_ reading: SystemMonitorReading?, preferences: SystemMonitorPreferences, dark: Bool) -> MenuBarMeterFace {
        let palette = MenuBarMeterPalette(choice: preferences.menuBarPalette)
        var rows = [MenuBarMeterRow(label: "CPU", fraction: reading?.cpu.value)]
        if reading?.gpu != .unavailable { rows.append(MenuBarMeterRow(label: "GPU", fraction: reading?.gpu.value)) }
        return MenuBarMeterFace(rows: rows, style: MenuBarMeterStyle(choice: preferences.menuBarStyle), palette: palette,
                                dark: palette != .clean && dark)
    }

    nonisolated static func description(_ reading: SystemMonitorReading?) -> String {
        func text(_ metric: SystemMonitorMetric?) -> String {
            switch metric {
            case .value(let fraction): "\(Int((fraction * 100).rounded()))%"
            case .unavailable: "unavailable"
            default: "measuring…"
            }
        }
        return "System monitor\nCPU \(text(reading?.cpu)) · GPU \(text(reading?.gpu))"
    }

    @objc private func togglePopup() {
        guard let button = item?.button else { return }
        if presenter.isShown { presenter.close(); return }
        let host = NSHostingView(rootView: SystemMonitorStatusPopover(monitor: monitor) { [weak self] in
            self?.presenter.close(); self?.openFrog()
        }.background(MenuWindowSizing()))
        presenter.show(host, relativeTo: button)
    }

    isolated deinit { stop() }
}

/// The overview from Frog's System tab, on its own beneath the CPU and GPU item.
struct SystemMonitorStatusPopover: View {
    @ObservedObject var monitor: SystemMonitor
    let openSettings: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "gauge.medium").foregroundStyle(FrogStyle.muted)
                Text("System").font(FrogType.section)
                Spacer()
            }.padding(.horizontal, 8).frame(height: 40)
            SystemMonitorView(monitor: monitor, presenter: .statusItem)
            MenuActionRow(title: "Menu bar item settings…", symbol: "slider.horizontal.3", action: openSettings)
        }.padding(6).frame(width: 292).fixedSize(horizontal: false, vertical: true)
            .font(FrogType.body).foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent).controlSize(.small)
            .frogPanel()
            .environment(\.locale, L10n.locale)
    }
}
