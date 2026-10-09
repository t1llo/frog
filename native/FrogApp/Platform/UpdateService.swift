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
}

struct UpdateSettingsView: View {
    @ObservedObject private var updater = UpdateService.shared
    var body: some View {
        CompactRow(title: "Check automatically") { Toggle("Check automatically", isOn: Binding(get: { updater.automaticChecks }, set: updater.setAutomaticChecks)).labelsHidden() }
        Divider()
        CompactRow(title: "Download updates automatically") { Toggle("Download updates automatically", isOn: Binding(get: { updater.automaticDownloads }, set: updater.setAutomaticDownloads)).labelsHidden() }
        CompactRow(title: "Software updates") { Button("Check for Updates") { updater.check() }.disabled(!updater.canCheck) }
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = UpdateService.shared
    var body: some View { Button("Check for Updates…") { updater.check() }.disabled(!updater.canCheck) }
}
