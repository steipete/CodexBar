import Foundation
import IOKit.pwr_mgt

struct AgentSessionPowerAssertion: Sendable {
    var acquire: @Sendable () -> UInt32?
    var release: @Sendable (UInt32) -> Void

    static let live = Self(acquire: {
        var assertion: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "CodexBar: local agent session is live" as CFString,
            &assertion)
        return result == kIOReturnSuccess ? assertion : nil
    }, release: { _ = IOPMAssertionRelease($0) })
}
