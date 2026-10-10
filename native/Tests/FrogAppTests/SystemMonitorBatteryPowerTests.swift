import Foundation
import XCTest
@testable import FrogApp

final class SystemMonitorBatteryPowerTests: XCTestCase {
    private func properties(current: Any = -1_500, external: Bool = false, charging: Bool = false) -> [String: Any] {
        ["BatteryInstalled": true, "ExternalConnected": external, "IsCharging": charging,
         "Voltage": 12_000, "InstantAmperage": current]
    }

    func testMillivoltsAndSignedMilliampsDescribeBatteryDirectionNotSystemOrAdapterPower() {
        XCTAssertEqual(SystemMonitorBatteryPower.reading(properties: properties()), .drawing(watts: 18))
        XCTAssertEqual(SystemMonitorBatteryPower.reading(properties: properties(current: 2_000, external: true, charging: true)), .charging(watts: 24))
        // Plugged-in Macs may draw supplemental energy from the battery.
        XCTAssertEqual(SystemMonitorBatteryPower.reading(properties: properties(external: true)), .drawing(watts: 18))
        XCTAssertEqual(SystemMonitorBatteryFlow.drawing(watts: 18).title, "Battery draw")
        XCTAssertEqual(SystemMonitorBatteryFlow.charging(watts: 24).title, "Battery charging")
    }

    func testSignedAndUnsigned32And64BitRegistryEncodingsAgree() {
        let encodings: [NSNumber] = [
            NSNumber(value: Int32(-1_500)), NSNumber(value: Int64(-1_500)),
            NSNumber(value: UInt32(bitPattern: -1_500)),
            NSNumber(value: UInt64(bitPattern: -1_500))
        ]
        for value in encodings {
            XCTAssertEqual(SystemMonitorBatteryPower.reading(properties: properties(current: value)), .drawing(watts: 18))
        }
        // Unsigned 16-bit raw bus values aren't the published signed registry contract.
        XCTAssertNil(SystemMonitorBatteryPower.reading(properties: properties(current: UInt16(bitPattern: -1_500))))
    }

    func testInstantCurrentTakesPrecedenceAndAverageIsOnlyFallbackWhenAbsent() {
        var values = properties()
        values["Amperage"] = -500
        XCTAssertEqual(SystemMonitorBatteryPower.reading(properties: values), .drawing(watts: 18))
        values.removeValue(forKey: "InstantAmperage")
        XCTAssertEqual(SystemMonitorBatteryPower.reading(properties: values), .drawing(watts: 6))
        for invalid: Any in [0, "-1500", NSNull(), 80_000] {
            values["InstantAmperage"] = invalid
            XCTAssertNil(SystemMonitorBatteryPower.reading(properties: values), "Don't replace an invalid current reading with a stale average")
        }
        values.removeValue(forKey: "InstantAmperage")
        values.removeValue(forKey: "Amperage")
        XCTAssertNil(SystemMonitorBatteryPower.reading(properties: values))
    }

    func testMissingBatteryMissingFlagsAndInconsistentChargeStateAreUnavailable() {
        for key in ["BatteryInstalled", "ExternalConnected", "IsCharging", "Voltage"] {
            var values = properties()
            values.removeValue(forKey: key)
            XCTAssertNil(SystemMonitorBatteryPower.reading(properties: values), key)
        }
        var desktop = properties()
        desktop["BatteryInstalled"] = false
        XCTAssertNil(SystemMonitorBatteryPower.reading(properties: desktop))
        XCTAssertNil(SystemMonitorBatteryPower.reading(properties: properties(current: 1_000)))
        XCTAssertNil(SystemMonitorBatteryPower.reading(properties: properties(current: 1_000, external: true)))
        XCTAssertNil(SystemMonitorBatteryPower.reading(properties: properties(current: 1_000, charging: true)))
        XCTAssertNil(SystemMonitorBatteryPower.reading(properties: properties(external: true, charging: true)))
    }

    func testZeroMalformedAndImplausibleMeasurementsNeverBecomeWatts() {
        for voltage: Any in [0, -12_000, 100, 65_535, UInt64.max, true, "12000", Double.nan] {
            var values = properties()
            values["Voltage"] = voltage
            XCTAssertNil(SystemMonitorBatteryPower.reading(properties: values), "Invalid voltage: \(voltage)")
        }
        for current: Any in [0, -20_001, 20_001, Int64.min, UInt64(1) << 40, false, "-1500", Double.infinity, -1_500.5] {
            XCTAssertNil(SystemMonitorBatteryPower.reading(properties: properties(current: current)), "Invalid current: \(current)")
        }
        var excessive = properties(current: -20_000)
        excessive["Voltage"] = 25_000
        XCTAssertNil(SystemMonitorBatteryPower.reading(properties: excessive), "500 W is outside conservative laptop battery bounds")
        XCTAssertEqual(SystemMonitorBatteryPower.reading(properties: properties(current: -1)), .drawing(watts: 0.012), "Small valid current must not be rounded to a fabricated zero reading")
    }
}
