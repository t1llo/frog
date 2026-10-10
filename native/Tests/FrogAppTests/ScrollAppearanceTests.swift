import AppKit
import SwiftUI
import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class ScrollAppearanceTests: XCTestCase {
    func testPopupUsesActiveNativeBackdropAndIndependentSurfaceOpacity() async throws {
        _ = NSApplication.shared
        let original = FrogAppearance.shared.settings
        defer { FrogAppearance.shared.apply(original) }
        var settings = AppearancePreferences(); settings.transparency = 1; settings.popupTransparency = 0.25
        FrogAppearance.shared.apply(settings)
        let style = FrogSurfaceStyle(color: .black, settings: settings, strength: 0.8)
        var environment = EnvironmentValues()
        XCTAssertEqual(style.opacity(in: environment), 0.2, accuracy: 0.001)
        environment.frogPopupSurface = true
        XCTAssertEqual(style.opacity(in: environment), 0.8, accuracy: 0.001)

        let host = NSHostingView(rootView: Text("Synthetic popup").padding(24).frogPanel())
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 320, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil); window.contentView = nil }
        window.contentView = host; host.layoutSubtreeIfNeeded()
        let effect = try XCTUnwrap(descendants(host).compactMap { $0 as? NSVisualEffectView }.first)
        XCTAssertEqual(effect.blendingMode, .behindWindow)
        XCTAssertEqual(effect.material, .popover)
        XCTAssertEqual(effect.state, .active)
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        XCTAssertEqual(host.layer?.cornerRadius, 12, "The native host must clip system-added background siblings to the popup outline")
        XCTAssertEqual(host.layer?.masksToBounds, true)
        let mask = try XCTUnwrap(effect.maskImage)
        XCTAssertEqual(mask.size, effect.bounds.size, "The native blur mask must track the rendered popup size")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(mask.tiffRepresentation)))
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0, accuracy: 0.01)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)).alphaComponent, 0.99)
        if let path = ProcessInfo.processInfo.environment["FROG_APPEARANCE_EVIDENCE"] {
            try await captureSyntheticPreviews(in: URL(fileURLWithPath: path))
        }
    }
    func testSemanticPaletteOverridesResolveInBothModesAndPresetsRestore() throws {
        _ = NSApplication.shared
        let original = FrogAppearance.shared.settings
        defer { FrogAppearance.shared.apply(original) }
        var settings = AppearancePreferences(); settings.theme = .nord
        settings.lightPalette = ["background": "112233", "surface": "223344", "text": "334455", "accent": "445566"]
        settings.darkPalette = ["background": "556677", "surface": "667788", "text": "778899", "accent": "8899AA", "on-accent": "001122"]
        FrogAppearance.shared.apply(settings)
        func hex(_ color: Color, _ appearance: NSAppearance.Name) throws -> String {
            var resolved: NSColor?
            try XCTUnwrap(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance { resolved = NSColor(color).usingColorSpace(.sRGB) }
            let rgb = try XCTUnwrap(resolved)
            return String(format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
        }
        XCTAssertEqual(try hex(FrogStyle.opaqueCanvas, .aqua), "112233")
        XCTAssertEqual(try hex(FrogStyle.opaqueCanvas, .darkAqua), "556677")
        XCTAssertEqual(try hex(FrogStyle.panelSurface, .aqua), "223344")
        XCTAssertEqual(try hex(FrogStyle.panelSurface, .darkAqua), "667788")
        XCTAssertEqual(try hex(FrogStyle.ink, .aqua), "334455")
        XCTAssertEqual(try hex(FrogStyle.ink, .darkAqua), "778899")
        XCTAssertEqual(try hex(FrogStyle.accent, .aqua), "445566")
        XCTAssertEqual(try hex(FrogStyle.accent, .darkAqua), "8899AA")
        XCTAssertEqual(try hex(FrogStyle.onAccent, .darkAqua), "001122")
        settings.lightPalette = nil; settings.darkPalette = nil; FrogAppearance.shared.apply(settings)
        XCTAssertEqual(try hex(FrogStyle.opaqueCanvas, .darkAqua), "2E3440")
        XCTAssertEqual(try hex(FrogStyle.accent, .aqua), "466A83")
    }
    func testScrollbarAppearanceDoesNotChangeAfterTheFirstFrame() async throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: ScrollView {
            VStack { ForEach(0..<100, id: \.self) { Text("Row \($0)").frame(height: 30) } }.minimalScrollbars()
        })
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        window.orderFront(nil); host.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
        let firstWidth = scroll.contentSize.width
        let firstInsets = scroll.scrollerInsets
        XCTAssertEqual(scroll.scrollerStyle, .overlay)
        XCTAssertTrue(scroll.autohidesScrollers)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(scroll.scrollerStyle, .overlay)
        XCTAssertEqual(scroll.contentSize.width, firstWidth)
        XCTAssertEqual(scroll.scrollerInsets.top, firstInsets.top)
        XCTAssertEqual(scroll.scrollerInsets.right, firstInsets.right)
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    /// Opt-in visual evidence captures only our window over a larger synthetic checkerboard.
    /// No desktop capture, wallpaper read, permission request or user setting mutation.
    private func captureSyntheticPreviews(in directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let frame = NSRect(x: 300, y: 250, width: 540, height: 300)
        let backdrop = NSWindow(contentRect: frame.insetBy(dx: -160, dy: -160), styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.level = .floating; backdrop.ignoresMouseEvents = true
        backdrop.contentView = NSHostingView(rootView: HStack(spacing: 0) {
            ForEach(0..<20, id: \.self) { index in
                Rectangle().fill(index.isMultiple(of: 2) ? Color(red: 0.20, green: 0.58, blue: 0.42) : Color(red: 0.68, green: 0.46, blue: 0.22))
            }
        })
        let preview = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        preview.level = .floating; preview.ignoresMouseEvents = true
        defer { preview.orderOut(nil); preview.contentView = nil; backdrop.orderOut(nil); backdrop.contentView = nil }
        backdrop.orderFrontRegardless()
        for mode in [AppearancePreferences.Mode.light, .dark] {
            for amount in [0.0, 0.5, 1.0] {
                for popup in [false, true] {
                    var settings = AppearancePreferences(); settings.mode = mode; settings.theme = .frog
                    settings.transparency = amount; settings.popupTransparency = amount
                    FrogAppearance.shared.apply(settings)
                    preview.appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
                    let content = VStack(alignment: .leading, spacing: 16) {
                        Text("Frog · synthetic \(popup ? "popup" : "window")").font(.system(size: 18, weight: .semibold))
                        Text("Backdrop blur \(Int(amount * 100))% · \(mode.rawValue)").foregroundStyle(FrogStyle.muted)
                        FrogCard {
                            HStack { Text("Readable theme surface"); Spacer(); FrogBadge(text: "Active", active: true) }
                            Text("Only generated fixture content is shown.").font(.system(size: 12)).foregroundStyle(FrogStyle.muted)
                        }
                        HStack {
                            Text("Synthetic text field").foregroundStyle(FrogStyle.muted).padding(10).background(FrogStyle.inset, in: RoundedRectangle(cornerRadius: 6))
                            Spacer()
                            Button("Action") {}.buttonStyle(FrogButtonStyle(primary: true))
                        }
                    }.padding(24).frame(width: 540, height: 300).foregroundStyle(FrogStyle.ink)
                    let root = popup ? AnyView(content.frogPanel()) : AnyView(content.background(FrogStyle.canvas).background(FrogWindowMaterial()))
                    let host = NSHostingView(rootView: root)
                    preview.contentView = host; preview.orderFrontRegardless(); host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(140))
                    let screenHeight = try XCTUnwrap(NSScreen.screens.first).frame.height
                    let rectangle = CGRect(x: frame.minX, y: screenHeight - frame.maxY, width: frame.width, height: frame.height)
                    // Core Graphics expects raw window IDs in this CFArray, not CFNumber objects.
                    var ids = [UnsafeRawPointer(bitPattern: preview.windowNumber), UnsafeRawPointer(bitPattern: backdrop.windowNumber)]
                    let windows = try XCTUnwrap(ids.withUnsafeMutableBufferPointer { CFArrayCreate(nil, $0.baseAddress, $0.count, nil) })
                    let image = try XCTUnwrap(CGImage(windowListFromArrayScreenBounds: rectangle, windowArray: windows, imageOption: .boundsIgnoreFraming))
                    let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                    try png.write(to: directory.appendingPathComponent("frog-\(popup ? "popup" : "window")-\(mode.rawValue)-\(Int(amount * 100)).png"))
                }
            }
        }
    }
}
