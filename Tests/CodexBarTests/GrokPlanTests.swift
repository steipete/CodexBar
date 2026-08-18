import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct GrokPlanTests {
    @Test
    func `normalizes SuperGrok Heavy subscription tiers`() {
        #expect(GrokPlan.displayName(from: "SuperGrok Heavy") == "SuperGrok Heavy")
        #expect(GrokPlan.displayName(from: "supergrok_heavy") == "SuperGrok Heavy")
        #expect(GrokPlan.displayName(from: "  HEAVY  ") == "SuperGrok Heavy")
        #expect(GrokPlan.displayName(from: "SuperGrok") == "SuperGrok")
        #expect(GrokPlan.displayName(from: "Custom Team") == "Custom Team")
        #expect(GrokPlan.displayName(from: "   ") == nil)
        #expect(GrokPlan.displayName(from: nil) == nil)
    }

    @Test
    func `login method prefers billing tier over OIDC SuperGrok`() {
        let credentials = GrokCredentials(
            accessToken: "token",
            refreshToken: nil,
            scope: "https://auth.x.ai::client",
            authMode: "oidc",
            userId: nil,
            email: "grok@example.com",
            firstName: nil,
            lastName: nil,
            teamId: nil,
            oidcIssuer: nil,
            oidcClientId: nil,
            expiresAt: nil,
            createTime: nil)

        #expect(credentials.loginMethod == "SuperGrok")
        #expect(GrokPlan.loginMethod(subscriptionTier: "SuperGrok Heavy", credentials: credentials)
            == "SuperGrok Heavy")
        #expect(GrokPlan.loginMethod(subscriptionTier: nil, credentials: credentials) == "SuperGrok")
        #expect(GrokPlan.loginMethod(subscriptionTier: "  ", credentials: credentials) == "SuperGrok")
    }

    @Test
    func `settings parser reads subscription_tier_display`() {
        #expect(GrokCLISettingsFetcher.parse(Data(#"{"subscription_tier_display":"SuperGrok Heavy"}"#.utf8))
            == "SuperGrok Heavy")
        #expect(GrokCLISettingsFetcher.parse(Data(#"{"subscription_tier_display":"supergrok"}"#.utf8))
            == "SuperGrok")
        #expect(GrokCLISettingsFetcher.parse(Data(#"{}"#.utf8)) == nil)
        #expect(GrokCLISettingsFetcher.parse(Data("not-json".utf8)) == nil)
    }

    @Test
    func `applying a plan name keeps the existing usage percent`() {
        let snapshot = GrokWebBillingSnapshot(
            usedPercent: 0,
            resetsAt: Date(timeIntervalSince1970: 1_800_000_000))
        let applied = snapshot.applying(subscriptionTier: "SuperGrok Heavy")
        #expect(applied.subscriptionTier == "SuperGrok Heavy")
        #expect(applied.usedPercent == 0)
        #expect(applied.resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test
    func `settings load failure does not invent a previous Heavy tier`() async throws {
        let credentials = GrokCredentials(
            accessToken: "token-a",
            refreshToken: nil,
            scope: "https://auth.x.ai::client",
            authMode: "oidc",
            userId: "user-a",
            email: "a@example.com",
            firstName: nil,
            lastName: nil,
            teamId: nil,
            oidcIssuer: nil,
            oidcClientId: nil,
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            createTime: nil)
        let transport = GrokSettingsFailingTransport()

        let tier = try await GrokStatusProbe.loadSettingsTier(
            credentials: credentials,
            session: transport)

        #expect(tier == nil)
        #expect(GrokPlan.loginMethod(subscriptionTier: tier, credentials: credentials) == "SuperGrok")
    }

    @Test
    func `settings request uses a short enrichment timeout`() {
        #expect(GrokCLISettingsFetcher.requestTimeoutSeconds == 2)
        #expect(GrokStatusProbe.settingsJoinGrace == .seconds(2))
    }

    @Test
    func `settings endpoint is derived from the billing host`() throws {
        let billing = try #require(URL(string: "https://grok.test/v1/billing?format=credits"))
        #expect(GrokCLISettingsFetcher.endpoint(fromBilling: billing).absoluteString
            == "https://grok.test/v1/settings")
    }
}

private struct GrokSettingsFailingTransport: ProviderHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 500,
                  httpVersion: nil,
                  headerFields: nil)
        else {
            throw URLError(.badURL)
        }
        return (Data("nope".utf8), response)
    }
}
