import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
import SweetCookieKit

/// Covers the background (non-user-initiated) branch of `BrowserCookieAccessGate.shouldAttempt`.
/// Before the preflight was consulted, any scheduled refresh returned early, so an already-authorized
/// Safe Storage entry could only refresh when the menu was opened. These tests drive the gate through
/// the strictly no-UI preflight override, never touching the real Keychain.
///
/// Serialized because the gate persists denial cooldowns in process-global state that
/// `resetForTesting()` clears — parallel cases would clobber each other's setup.
@Suite(.serialized)
struct BrowserCookieAccessGateTests {
    /// Evaluate `shouldAttempt` with the Keychain enabled, a stubbed no-UI preflight outcome, and an
    /// explicit interaction context — the exact three seams the production gate reads.
    private func evaluate(
        _ browser: Browser,
        preflight: KeychainAccessPreflight.Outcome,
        interaction: ProviderInteraction,
        now: Date = Date()) -> Bool
    {
        var result = false
        KeychainAccessGate.withTaskOverrideForTesting(false) {
            ProviderInteractionContext.$current.withValue(interaction) {
                KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in preflight } operation: {
                    result = BrowserCookieAccessGate.shouldAttempt(browser, now: now)
                }
            }
        }
        return result
    }

    @Test
    func `background refresh proceeds when the no-UI preflight already grants access`() {
        BrowserCookieAccessGate.resetForTesting()
        defer { BrowserCookieAccessGate.resetForTesting() }

        #expect(self.evaluate(.chrome, preflight: .allowed, interaction: .background))
    }

    @Test
    func `background refresh is skipped when the preflight requires interaction`() {
        BrowserCookieAccessGate.resetForTesting()
        defer { BrowserCookieAccessGate.resetForTesting() }

        // An interaction-required ACL would surface a Keychain prompt, so a scheduled refresh must not
        // attempt the read — preserving the no-surprise boundary.
        #expect(self.evaluate(.chrome, preflight: .interactionRequired, interaction: .background) == false)
    }

    @Test
    func `background refresh is skipped when the preflight cannot confirm access`() {
        BrowserCookieAccessGate.resetForTesting()
        defer { BrowserCookieAccessGate.resetForTesting() }

        // Only an explicit `.allowed` enables a background read. A missing item (or a query failure)
        // is never optimistically treated as a grant the way the user-initiated path allows.
        #expect(self.evaluate(.chrome, preflight: .notFound, interaction: .background) == false)
        #expect(self.evaluate(.chrome, preflight: .failure(-25293), interaction: .background) == false)
    }

    @Test
    func `an active denial cooldown suppresses background refresh even when the ACL is allowed`() {
        BrowserCookieAccessGate.resetForTesting()
        defer { BrowserCookieAccessGate.resetForTesting() }

        let start = Date(timeIntervalSince1970: 2000)
        BrowserCookieAccessGate.recordDenied(for: .chrome, now: start)

        // Within the six-hour cooldown the background gate stays suppressed regardless of a now-allowed
        // preflight, matching the suppression the user-initiated path honors.
        #expect(self.evaluate(
            .chrome,
            preflight: .allowed,
            interaction: .background,
            now: start.addingTimeInterval(60)) == false)

        // Once the six-hour cooldown lapses, an allowed preflight lets the background refresh proceed
        // again.
        let sixHours: TimeInterval = 6 * 60 * 60
        #expect(self.evaluate(
            .chrome,
            preflight: .allowed,
            interaction: .background,
            now: start.addingTimeInterval(sixHours + 60)))
    }

    @Test
    func `user initiated refresh is unchanged and still proceeds on an allowed preflight`() {
        BrowserCookieAccessGate.resetForTesting()
        defer { BrowserCookieAccessGate.resetForTesting() }

        #expect(self.evaluate(.chrome, preflight: .allowed, interaction: .userInitiated))
    }

    @Test
    func `browsers that do not use the Keychain are unaffected by the background gate`() {
        BrowserCookieAccessGate.resetForTesting()
        defer { BrowserCookieAccessGate.resetForTesting() }

        // Safari does not decrypt cookies via the Keychain, so the gate short-circuits to true before
        // any preflight or interaction check — in the background just as in a user-initiated refresh.
        #expect(self.evaluate(.safari, preflight: .interactionRequired, interaction: .background))
    }
}
#endif
