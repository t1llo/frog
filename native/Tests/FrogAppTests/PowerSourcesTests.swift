import IOKit
import IOKit.ps
import XCTest
@testable import FrogApp

/// Stay awake and the system monitor read the power sources in one place. Windowless, and
/// apart from one read of this Mac's own sources, from descriptions written here.
final class PowerSourcesTests: XCTestCase {
    private func internalBattery(_ current: Any, of maximum: Any = 100, charging: Bool = false) -> [String: Any] {
        [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: current, kIOPSMaxCapacityKey: maximum,
         kIOPSIsChargingKey: charging]
    }
    private func ups(_ current: Int) -> [String: Any] {
        [kIOPSTypeKey: kIOPSUPSType, kIOPSCurrentCapacityKey: current, kIOPSMaxCapacityKey: 100, kIOPSIsChargingKey: true]
    }

    func testTheChargeOfTheInternalBatteryIsTakenNotThatOfAUPS() throws {
        // The text of `pmset -g batt` gave the first percentage of any source.
        for descriptions in [[ups(80), internalBattery(15)], [internalBattery(15), ups(80)]] {
            let sources = PowerSources(providing: kIOPSBatteryPowerValue, descriptions: descriptions)
            XCTAssertEqual(sources, PowerSources(providing: kIOPSBatteryPowerValue, descriptions: [internalBattery(15)]))
            XCTAssertEqual(sources.batteryPercent, 15)
            XCTAssertFalse(sources.charging)
            XCTAssertEqual(try NativeStayAwakeSystem.battery(sources), PowerBattery(onBattery: true, percent: 15))
        }
        // A Mac without a battery of its own has no charge, whatever the UPS reports.
        let desktop = PowerSources(providing: kIOPMUPSPowerKey, descriptions: [ups(80)])
        XCTAssertEqual(desktop.source, .ups)
        XCTAssertNil(desktop.batteryPercent)
        XCTAssertEqual(try NativeStayAwakeSystem.battery(desktop), PowerBattery(onBattery: false, percent: nil))
    }

    func testSourceChargeAndChargingAreReadFromWhatMacOSReports() throws {
        let charging = PowerSources(providing: kIOPSACPowerValue, descriptions: [internalBattery(9, charging: true)])
        XCTAssertEqual(charging.source, .adapter)
        XCTAssertEqual(charging.batteryPercent, 9)
        XCTAssertTrue(charging.charging)
        XCTAssertEqual(try NativeStayAwakeSystem.battery(charging), PowerBattery(onBattery: false, percent: 9))

        let unplugged = PowerSources(providing: kIOPSBatteryPowerValue, descriptions: [internalBattery(19)])
        XCTAssertEqual(unplugged.source, .battery)
        XCTAssertEqual(try NativeStayAwakeSystem.battery(unplugged), PowerBattery(onBattery: true, percent: 19))

        // A capacity in other units than percent gives the same rounded share.
        XCTAssertEqual(PowerSources(providing: kIOPSBatteryPowerValue, descriptions: [internalBattery(2, of: 3)]).batteryPercent, 67)
        XCTAssertEqual(PowerSources(providing: kIOPSBatteryPowerValue, descriptions: [internalBattery(0)]).batteryPercent, 0)
        XCTAssertEqual(PowerSources(providing: kIOPSACPowerValue, descriptions: [internalBattery(100)]).batteryPercent, 100)

        let withoutBattery = PowerSources(providing: kIOPSACPowerValue, descriptions: [])
        XCTAssertNil(withoutBattery.batteryPercent)
        XCTAssertFalse(withoutBattery.charging)
        XCTAssertEqual(try NativeStayAwakeSystem.battery(withoutBattery), PowerBattery(onBattery: false, percent: nil))
    }

    func testAMacOnBatteryWithoutAReadableChargeIsUnreadable() {
        let unreadable: [[String: Any]] = [
            internalBattery(101), internalBattery(-1), internalBattery(50, of: 0), internalBattery("50"),
            [kIOPSTypeKey: kIOPSInternalBatteryType]
        ]
        for description in unreadable {
            let sources = PowerSources(providing: kIOPSBatteryPowerValue, descriptions: [description])
            XCTAssertNil(sources.batteryPercent)
            XCTAssertThrowsError(try NativeStayAwakeSystem.battery(sources)) {
                guard case StayAwakeError.unreadable = $0 else { return XCTFail("\($0)") }
            }
            // A charge only matters when the Mac runs on it.
            XCTAssertEqual(try NativeStayAwakeSystem.battery(PowerSources(providing: kIOPSACPowerValue, descriptions: [description])),
                           PowerBattery(onBattery: false, percent: nil))
        }
        XCTAssertThrowsError(try NativeStayAwakeSystem.battery(PowerSources(providing: kIOPSBatteryPowerValue, descriptions: [])))
        // Neither is a source macOS does not name, or no answer at all, taken for the adapter.
        for providing in [nil, "", "Solar Power"] {
            let sources = PowerSources(providing: providing, descriptions: [internalBattery(80)])
            XCTAssertNil(sources.source)
            XCTAssertEqual(sources.batteryPercent, 80)
            XCTAssertThrowsError(try NativeStayAwakeSystem.battery(sources))
        }
        XCTAssertThrowsError(try NativeStayAwakeSystem.battery(nil))
    }

    func testThisMacsPowerSourcesCanBeRead() async throws {
        let sources = try XCTUnwrap(PowerSources.read())
        XCTAssertNotNil(sources.source)
        if let percent = sources.batteryPercent { XCTAssertTrue((0...100).contains(percent)) }
        let battery = try await NativeStayAwakeSystem().battery()
        if let percent = battery.percent { XCTAssertTrue((0...100).contains(percent)) }
        if battery.onBattery { XCTAssertNotNil(battery.percent) }
    }
}
