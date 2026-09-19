import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeVerifiedAccountOwnerTests {
    @Test
    func `verified owner uses principal and organization without display or credential fields`() throws {
        let owner = try #require(ClaudeVerifiedAccountOwner.ownerID(
            accountUUID: "principal-a", email: "old@example.com", organizationUUID: "org-a"))
        #expect(owner == ClaudeVerifiedAccountOwner.ownerID(
            accountUUID: "principal-a", email: "renamed@example.com", organizationUUID: "org-a"))
        #expect(owner != ClaudeVerifiedAccountOwner.ownerID(
            accountUUID: "principal-b", email: "old@example.com", organizationUUID: "org-a"))
        #expect(owner != ClaudeVerifiedAccountOwner.ownerID(
            accountUUID: "principal-a", email: "old@example.com", organizationUUID: "org-b"))
        #expect(!owner.contains("principal-a"))
        #expect(!owner.contains("example.com"))
        #expect(ClaudeVerifiedAccountOwner.ownerID(accountUUID: nil, email: nil, organizationUUID: "org-a") == nil)
        #expect(ClaudeVerifiedAccountOwner
            .ownerID(accountUUID: "principal-a", email: nil, organizationUUID: nil) == nil)
        #expect(ClaudeVerifiedAccountOwner.ownerID(
            accountUUID: nil,
            email: " User@Example.com ",
            organizationUUID: "org-a")
            == ClaudeVerifiedAccountOwner.ownerID(
                accountUUID: nil,
                email: "user@example.com",
                organizationUUID: "org-a"))
    }

    @Test
    func `profile is fetched only when requested and with the winning usage token`() async throws {
        let skipped = IdentityCalls()
        let plain = try await self.fetch(includeIdentity: false, calls: skipped)
        #expect(plain.accountID == nil)
        #expect(await skipped.values == ["usage:fixture-access-token"])

        let requested = IdentityCalls()
        let identified = try await self.fetch(includeIdentity: true, calls: requested)
        #expect(await requested.values == ["usage:fixture-access-token", "profile:fixture-access-token"])
        #expect(identified.primary.usedPercent == 25)
        #expect(identified.accountID == ClaudeVerifiedAccountOwner.ownerID(
            accountUUID: "principal-a", email: "owner@example.com", organizationUUID: "org-a"))
        #expect(identified.accountEmail == plain.accountEmail)
        let mapped = ClaudeOAuthFetchStrategy._snapshotForTesting(from: identified)
            .withAccountLabel("Work", for: .claude)
        #expect(mapped.identity?.accountEmail == "Work")
        #expect(mapped.identity?.accountID == nil)
        #expect(mapped.identity?.widgetAccountOwnerID == identified.accountID)
        #expect(identified.replacingWebExtras(extraRateWindows: [], providerCost: nil).accountID == identified
            .accountID)
    }

    @Test
    func `profile failure leaves successful quota available without verified ownership`() async throws {
        let calls = IdentityCalls()
        let snapshot = try await self.fetch(includeIdentity: true, calls: calls, profileFails: true)
        #expect(snapshot.primary.usedPercent == 25)
        #expect(snapshot.accountID == nil)
        #expect(snapshot.accountEmail == nil)
        #expect(await calls.values == ["usage:fixture-access-token", "profile:fixture-access-token"])
    }

    @Test
    func `profile cancellation remains terminal`() async throws {
        await #expect(throws: CancellationError.self) {
            try await self.fetch(includeIdentity: true, calls: IdentityCalls(), cancelProfile: true)
        }
    }

    private func fetch(
        includeIdentity: Bool,
        calls: IdentityCalls,
        profileFails: Bool = false,
        cancelProfile: Bool = false) async throws -> ClaudeUsageSnapshot
    {
        let credentials = ClaudeOAuthCredentials(
            accessToken: "fixture-access-token", refreshToken: nil,
            expiresAt: Date().addingTimeInterval(3600), scopes: ["user:profile"], rateLimitTier: "claude_pro")
        let usage = try JSONDecoder().decode(
            OAuthUsageResponse.self, from: Data(#"{"five_hour":{"utilization":25}}"#.utf8))
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: ["PATH": "/usr/bin:/bin"], runtime: .cli, dataSource: .oauth,
            includeAccountIdentity: includeIdentity)
        return try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue({ _, _, _ in credentials }) {
            try await ClaudeUsageFetcher.$fetchOAuthUsageOverride.withValue({ token, _ in
                await calls.append("usage:\(token)")
                return usage
            }) {
                try await ClaudeUsageFetcher.$fetchOAuthProfileOverride.withValue({ token in
                    await calls.append("profile:\(token)")
                    if cancelProfile { throw CancellationError() }
                    if profileFails { throw IdentityFailure.unavailable }
                    return OAuthProfileResponse(
                        emailAddress: "owner@example.com", organizationUuid: "org-a", accountUuid: "principal-a")
                }) {
                    try await fetcher.loadLatestUsage(model: "sonnet")
                }
            }
        }
    }
}

private enum IdentityFailure: Error { case unavailable }

private actor IdentityCalls {
    var values: [String] = []
    func append(_ value: String) { self.values.append(value) }
}
