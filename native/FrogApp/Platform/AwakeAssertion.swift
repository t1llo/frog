import Foundation
import IOKit.pwr_mgt

/// Keeps the display on, and with it the screen unlocked, while held. `pmset disablesleep` alone keeps the Mac
/// running but lets the display sleep, the screen saver start and the screen lock.
@MainActor protocol DisplayAwakeHolding: AnyObject {
    func hold(_ on: Bool)
}

/// The two idle assertions `caffeinate -d -i` takes. macOS releases them when Frog quits or crashes.
@MainActor final class AwakeAssertion: DisplayAwakeHolding {
    private var assertions: [IOPMAssertionID] = []

    func hold(_ on: Bool) {
        if on, assertions.isEmpty {
            let reason = "Frog's Stay awake is on" as CFString
            for type in [kIOPMAssertPreventUserIdleDisplaySleep, kIOPMAssertPreventUserIdleSystemSleep] {
                var id = IOPMAssertionID(0)
                if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id) == kIOReturnSuccess {
                    assertions.append(id)
                }
            }
            // Counts as activity now, so a display that was about to dim stays on.
            var activity = IOPMAssertionID(0)
            IOPMAssertionDeclareUserActivity(reason, kIOPMUserActiveLocal, &activity)
        } else if !on {
            for id in assertions { IOPMAssertionRelease(id) }
            assertions = []
        }
    }
}
