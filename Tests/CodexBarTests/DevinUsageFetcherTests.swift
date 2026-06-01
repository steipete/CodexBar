import Foundation
import Testing
@testable import CodexBarCore

struct DevinUsageFetcherTests {
    private static let now = Date(timeIntervalSince1970: 1_780_000_000)

    @Test
    func `parses quota usage response into daily and weekly windows`() throws {
        let response: [String: Any] = [
            "plan_name": "pro",
            "quota_usage": [
                "daily_quota": [
                    "used": 3,
                    "limit": 10,
                    "reset_at": "2026-06-01T08:00:00Z",
                ],
                "weekly_quota": [
                    "remaining_percent": 0.25,
                    "next_reset_at": 1_780_560_000,
                ],
            ],
        ]

        let snapshot = try DevinUsageParser.parse(response, organization: "org/example-org", now: Self.now)

        #expect(snapshot.daily?.usedPercent == 30)
        #expect(snapshot.weekly?.usedPercent == 75)
        #expect(snapshot.daily?.resetsAt?.timeIntervalSince1970 == 1_780_300_800)
        #expect(snapshot.weekly?.resetsAt?.timeIntervalSince1970 == 1_780_560_000)
        #expect(snapshot.planName == "Pro")
        #expect(snapshot.organization == "example-org")
    }

