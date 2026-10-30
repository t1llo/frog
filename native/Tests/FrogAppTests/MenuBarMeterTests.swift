import AppKit
import XCTest
import FrogCore
@testable import FrogApp
@testable import FrogUsage

/// Menu-bar meters are drawn on every reading; equal faces must not draw again, and the item
/// must keep its width while readings change.
final class MenuBarMeterTests: XCTestCase {
    func testReadingsTooCloseToSeeMakeTheSameFace() {
        XCTAssertEqual(MenuBarMeterRow(label: "CPU", fraction: 0.421), MenuBarMeterRow(label: "CPU", fraction: 0.424))
        XCTAssertNotEqual(MenuBarMeterRow(label: "CPU", fraction: 0.42), MenuBarMeterRow(label: "CPU", fraction: 0.43))
        XCTAssertEqual(MenuBarMeterRow(label: "GPU", fraction: 1.7).fraction, 1)
        XCTAssertNil(MenuBarMeterRow(label: "GPU", fraction: .nan).fraction)
        XCTAssertEqual(MenuBarMeterRow(label: "GPU", fraction: nil).value, "—")
        XCTAssertEqual(MenuBarMeterRow(label: "GPU", fraction: 0.078).value, "8%")
    }

    func testOnlyACleanMeterIsATemplate() {
        let rows = [MenuBarMeterRow(label: "5h", fraction: 0.3)]
        for style in MenuBarMeterStyle.allCases {
            XCTAssertTrue(MenuBarMeter.image(.init(rows: rows, style: style, palette: .clean)).isTemplate, style.rawValue)
            XCTAssertFalse(MenuBarMeter.image(.init(rows: rows, style: style, palette: .spectrum, dark: true)).isTemplate, style.rawValue)
        }
    }

    func testTheItemKeepsItsWidthAsReadingsChange() {
        for style in MenuBarMeterStyle.allCases {
            let widths = [0.0, 0.05, 0.5, 1].map { load in
                MenuBarMeter.image(.init(rows: [.init(label: "CPU", fraction: load), .init(label: "GPU", fraction: nil)],
                                         style: style, palette: .level)).size.width
            }
            XCTAssertEqual(Set(widths).count, 1, "\(style.rawValue): \(widths)")
            XCTAssertEqual(MenuBarMeter.image(.init(rows: [.init(label: "CPU", fraction: 0.2)], style: style, palette: .clean)).size.height, 22)
        }
    }

    func testAGPUWithoutALoadReadingLeavesCPUAlone() {
        let settings = SystemMonitorSettings()
        let both = SystemMonitorStatusItemController.face(.init(cpu: .value(0.3), gpu: .value(0.6)), settings: settings, dark: false)
        XCTAssertEqual(both.rows.map(\.label), ["CPU", "GPU"])
        XCTAssertEqual(both.style, .segments)
        XCTAssertEqual(both.palette, .spectrum)
        let cpu = SystemMonitorStatusItemController.face(.init(cpu: .value(0.3), gpu: .unavailable), settings: settings, dark: false)
        XCTAssertEqual(cpu.rows.map(\.label), ["CPU"])
        let measuring = SystemMonitorStatusItemController.face(nil, settings: settings, dark: true)
        XCTAssertEqual(measuring.rows.map(\.fraction), [nil, nil])
        var clean = settings; clean.menuBarPalette = .clean
        XCTAssertFalse(SystemMonitorStatusItemController.face(nil, settings: clean, dark: true).dark,
                       "A template does not depend on the menu bar's look")
    }

    func testTheChosenReadingsAreTheRowsOfTheItem() {
        var settings = SystemMonitorSettings()
        let reading = SystemMonitorReading(cpu: .value(0.3), gpu: .value(0.6), memory: .value(0.5))
        let rows = { (readings: SystemMonitorSettings.Readings) -> [String] in
            settings.menuBarReadings = readings
            return SystemMonitorStatusItemController.face(reading, settings: settings, dark: false).rows.map(\.label)
        }
        XCTAssertEqual(rows(.cpu), ["CPU"])
        XCTAssertEqual(rows(.cpuMemory), ["CPU", "MEM"])
        XCTAssertEqual(rows(.cpuGpuMemory), ["CPU", "GPU", "MEM"])
        XCTAssertEqual(SystemMonitorStatusItemController.description(reading), "System monitor\nCPU 30% · GPU 60% · Memory 50%")
    }

    func testUsageLimitsBecomeAMeterInEveryDesignButNumbers() throws {
        var face = UsageStatusReadout.Face(provider: "Claude", windows: [
            UsageWindow(id: "five_hour", title: "Session", percentage: 37, resetsAt: nil, duration: 5 * 3600),
            UsageWindow(id: "seven_day", title: "Week", percentage: .nan, resetsAt: nil, duration: 7 * 86_400)
        ])
        XCTAssertNil(face.meter, "Numbers keep today's readout")
        face.style = .segments
        let meter = try XCTUnwrap(face.meter)
        XCTAssertEqual(meter.rows.map(\.label), ["5h", "7d"])
        XCTAssertEqual(meter.rows.map(\.fraction), [0.37, nil], "A window without a reading stays empty")
        var estimate = UsageStatusReadout.Face(provider: "Claude", windows: [], estimate: .init(range: "7d", value: "$185"))
        estimate.style = .bars
        XCTAssertNil(estimate.meter, "Without a plan reading the item still shows the estimate as text")
    }

