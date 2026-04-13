#if os(macOS)
import IOKit.pwr_mgt

final class SleepManager {
    private var assertionID: IOPMAssertionID = 0
    private var active = false

    func preventIdleSleep() {
        guard !active else { return }
        let reason = "TermOnMac agent active" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )
        if result == kIOReturnSuccess {
            active = true
            log("[sleep] idle sleep prevention enabled")
        } else {
            log("[sleep] failed to create IOPMAssertion: \(result)")
        }
    }

    func allowSleep() {
        guard active else { return }
        IOPMAssertionRelease(assertionID)
        active = false
        log("[sleep] idle sleep prevention released")
    }

    deinit {
        allowSleep()
    }
}
#endif