    @Test
    func `usage snapshot maps Devin quotas to primary and secondary windows`() {
        let snapshot = DevinUsageSnapshot(
            daily: DevinQuotaWindow(usedPercent: 12),
            weekly: DevinQuotaWindow(usedPercent: 42),
            planName: "Free",
            organization: "example-org",
            updatedAt: Self.now)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 12)
        #expect(usage.primary?.windowMinutes == 1440)
        #expect(usage.primary?.resetDescription == "Daily")
        #expect(usage.secondary?.usedPercent == 42)
        #expect(usage.secondary?.windowMinutes == 10080)
        #expect(usage.secondary?.resetDescription == "Weekly")
        #expect(usage.identity?.providerID == .devin)
        #expect(usage.identity?.accountOrganization == "example-org")
        #expect(usage.identity?.loginMethod == "Free")
    }

    @Test
    func `fetch sends bearer token and organization header`() async throws {
        let auth = DevinUsageFetcher.RequestAuth(
            bearerToken: "secret-token",
            organization: "org/example-org",
            internalOrganizationID: "org-b31f951cd01d4c6da84991cf5b970cfb",
            sourceLabel: "test")
        let stub = ProviderHTTPTransportStub { request in
            #expect(request.url?.host == "app.devin.ai")
            #expect(request.url?.path == "/api/org-b31f951cd01d4c6da84991cf5b970cfb/billing/quota/usage")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
            #expect(request.value(forHTTPHeaderField: "x-cog-org-id") == "org-b31f951cd01d4c6da84991cf5b970cfb")
            let body = """
            {"daily":{"used_percent":10},"weekly":{"used_percent":20},"plan":"free"}
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            return (Data(body.utf8), response)
        }

        let snapshot = try await DevinUsageFetcher.fetchQuotaUsage(
            auth: auth,
            now: Self.now,
            transport: stub)

        #expect(snapshot.daily?.usedPercent == 10)
        #expect(snapshot.weekly?.usedPercent == 20)
        #expect(snapshot.planName == "Free")
    }

    @Test
    func `fetch refreshes expired browser access token once`() async throws {
        let oldToken = "old.token.with.enough.length"
        let newToken = "new.token.with.enough.length"
        let refreshToken = "refresh.token.with.enough.length"
        let tokenEndpoint = try #require(URL(string: "https://dev-us.auth0.com/oauth/token"))
        let auth = DevinUsageFetcher.RequestAuth(
            bearerToken: oldToken,
            refreshToken: refreshToken,
            refreshSession: DevinUsageFetcher.RequestAuth.RefreshSession(
                tokenEndpoint: tokenEndpoint,
                clientID: "client",
                audience: "https://backend.webapp.devin.ai",
                scope: "openid profile"),
            organization: "org/example-org",
            internalOrganizationID: "org-b31f951cd01d4c6da84991cf5b970cfb",
            sourceLabel: "Brave Default")
        let stub = ProviderHTTPTransportStub { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: request.url?.host == "dev-us.auth0.com" ? 200 :
                    (request.value(forHTTPHeaderField: "Authorization") == "Bearer \(newToken)" ? 200 : 401),
                httpVersion: nil,
                headerFields: nil)!

            if request.url?.host == "dev-us.auth0.com" {
                #expect(request.httpMethod == "POST")
                let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                #expect(body.contains("grant_type=refresh_token"))
                #expect(body.contains("refresh_token=refresh.token.with.enough.length"))
                return (Data(#"{"access_token":"\#(newToken)"}"#.utf8), response)
            }

            if request.value(forHTTPHeaderField: "Authorization") == "Bearer \(newToken)" {
                let body = #"{"daily":{"used_percent":10},"weekly":{"used_percent":20},"plan":"free"}"#
                return (Data(body.utf8), response)
            }
            return (Data(#"{"error":"expired"}"#.utf8), response)
        }

        let snapshot = try await DevinUsageFetcher.fetchQuotaUsage(
            auth: auth,
            now: Self.now,
            transport: stub)

        let requests = await stub.requests()
        #expect(requests.map { $0.url?.host } == ["app.devin.ai", "dev-us.auth0.com", "app.devin.ai"])
        #expect(snapshot.daily?.usedPercent == 10)
        #expect(snapshot.weekly?.usedPercent == 20)
    }

    @Test
    func `normalizes organization inputs`() {
        #expect(DevinUsageFetcher.normalizedOrganization("example-org") == "org/example-org")
        #expect(DevinUsageFetcher.normalizedOrganization("org/example-org") == "org/example-org")
        #expect(DevinUsageFetcher.normalizedOrganization("org-b31f951cd01d4c6da84991cf5b970cfb") ==
            "organizations/org-b31f951cd01d4c6da84991cf5b970cfb")
        #expect(DevinUsageFetcher.normalizedOrganization("https://app.devin.ai/org/example-org/settings/usage") ==
            "org/example-org")
    }

    @Test
    func `manual auth strips Authorization and Bearer prefixes`() throws {
        let auth = try #require(DevinUsageFetcher.manualAuth(
            from: "Authorization: Bearer secret-token",
            organization: "example-org"))

        #expect(auth.bearerToken == "secret-token")
        #expect(auth.organization == "org/example-org")
        #expect(auth.sourceLabel == "manual")
    }

    #if os(macOS)
    @Test
    func `session importer extracts auth0 access token and matching org`() throws {
        let accessToken = "eyJhbGciOiJub25lIn0.eyJpc3MiOiJodHRwczovL2Rldi11cy5hdXRoMC5jb20vIn0.signature"
        let auth0Key =
            "_https://app.devin.ai\u{0000}\u{0001}" +
            "@@auth0spajs@@::client::https://backend.webapp.devin.ai::openid profile"
        let storage = [
            auth0Key: """
            {"body":{"access_token":"\(accessToken)","refresh_token":"refresh.token.with.enough.length"}}
            """,
            "_https://app.devin.ai\u{0000}\u{0001}last-internal-org-for-external-org-v1-example-org":
                "\"org-b31f951cd01d4c6da84991cf5b970cfb\"",
        ]

        let session = try #require(DevinSessionImporter.session(
            from: storage,
            organizationOverride: "example-org",
            sourceLabel: "Brave Default"))

        #expect(session.accessToken == accessToken)
        #expect(session.refreshToken == "refresh.token.with.enough.length")
        #expect(session.auth0?.tokenEndpoint.absoluteString == "https://dev-us.auth0.com/oauth/token")
        #expect(session.auth0?.clientID == "client")
        #expect(session.auth0?.audience == "https://backend.webapp.devin.ai")
        #expect(session.organization == "org/example-org")
        #expect(session.internalOrganizationID == "org-b31f951cd01d4c6da84991cf5b970cfb")
        #expect(session.sourceLabel == "Brave Default")
    }

    @Test
    func `session importer infers organization from post auth storage`() throws {
        let accessToken = "eyJhbGciOiJub25lIn0.eyJpc3MiOiJodHRwczovL2F1dGguZGV2aW4uYWkvIn0.signature"
        let storage = [
            "_https://app.devin.ai\u{0000}\u{0001}@@auth0spajs@@::client::audience::scope":
                #"{"body":{"access_token":"\#(accessToken)"}}"#,
            "_https://app.devin.ai\u{0000}\u{0001}post-auth-v3-null-github|123-org_name-example-org": """
            {
              "externalOrgId": null,
              "userId": "github|123",
              "internalOrgId": "org-b31f951cd01d4c6da84991cf5b970cfb",
              "orgName": "example-org"
            }
            """,
        ]

        let session = try #require(DevinSessionImporter.session(
            from: storage,
            organizationOverride: nil,
            sourceLabel: "Brave Default"))

        #expect(session.organization == "org/example-org")
        #expect(session.internalOrganizationID == "org-b31f951cd01d4c6da84991cf5b970cfb")
    }

    @Test
    func `session importer infers organization from member info storage`() throws {
        let accessToken = "eyJhbGciOiJub25lIn0.eyJpc3MiOiJodHRwczovL2F1dGguZGV2aW4uYWkvIn0.signature"
        let storage = [
            "_https://app.devin.ai\u{0000}\u{0001}@@auth0spajs@@::client::audience::scope":
                #"{"body":{"access_token":"\#(accessToken)"}}"#,
            "_https://app.devin.ai\u{0000}\u{0001}member-info-v1-org-github|123": """
            {
              "value": {
                "org_id": "org-b31f951cd01d4c6da84991cf5b970cfb",
                "org_name": "example-org"
              }
            }
            """,
        ]

        let session = try #require(DevinSessionImporter.session(
            from: storage,
            organizationOverride: nil,
            sourceLabel: "Brave Default"))

        #expect(session.organization == "org/example-org")
        #expect(session.internalOrganizationID == "org-b31f951cd01d4c6da84991cf5b970cfb")
    }

    @Test
    func `session importer falls back to internal organization id`() {
        let result = DevinSessionImporter.organizationInfo(
            from: [
                "_https://app.devin.ai\u{0000}\u{0001}feature-flags-cache:org-b31f951cd01d4c6da84991cf5b970cfb": "{}",
                "_https://app.devin.ai\u{0000}\u{0001}member-info-v1-org-github|123": """
                {"value":{"org_id":"org-b31f951cd01d4c6da84991cf5b970cfb"}}
                """,
            ],
            organizationOverride: nil)

        #expect(result.organization == "organizations/org-b31f951cd01d4c6da84991cf5b970cfb")
        #expect(result.internalOrganizationID == "org-b31f951cd01d4c6da84991cf5b970cfb")
    }

    @Test
    func `session importer infers organization from raw storage fallback`() {
        let result = DevinSessionImporter.organizationInfo(
            from: [
                "__codexbar_devin_org_slug": "example-org",
                "__codexbar_devin_internal_org_id": "org-b31f951cd01d4c6da84991cf5b970cfb",
            ],
            organizationOverride: nil)

        #expect(result.organization == "org/example-org")
        #expect(result.internalOrganizationID == "org-b31f951cd01d4c6da84991cf5b970cfb")
    }
    #endif
}
