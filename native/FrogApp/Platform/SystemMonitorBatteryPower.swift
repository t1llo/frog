import Foundation

enum SystemMonitorBatteryFlow: Equatable, Sendable {
    case charging(watts: Double)
    case drawing(watts: Double)

    var title: String {
        switch self {
        case .charging: "Battery charging"
        case .drawing: "Battery draw"
        }
    }

    var watts: Double {
        switch self {
        case .charging(let watts), .drawing(let watts): watts
        }
    }
}

/// IOPMPowerSource.h specifies Voltage in mV and signed Amperage in mA.
/// Apple's AppleSmartBattery.cpp publishes InstantAmperage as sign-extended
/// int32_t; IOKit/NSNumber may expose that two's-complement value as unsigned.
/// https://github.com/apple-oss-distributions/PowerManagement/blob/main/AppleSmartBatteryManager/AppleSmartBattery.cpp
enum SystemMonitorBatteryPower {
    static func reading(properties: [String: Any]) -> SystemMonitorBatteryFlow? {
        guard flag(properties["BatteryInstalled"]) == true,
              let external = flag(properties["ExternalConnected"]),
              let charging = flag(properties["IsCharging"]),
              let voltage = integer(properties["Voltage"]),
              (6_000...25_000).contains(voltage.int64Value) else { return nil }

        // Prefer the instantaneous current. An explicitly zero/invalid instant
        // reading must not fall back to a stale nonzero averaged current.
        let rawCurrent = properties["InstantAmperage"] ?? properties["Amperage"]
        guard let current = signedMilliamps(rawCurrent), current != 0 else { return nil }
        let watts = Double(voltage.int64Value) * Double(abs(current)) / 1_000_000
        // Conservative laptop-battery plausibility bounds; unsupported hardware
        // stays unavailable instead of turning malformed counters into watts.
        guard watts > 0, watts <= 300 else { return nil }
        if current > 0 {
            guard charging, external else { return nil }
            return .charging(watts: watts)
        }
        guard !charging else { return nil }
        // A battery can supplement an undersized adapter. Negative current is
        // still battery draw with external power present, never adapter draw.
        return .drawing(watts: watts)
    }

    private static func signedMilliamps(_ value: Any?) -> Int64? {
        guard let number = integer(value) else { return nil }
        var signed = number.int64Value
        if signed > Int64(Int32.max), signed <= Int64(UInt32.max) {
            signed = Int64(Int32(bitPattern: UInt32(signed)))
        }
        // int64Value also decodes an unsigned, sign-extended 64-bit registry
        // number. No 16-bit reinterpretation: the published contract is 32-bit.
        guard (-20_000...20_000).contains(signed) else { return nil }
        return signed
    }

    private static func integer(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType)) else { return nil }
        return number
    }

    private static func flag(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
