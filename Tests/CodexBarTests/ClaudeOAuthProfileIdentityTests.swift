import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeOAuthProfileIdentityTests {
    @Test
    func `requested OAuth profile keeps its email in the published identity`() async throws {
        let snapshot = try await self.fetch { token in
            #expect(token == "fixture-oauth-token")
            return OAuthProfileResponse(emailAddress: "oauth@example.com", organizationUuid: "fixture-org")
        }
        let published = ClaudeOAuthFetchStrategy._snapshotForTesting(from: snapshot)
        #expect(snapshot.accountEmail == "oauth@example.com")
        #expect(published.identity?.accountEmail == "oauth@example.com")
        #expect(published.identity?.providerID == .claude)
        #expect(snapshot.accountID != nil)
        #expect(snapshot.primary?.usedPercent == 17)
        #expect(snapshot.accountOrganization == nil)
    }

    @Test
    func `profile email does not require enough fields to establish widget ownership`() async throws {
        let snapshot = try await self.fetch { _ in
            OAuthProfileResponse(emailAddress: "oauth@example.com", organizationUuid: nil)
        }
        #expect(snapshot.accountEmail == "oauth@example.com")
        #expect(snapshot.accountID == nil)
        #expect(snapshot.primary?.usedPercent == 17)
    }

    @Test
    func `failed optional profile leaves successful OAuth usage available`() async throws {
        let snapshot = try await self.fetch { _ in throw URLError(.timedOut) }
        #expect(snapshot.accountEmail == nil)
        #expect(snapshot.accountID == nil)
        #expect(snapshot.primary?.usedPercent == 17)
    }

    @Test
    func `ordinary OAuth refresh retains the profile request opt in`() async throws {
        let snapshot = try await self.fetch(includeAccountIdentity: false) { _ in
            Issue.record("Ordinary refresh must not request an optional profile")
            throw URLError(.badServerResponse)
        }
        #expect(snapshot.accountEmail == nil)
        #expect(snapshot.accountID == nil)
        #expect(snapshot.primary?.usedPercent == 17)
    }

    private func fetch(
        includeAccountIdentity: Bool = true,
        profile: @escaping @Sendable (String) async throws -> OAuthProfileResponse) async throws -> ClaudeUsageSnapshot
    {
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            dataSource: .oauth,
            includeAccountIdentity: includeAccountIdentity)
        let credentials: @Sendable ([String: String], Bool, Bool) async throws -> ClaudeOAuthCredentials = { _, _, _ in
            ClaudeOAuthCredentials(
                accessToken: "fixture-oauth-token",
                refreshToken: nil,
                expiresAt: Date(timeIntervalSinceNow: 3600),
                scopes: ["user:profile"],
                rateLimitTier: "claude_pro")
        }
        let usage: @Sendable (String, Bool) async throws -> OAuthUsageResponse = { _, _ in
            try ClaudeOAuthUsageFetcher._decodeUsageResponseForTesting(Data("""
            {"five_hour":{"utilization":17}}
            """.utf8))
        }
        return try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(credentials) {
            try await ClaudeUsageFetcher.$fetchOAuthUsageOverride.withValue(usage) {
                try await ClaudeUsageFetcher.$fetchOAuthProfileOverride.withValue(profile) {
                    try await fetcher.loadLatestUsage()
                }
            }
        }
    }
}
