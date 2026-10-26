import XCTest
import AppKit
import SwiftUI
import FrogCore
import FrogTestSupport
import FrogUsage
@testable import FrogApp

/// Pictures of every page of the Frog window, with every feature on, drawn without a window in light and dark.
/// Runs only with `FROG_PAGE_SHOTS` set to the folder for the pictures.
@MainActor
final class PageShotsTests: XCTestCase {
    func testEveryPage() async throws {
        guard let folder = ProcessInfo.processInfo.environment["FROG_PAGE_SHOTS"] else {
            throw XCTSkip("Set FROG_PAGE_SHOTS to a folder to take these pictures")
        }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var configuration = Configuration()
        for feature in FeatureID.allCases { configuration.preferences.setFeature(feature, enabled: true) }
        try ConfigurationStore(directory: root).save(configuration)
        let usage = UsageDashboardModel(defaults: temporaryDefaults(), fixtureRoot: root.appendingPathComponent("fixtures"))
        let toolkit = Toolkit(makeUsage: { usage }, showsUsageStatusItem: false)
        let model = AppModel(dataDirectory: root, registerShortcuts: false, readKey: { _ in nil }, readAccessibility: { true },
                             toolkit: toolkit, systemStatusTick: { try await Task.sleep(for: .seconds(3_600)) })
        defer { model.shutdown() }
        let only = ProcessInfo.processInfo.environment["FROG_PAGE_SHOTS_ONLY"]
        let routes: [(String, ToolkitRoute)] = FeatureID.allCases.map { ($0.rawValue, .feature($0)) }
            + [("history", .history), ("models", .models), ("features", .features), ("settings", .settings), ("statistics", .statistics)]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let name = appearance == .aqua ? "light" : "dark"
            if name == "dark", ProcessInfo.processInfo.environment["FROG_PAGE_SHOTS_DARK"] == nil { continue }
            for (route, value) in routes where only.map({ $0.split(separator: ",").contains(Substring(route)) }) ?? true {
                model.toolkit.select(value)
                let height: CGFloat = ProcessInfo.processInfo.environment["FROG_PAGE_SHOTS_TALL"] == nil ? 760 : 2_000
                let host = NSHostingView(rootView: MainView().environmentObject(model).frame(width: 1_000, height: height)
                    .background(FrogStyle.opaqueCanvas))
                host.appearance = NSAppearance(named: appearance)
                host.frame = NSRect(x: 0, y: 0, width: 1_000, height: height)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(500))
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: "\(folder)/\(route)-\(name).png"))
            }
        }
    }
}