    func testStayAwakeIconCountsDown() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ring = StayAwakeIcon.Face(style: "ring", deadline: now.addingTimeInterval(3600), duration: 4 * 3600, now: now)
        XCTAssertEqual(ring.remaining, 0.26, accuracy: 0.001, "A quarter left, rounded up to the next 2%")
        XCTAssertNil(ring.text)
        XCTAssertEqual(StayAwakeIcon.Face(style: "ring", deadline: nil, duration: 0, now: now).remaining, 1, "Until Frog quits")
        let restored = StayAwakeIcon.Face(style: "ring", deadline: now.addingTimeInterval(3 * 3600), duration: 1800, now: now)
        XCTAssertEqual(restored.remaining, 1, "A restored session longer than today's duration starts full")
        XCTAssertEqual(StayAwakeIcon.Face(style: "time", deadline: now.addingTimeInterval(8400), duration: 14_400, now: now).text, "2h 20m")
        XCTAssertEqual(StayAwakeIcon.left(until: now.addingTimeInterval(61), now: now), "2m")
        XCTAssertNil(StayAwakeIcon.left(until: now.addingTimeInterval(-5), now: now))
        XCTAssertEqual(StayAwakeIcon.Face(style: "sparkles", deadline: nil, duration: 0, now: now).style, "ring")
        XCTAssertTrue(StayAwakeIcon.image(ring).isTemplate)
    }

    /// Opt-in visual evidence: FROG_MENU_BAR_EVIDENCE=<folder> writes a sheet of every design.
    func testDrawsASheetOfEveryDesignWhenAsked() throws {
        guard let path = ProcessInfo.processInfo.environment["FROG_MENU_BAR_EVIDENCE"] else { return }
        let usage = [MenuBarMeterRow(label: "5h", fraction: 0.37), MenuBarMeterRow(label: "7d", fraction: 0.81)]
        let accounts = [MenuBarMeterRow(label: "A", fraction: 0.12), MenuBarMeterRow(label: "B", fraction: 0.64),
                        MenuBarMeterRow(label: "C", fraction: 0.95, dimmed: true)]
        let system = [MenuBarMeterRow(label: "CPU", fraction: 0.42), MenuBarMeterRow(label: "GPU", fraction: 0.78)]
        var lines: [(String, (Bool) -> NSImage)] = []
        for palette in MenuBarMeterPalette.allCases {
            for style in MenuBarMeterStyle.allCases {
                lines.append(("\(style.rawValue) · \(palette.rawValue)", { dark in
                    let images = [usage, accounts, system].map { MenuBarMeter.image(.init(rows: $0, style: style, palette: palette, dark: dark)) }
                    return Self.row(images)
                }))
            }
            lines.append(("usage numbers · \(palette.rawValue)", { dark in
                var face = UsageStatusReadout.Face(provider: "Claude", windows: [
                    UsageWindow(id: "five_hour", title: "Session", percentage: 37, resetsAt: nil, duration: 5 * 3600),
                    UsageWindow(id: "seven_day", title: "Week", percentage: 81, resetsAt: nil, duration: 7 * 86_400)])
                face.palette = palette; face.dark = dark
                return UsageStatusReadout.image(face)
            }))
        }
        let now = Date()
        lines.append(("stay awake", { _ in
            Self.row(["icon", "ring", "time"].map { StayAwakeIcon.image(.init(style: $0, deadline: now.addingTimeInterval(8430), duration: 14_400, now: now)) }
                     + [StayAwakeIcon.image(.init(style: "ring", deadline: now.addingTimeInterval(900), duration: 14_400, now: now))])
        }))
        let scale: CGFloat = 3, lineHeight: CGFloat = 30, labelWidth: CGFloat = 170, column: CGFloat = 260
        let size = NSSize(width: labelWidth + column * 2, height: lineHeight * CGFloat(lines.count))
        let sheet = NSImage(size: NSSize(width: size.width * scale, height: size.height * scale), flipped: true) { _ in
            NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
            for (index, line) in lines.enumerated() {
                let y = CGFloat(index) * lineHeight
                NSColor.white.setFill(); NSRect(x: 0, y: y, width: labelWidth, height: lineHeight).fill()
                (line.0 as NSString).draw(at: NSPoint(x: 6, y: y + 8), withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
                for (offset, dark) in [false, true].enumerated() {
                    let x = labelWidth + CGFloat(offset) * column
                    (dark ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
                    NSRect(x: x, y: y, width: column, height: lineHeight).fill()
                    let image = line.1(dark)
                    Self.tinted(image, dark ? .white : .black).draw(in: NSRect(x: x + 10, y: y + 4, width: image.size.width, height: image.size.height))
                }
            }
            return true
        }
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(sheet.tiffRepresentation)))
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("menu-bar-designs.png"))
    }

    private static func row(_ images: [NSImage]) -> NSImage {
        let width = images.reduce(0) { $0 + $1.size.width + 14 }
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            var x: CGFloat = 0
            for item in images { tinted(item, .black).draw(at: NSPoint(x: x, y: 0), from: .zero, operation: .sourceOver, fraction: 1); x += item.size.width + 14 }
            return true
        }
        image.isTemplate = images.allSatisfy(\.isTemplate)
        return image
    }

    /// A template drawn as the menu bar would: its shape in `color`. Anything else as it is.
    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        guard image.isTemplate else { return image }
        return NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
