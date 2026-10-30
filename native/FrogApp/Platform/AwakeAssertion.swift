import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac awake while held, and with `screen` its display on and the screen unlocked. These are the
/// assertions `caffeinate -i` and `caffeinate -d -i` take: they need no setup, and macOS releases them when
/// Frog quits or crashes.
@MainActor protocol DisplayAwakeHolding: AnyObject {
    func hold(_ on: Bool, screen: Bool)
}

@MainActor final class AwakeAssertion: DisplayAwakeHolding {
    private var assertions: [IOPMAssertionID] = []
    private var screen = false

    func hold(_ on: Bool, screen: Bool) {
        if on, !assertions.isEmpty, screen == self.screen { return }
        release()
        guard on else { return }
        self.screen = screen
        let reason = "Frog's Stay awake is on" as CFString
        let types = screen ? [kIOPMAssertPreventUserIdleDisplaySleep, kIOPMAssertPreventUserIdleSystemSleep] : [kIOPMAssertPreventUserIdleSystemSleep]
        for type in types {
            var id = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id) == kIOReturnSuccess {
                assertions.append(id)
            }
        }
        if screen {
            // Counts as activity now, so a display that was about to dim stays on.
            var activity = IOPMAssertionID(0)
            IOPMAssertionDeclareUserActivity(reason, kIOPMUserActiveLocal, &activity)
        }
    }

    private func release() {
        for id in assertions { IOPMAssertionRelease(id) }
        assertions = []
    }

    isolated deinit { release() }
}
