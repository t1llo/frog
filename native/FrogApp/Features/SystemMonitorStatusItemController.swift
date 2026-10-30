import AppKit
import Combine
import SwiftUI

/// System monitor's own menu-bar item: the chosen readings as a meter. Clicking it opens the overview
/// beneath it. While it exists the monitor samples, also with every overview closed.
@MainActor final class SystemMonitorStatusItemController: NSObject {
    static let popupName = "System"
    private let monitor: SystemMonitor
    private let openPage: () -> Void
    private var settings: SystemMonitorSettings
    private var item: NSStatusItem?
    private var readings: AnyCancellable?
    private var appearance: NSKeyValueObservation?
    private var reading: SystemMonitorReading?
    private var shownFace: MenuBarMeterFace?
    private var shownDescription: String?
    private let presenter = StatusItemPopup(name: SystemMonitorStatusItemController.popupName)
    var isPopupShown: Bool { presenter.isShown }

    init(monitor: SystemMonitor, settings: SystemMonitorSettings, openPage: @escaping () -> Void) {
        self.monitor = monitor; self.settings = settings; self.openPage = openPage
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

    func apply(_ settings: SystemMonitorSettings) {
        guard self.settings != settings else { return }
        self.settings = settings
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
        let face = Self.face(reading, settings: settings, dark: button.effectiveAppearance.isDark)
        if face != shownFace { button.image = MenuBarMeter.image(face); shownFace = face }
        let description = Self.description(reading)
        guard description != shownDescription else { return }
        shownDescription = description
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    /// The chosen readings, top to bottom. A Mac whose GPU driver gives no load leaves GPU out.
    nonisolated static func face(_ reading: SystemMonitorReading?, settings: SystemMonitorSettings, dark: Bool) -> MenuBarMeterFace {
        let readings = settings.menuBarReadings
        var rows = [MenuBarMeterRow(label: "CPU", fraction: reading?.cpu.value)]
        if readings.gpu, reading?.gpu != .unavailable { rows.append(MenuBarMeterRow(label: "GPU", fraction: reading?.gpu.value)) }
        if readings.memory { rows.append(MenuBarMeterRow(label: "MEM", fraction: reading?.memory.value)) }
        return MenuBarMeterFace(rows: rows, style: settings.menuBarStyle, palette: settings.menuBarPalette,
                                dark: settings.menuBarPalette != .clean && dark)
    }

    nonisolated static func description(_ reading: SystemMonitorReading?) -> String {
        func text(_ metric: SystemMonitorMetric?) -> String {
            switch metric {
            case .value(let fraction): "\(Int((fraction * 100).rounded()))%"
            case .unavailable: "unavailable"
            default: "measuring…"
            }
        }
        return "System monitor\nCPU \(text(reading?.cpu)) · GPU \(text(reading?.gpu)) · Memory \(text(reading?.memory))"
    }

    @objc private func togglePopup() {
        guard let button = item?.button else { return }
        if presenter.isShown { presenter.close(); return }
        let host = NSHostingView(rootView: SystemMonitorStatusPopover(monitor: monitor) { [weak self] in
            self?.presenter.close(); self?.openPage()
        }.background(MenuWindowSizing()))
        presenter.show(host, relativeTo: button)
    }

    isolated deinit { stop() }
}

/// The overview from Frog's System tab, on its own beneath the menu-bar item.
struct SystemMonitorStatusPopover: View {
    @ObservedObject var monitor: SystemMonitor
    let openPage: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "gauge.medium").foregroundStyle(FrogStyle.muted)
                Text("System").font(FrogType.section)
                Spacer()
                IconAction(title: "Open System monitor", symbol: "arrow.up.forward.app", action: openPage)
            }.padding(.horizontal, 8).frame(height: 40)
            SystemMonitorView(monitor: monitor, presenter: .statusPopup)
        }.padding(6).frame(width: 292).fixedSize(horizontal: false, vertical: true)
            .font(FrogType.body).foregroundStyle(FrogStyle.ink).tint(FrogStyle.accent).controlSize(.small)
            .frogPanel()
            .environment(\.locale, L10n.locale)
    }
}
