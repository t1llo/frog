import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor
final class UpdateService: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdateService()
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = false
    @Published private(set) var automaticDownloads = false
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    private let connectivityRecovery = UpdateConnectivityRecovery()
    private var started = false
    private override init() {
        super.init()
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main).assign(to: &$canCheck)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: DispatchQueue.main).assign(to: &$automaticChecks)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates).receive(on: DispatchQueue.main).assign(to: &$automaticDownloads)
    }
    func start() {
        guard !started, Bundle.main.bundleURL.pathExtension == "app" else { return }
        controller.startUpdater()
        started = controller.updater.canCheckForUpdates
        if started, controller.updater.automaticallyChecksForUpdates {
            controller.updater.checkForUpdatesInBackground()
        }
    }
    func check() { controller.checkForUpdates(nil) }
    /// From a menu-bar popup Frog is not the active app, and Sparkle's window must not open behind others.
    func installReadyUpdate() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        check()
    }
    func setAutomaticChecks(_ enabled: Bool) {
        if !enabled { connectivityRecovery.cancel() }
        controller.updater.automaticallyChecksForUpdates = enabled
    }
    func setAutomaticDownloads(_ enabled: Bool) { controller.updater.automaticallyDownloadsUpdates = enabled }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        connectivityRecovery.updateCycleFinished(error: error,
            isAutomaticCheck: updateCheck == .updatesInBackground && updater.automaticallyChecksForUpdates) { [weak updater] in
            guard let updater, updater.automaticallyChecksForUpdates, !updater.sessionInProgress else { return false }
            updater.checkForUpdatesInBackground()
            return true
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        UpdateReadiness.shared.ready(item.displayVersionString)
        // Sparkle keeps the update: it installs on quit, and a check offers to install and relaunch.
        return false
    }
}

/// The update Sparkle has downloaded and will install when Frog quits. Frog runs for days, so
/// the menu-bar popups and Settings name it instead of leaving it unseen until then.
@MainActor final class UpdateReadiness: ObservableObject {
    static let shared = UpdateReadiness()
    @Published private(set) var version: String?
    func ready(_ version: String?) { self.version = version?.isEmpty == false ? version : nil }
}

/// In both menu-bar popups while an update waits for Frog to quit. Sparkle's own window then
/// offers to install it and relaunch.
struct UpdateReadyRow: View {
    @ObservedObject private var readiness = UpdateReadiness.shared
    let install: () -> Void
    var body: some View {
        if let version = readiness.version {
            MenuActionRow(title: "Update to \(version) is ready…", symbol: "arrow.down.circle", action: install)
                .help("Frog installs it when it quits. Choose this to install it and relaunch now.")
        }
    }
}

struct UpdateSettingsView: View {
    @ObservedObject private var updater = UpdateService.shared
    @ObservedObject private var readiness = UpdateReadiness.shared
    var body: some View {
        if let version = readiness.version {
            CompactRow(title: "Version \(version) is ready", detail: "Frog installs it when it quits.") {
                Button("Install and Relaunch…") { updater.check() }.buttonStyle(.frog(.primary))
            }
        }
        CompactRow(title: "Check automatically") { Toggle("Check automatically", isOn: Binding(get: { updater.automaticChecks }, set: updater.setAutomaticChecks)).labelsHidden() }
        CompactRow(title: "Download updates automatically") { Toggle("Download updates automatically", isOn: Binding(get: { updater.automaticDownloads }, set: updater.setAutomaticDownloads)).labelsHidden() }
        CompactRow(title: "Software updates") { Button("Check for Updates") { updater.check() }.disabled(!updater.canCheck) }
    }
}
