import AppKit
import SwiftUI
import XCTest
@testable import FrogApp

/// A plugin page in a state the page-shot test cannot reach, such as a running session or an open review, as
/// `<FROG_PAGE_SHOTS>/<name>-light.png` (and `-dark.png` with `FROG_PAGE_SHOTS_DARK`). Skips without `FROG_PAGE_SHOTS`.
@MainActor func savePluginPageShot(_ name: String, model: AppModel, height: CGFloat = 760, settle: Duration = .milliseconds(400),
                                   page: () -> AnyView) async throws {
    guard let folder = ProcessInfo.processInfo.environment["FROG_PAGE_SHOTS"] else {
        throw XCTSkip("Set FROG_PAGE_SHOTS to a folder to take these pictures")
    }
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let dark = ProcessInfo.processInfo.environment["FROG_PAGE_SHOTS_DARK"] != nil
    for appearance in dark ? [NSAppearance.Name.aqua, .darkAqua] : [.aqua] {
        let host = NSHostingView(rootView: page().environmentObject(model).frame(width: 760, height: height)
            .background(FrogStyle.opaqueCanvas))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(x: 0, y: 0, width: 760, height: height)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: settle)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "\(folder)/\(name)-\(appearance == .aqua ? "light" : "dark").png"))
    }
}
