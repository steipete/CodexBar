import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
@Suite
struct ClaudeOAuthIdentityEnrichmentTests {
    private func makeUsage(
        accountEmail: String? = nil,
        loginMethod: String? = "Claude Max") -> ClaudeUsageSnapshot
    {
        ClaudeUsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 25, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            opus: nil,
            providerCost: nil,
            updatedAt: Date(),
            accountEmail: accountEmail,
            accountOrganization: nil,
            loginMethod: loginMethod,
            rawText: nil)
    }

    @Test
    func `enriches email when OAuth returns nil`() async {
        let usage = self.makeUsage(accountEmail: nil)
        let identity = ClaudeAccountIdentity(
            accountEmail: "user@example.com",
            accountOrganization: "My Org",
            loginMethod: "Claude Pro")

        let enriched = await ClaudeOAuthFetchStrategy.$identityProbeOverride
            .withValue(.some(identity)) {
                await ClaudeOAuthFetchStrategy.enrichIdentityIfNeeded(
                    usage: usage,
                    environment: [:])
            }

        #expect(enriched.accountEmail == "user@example.com")
        #expect(enriched.accountOrganization == "My Org")
        // OAuth loginMethod takes precedence over probe loginMethod
        #expect(enriched.loginMethod == "Claude Max")
        // Usage fields are preserved
        #expect(enriched.primary.usedPercent == 10)
        #expect(enriched.secondary?.usedPercent == 25)
    }

    @Test
    func `preserves existing email when OAuth provides one`() async {
        let usage = self.makeUsage(accountEmail: "already@set.com")
        let identity = ClaudeAccountIdentity(
            accountEmail: "other@example.com",
            accountOrganization: "Other Org",
            loginMethod: "Claude Pro")

        let enriched = await ClaudeOAuthFetchStrategy.$identityProbeOverride
            .withValue(.some(identity)) {
                await ClaudeOAuthFetchStrategy.enrichIdentityIfNeeded(
                    usage: usage,
                    environment: [:])
            }

        #expect(enriched.accountEmail == "already@set.com")
    }

    @Test
    func `returns unchanged snapshot when probe fails`() async {
        let usage = self.makeUsage(accountEmail: nil)

        let enriched = await ClaudeOAuthFetchStrategy.$identityProbeOverride
            .withValue(.some(nil)) {
                await ClaudeOAuthFetchStrategy.enrichIdentityIfNeeded(
                    usage: usage,
                    environment: [:])
            }

        #expect(enriched.accountEmail == nil)
        #expect(enriched.primary.usedPercent == 10)
    }

    @Test
    func `uses probe loginMethod when OAuth has none`() async {
        let usage = self.makeUsage(accountEmail: nil, loginMethod: nil)
        let identity = ClaudeAccountIdentity(
            accountEmail: "user@example.com",
            accountOrganization: nil,
            loginMethod: "Claude Pro")

        let enriched = await ClaudeOAuthFetchStrategy.$identityProbeOverride
            .withValue(.some(identity)) {
                await ClaudeOAuthFetchStrategy.enrichIdentityIfNeeded(
                    usage: usage,
                    environment: [:])
            }

        #expect(enriched.accountEmail == "user@example.com")
        #expect(enriched.loginMethod == "Claude Pro")
    }

    @Test
    func `skips probe when OAuth token came from env var`() async {
        let usage = self.makeUsage(accountEmail: nil)
        let identity = ClaudeAccountIdentity(
            accountEmail: "cli@example.com",
            accountOrganization: nil,
            loginMethod: nil)

        let env = [ClaudeOAuthCredentialsStore.environmentTokenKey: "sk-ant-oat-env-token"]
        let enriched = await ClaudeOAuthFetchStrategy.$identityProbeOverride
            .withValue(.some(identity)) {
                await ClaudeOAuthFetchStrategy.enrichIdentityIfNeeded(
                    usage: usage,
                    environment: env)
            }

        // Should NOT merge CLI identity when token is env-backed
        #expect(enriched.accountEmail == nil)
    }
}
#endif
