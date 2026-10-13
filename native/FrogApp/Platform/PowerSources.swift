import Foundation
import IOKit
import IOKit.ps

/// What macOS reports about its power sources. Stay awake and the system monitor both read
/// it here, so the charge that stops a session is the charge the monitor shows.
struct PowerSources: Equatable, Sendable {
    enum Source: Sendable { case adapter, battery, ups }

    /// What the Mac draws from now.
    var source: Source?
    /// Of the internal battery only: a UPS has a charge of its own.
    var batteryPercent: Int?
    var charging = false

    /// A few system calls, no subprocess. Safe on any thread.
    static func read() -> PowerSources? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        return PowerSources(
            providing: IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?,
            descriptions: list.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] })
    }

    init(providing: String?, descriptions: [[String: Any]]) {
        switch providing {
        case kIOPSACPowerValue: source = .adapter
        case kIOPSBatteryPowerValue: source = .battery
        case kIOPMUPSPowerKey: source = .ups
        default: source = nil
        }
        for description in descriptions {
            guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  current >= 0, maximum > 0, current <= maximum else { continue }
            batteryPercent = Int((Double(current) / Double(maximum) * 100).rounded())
            charging = description[kIOPSIsChargingKey] as? Bool ?? false
            break
        }
    }
}
