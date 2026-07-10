import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
@Suite(.serialized)
struct ClaudeOAuthKeychainPreAlertGateTests {
    @Test
    func `acknowledgement suppresses repeated presentation until cooldown expires`() {
        let store = ClaudeOAuthKeychainPreAlertGate.StateStore()
        ClaudeOAuthKeychainPreAlertGate.withStateStoreOverrideForTesting(store) {
            let now = Date(timeIntervalSince1970: 1000)
            #expect(ClaudeOAuthKeychainPreAlertGate.beginPresentation(now: now))
            ClaudeOAuthKeychainPreAlertGate.finishPresentation(wasPresented: true, now: now)

            #expect(
                ClaudeOAuthKeychainPreAlertGate.beginPresentation(
                    now: now.addingTimeInterval(ClaudeOAuthKeychainPreAlertGate.cooldownInterval - 1)) == false)
            #expect(
                ClaudeOAuthKeychainPreAlertGate.beginPresentation(
                    now: now.addingTimeInterval(ClaudeOAuthKeychainPreAlertGate.cooldownInterval + 1)))
        }
    }

    @Test
    func `missing prompt handler does not consume acknowledgement cooldown`() {
        let store = ClaudeOAuthKeychainPreAlertGate.StateStore()
        ClaudeOAuthKeychainPreAlertGate.withStateStoreOverrideForTesting(store) {
            let now = Date(timeIntervalSince1970: 2000)
            #expect(ClaudeOAuthKeychainPreAlertGate.beginPresentation(now: now))
            ClaudeOAuthKeychainPreAlertGate.finishPresentation(wasPresented: false, now: now)
            #expect(ClaudeOAuthKeychainPreAlertGate.beginPresentation(now: now))
        }
    }

    @Test
    func `duplicate while presentation is in flight is suppressed`() {
        let store = ClaudeOAuthKeychainPreAlertGate.StateStore()
        ClaudeOAuthKeychainPreAlertGate.withStateStoreOverrideForTesting(store) {
            let now = Date(timeIntervalSince1970: 3000)
            #expect(ClaudeOAuthKeychainPreAlertGate.beginPresentation(now: now))
            #expect(ClaudeOAuthKeychainPreAlertGate.beginPresentation(now: now) == false)
            ClaudeOAuthKeychainPreAlertGate.finishPresentation(wasPresented: true, now: now)
        }
    }

    @Test
    func `acknowledgement persists across in memory reset`() {
        ClaudeOAuthKeychainPreAlertGate.resetForTesting()
        defer { ClaudeOAuthKeychainPreAlertGate.resetForTesting() }

        let now = Date(timeIntervalSince1970: 4000)
        #expect(ClaudeOAuthKeychainPreAlertGate.beginPresentation(now: now))
        ClaudeOAuthKeychainPreAlertGate.finishPresentation(wasPresented: true, now: now)
        ClaudeOAuthKeychainPreAlertGate.resetInMemoryForTesting()

        #expect(
            ClaudeOAuthKeychainPreAlertGate.beginPresentation(
                now: now.addingTimeInterval(ClaudeOAuthKeychainPreAlertGate.cooldownInterval - 1)) == false)
    }
}
#endif
