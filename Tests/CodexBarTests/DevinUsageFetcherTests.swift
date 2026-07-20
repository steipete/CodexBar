import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
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
    func `parses current Devin quota response with reset timestamps`() throws {
        let response: [String: Any] = [
            "is_quota_plan": true,
            "has_quota_allocation": true,
            "daily_percentage": 0.12,
            "weekly_percentage": 42,
            "daily_reset_at": "2026-06-11T00:00:00-08:00",
            "weekly_reset_at": "2026-06-14T00:00:00-08:00",
            "hide_daily_quota": false,
        ]

        let snapshot = try DevinUsageParser.parse(response, organization: "org/example-org", now: Self.now)

        #expect(snapshot.daily?.usedPercent == 12)
        #expect(snapshot.weekly?.usedPercent == 42)
        #expect(snapshot.daily?.resetsAt?.timeIntervalSince1970 == 1_781_164_800)
        #expect(snapshot.weekly?.resetsAt?.timeIntervalSince1970 == 1_781_424_000)
    }

    @Test
    func `parses overage balance into extra usage provider cost`() throws {
        let response: [String: Any] = [
            "daily_percentage": 12,
            "weekly_percentage": 42,
            "overage_balance": 70.87,
        ]

        let snapshot = try DevinUsageParser.parse(response, organization: nil, now: Self.now)

        #expect(snapshot.overageBalance == 70.87)
        let cost = try #require(snapshot.toUsageSnapshot().providerCost)
        #expect(cost.used == 70.87)
        #expect(cost.limit == 0)
        #expect(cost.currencyCode == "USD")
        #expect(cost.period == "Extra usage balance")
        #expect(cost.updatedAt == Self.now)
    }

    @Test
    func `parses overage balance cents into extra usage provider cost`() throws {
        let response: [String: Any] = [
            "daily_percentage": 12,
            "weekly_percentage": 42,
            "overage_balance_cents": 7087,
        ]

        let snapshot = try DevinUsageParser.parse(response, organization: nil, now: Self.now)

        #expect(snapshot.overageBalance == 70.87)
        #expect(snapshot.toUsageSnapshot().providerCost?.period == "Extra usage balance")
    }

    @Test
    func `omits provider cost when overage balance is absent`() throws {
        let response: [String: Any] = [
            "daily_percentage": 12,
            "weekly_percentage": 42,
        ]

        let snapshot = try DevinUsageParser.parse(response, organization: nil, now: Self.now)

        #expect(snapshot.overageBalance == nil)
        #expect(snapshot.toUsageSnapshot().providerCost == nil)
    }

    @Test(arguments: ["-1", "Infinity", "NaN"])
    func `omits invalid overage balances`(_ balance: String) throws {
        let response: [String: Any] = [
            "daily_percentage": 12,
            "weekly_percentage": 42,
            "overage_balance": balance,
        ]

        let snapshot = try DevinUsageParser.parse(response, organization: nil, now: Self.now)

        #expect(snapshot.overageBalance == nil)
        #expect(snapshot.toUsageSnapshot().providerCost == nil)
    }

    @Test(arguments: ["-1", "Infinity", "NaN"])
    func `omits invalid overage balance cents`(_ balance: String) throws {
        let response: [String: Any] = [
            "daily_percentage": 12,
            "weekly_percentage": 42,
            "overage_balance_cents": balance,
        ]

        let snapshot = try DevinUsageParser.parse(response, organization: nil, now: Self.now)

        #expect(snapshot.overageBalance == nil)
        #expect(snapshot.toUsageSnapshot().providerCost == nil)
    }

    @Test
    func `keeps weekly quota when current plan hides daily quota`() throws {
        let response: [String: Any] = [
            "weekly_percentage": 25,
            "weekly_reset_at": "2026-06-14T00:00:00-08:00",
            "hide_daily_quota": true,
        ]

        let usage = try DevinUsageParser.parse(response, organization: nil, now: Self.now).toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.secondary?.usedPercent == 25)
    }

    @Test
    func `normalizes mixed-scale current percentages at the one-percent boundary`() throws {
        let cases: [(input: Double, expected: Double)] = [
            (0.5, 50),
            (1, 1),
            (1.5, 1.5),
        ]

        for value in cases {
            let response: [String: Any] = [
                "daily_percentage": value.input,
                "weekly_percentage": value.input,
            ]
            let snapshot = try DevinUsageParser.parse(response, organization: nil, now: Self.now)

            #expect(snapshot.daily?.usedPercent == value.expected)
            #expect(snapshot.weekly?.usedPercent == value.expected)
        }
    }

    @Test
    func `preserves fractional boundaries for fallback quota percentages`() throws {
        let response: [String: Any] = [
            "quota_usage": [
                "daily_quota": [
                    "used_percent": 1,
                    "reset_at": "2026-06-01T08:00:00Z",
                ],
                "weekly_quota": [
                    "remaining_percent": 1,
                    "next_reset_at": 1_780_560_000,
                ],
            ],
        ]

        let snapshot = try DevinUsageParser.parse(response, organization: nil, now: Self.now)

        #expect(snapshot.daily?.usedPercent == 100)
        #expect(snapshot.weekly?.usedPercent == 0)
    }

    @Test
    func `parses zero percentages from JSON response`() throws {
        let data = Data("""
        {
          "daily_percentage": 0,
          "weekly_percentage": 0,
          "daily_reset_at": "2026-06-11T00:00:00-08:00",
          "weekly_reset_at": "2026-06-14T00:00:00-08:00"
        }
        """.utf8)

        let snapshot = try DevinUsageParser.parse(data, organization: nil, now: Self.now)

        #expect(snapshot.daily?.usedPercent == 0)
        #expect(snapshot.weekly?.usedPercent == 0)
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
            internalOrganizationID: "org_GQ6LhcfkW1TSinM6",
            sourceLabel: "test")
        let stub = ProviderHTTPTransportStub { request in
            #expect(request.url?.host == "app.devin.ai")
            #expect(request.url?.path == "/api/org_GQ6LhcfkW1TSinM6/billing/quota/usage")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
            #expect(request.value(forHTTPHeaderField: "x-cog-org-id") == "org_GQ6LhcfkW1TSinM6")
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
    func `fetch does not mask parser failure with fallback endpoint errors`() async {
        let auth = DevinUsageFetcher.RequestAuth(
            bearerToken: "secret-token",
            organization: "org/example-org",
            internalOrganizationID: "org_GQ6LhcfkW1TSinM6",
            sourceLabel: "test")
        let stub = ProviderHTTPTransportStub { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: request.url?.path == "/api/org_GQ6LhcfkW1TSinM6/billing/quota/usage" ? 200 : 404,
                httpVersion: nil,
                headerFields: nil)!
            return (Data("{}".utf8), response)
        }

        do {
            _ = try await DevinUsageFetcher.fetchQuotaUsage(
                auth: auth,
                now: Self.now,
                transport: stub)
            Issue.record("Expected quota parsing to fail")
        } catch let error as DevinUsageError {
            guard case .parseFailed = error else {
                Issue.record("Expected parseFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected DevinUsageError, got \(error)")
        }

        #expect(await stub.requests().count == 1)
    }

    @Test
    func `normalizes organization inputs`() {
        #expect(DevinUsageFetcher.normalizedOrganization("example-org") == "org/example-org")
        #expect(DevinUsageFetcher.normalizedOrganization("org/example-org") == "org/example-org")
        #expect(DevinUsageFetcher.normalizedOrganization("org_GQ6LhcfkW1TSinM6") ==
            "organizations/org_GQ6LhcfkW1TSinM6")
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
    func `empty app organization setting preserves imported organization`() async throws {
        try await DevinSessionImporter.withImportSessionOverrideForTesting { _, organizationOverride, _ in
            #expect(organizationOverride == nil)
            return DevinSessionImporter.SessionInfo(
                accessToken: "test-access-token",
                organization: "org/example-org",
                internalOrganizationID: "org_GQ6LhcfkW1TSinM6",
                sourceLabel: "Chrome Default")
        } operation: {
            let stub = ProviderHTTPTransportStub { request in
                #expect(request.url?.path == "/api/org_GQ6LhcfkW1TSinM6/billing/quota/usage")
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil)!
                return (Data(#"{"daily_percentage":0,"weekly_percentage":0}"#.utf8), response)
            }

            let snapshot = try await DevinUsageFetcher(browserDetection: BrowserDetection(cacheTTL: 0)).fetch(
                organizationOverride: "",
                now: Self.now,
                transport: stub)

            #expect(snapshot.organization == "example-org")
            #expect(snapshot.daily?.usedPercent == 0)
            #expect(snapshot.weekly?.usedPercent == 0)
        }
    }

    @Test
    func `session importer extracts current auth1 token and matching org`() throws {
        let accessToken = "auth1_abcdefghijklmnopqrstuvwxyz0123456789"
        let storage = [
            "_https://app.devin.ai\u{0000}\u{0001}auth1_session":
                #"{"token":"\#(accessToken)","userId":"github|123"}"#,
            "_https://app.devin.ai\u{0000}\u{0001}last-internal-org-for-external-org-v1-example-org":
                "\"org_GQ6LhcfkW1TSinM6\"",
        ]

        let session = try #require(DevinSessionImporter.session(
            from: storage,
            organizationOverride: "example-org",
            sourceLabel: "Chrome Default"))

        #expect(session.accessToken == accessToken)
        #expect(session.organization == "org/example-org")
        #expect(session.internalOrganizationID == "org_GQ6LhcfkW1TSinM6")
        #expect(session.sourceLabel == "Chrome Default")
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
              "internalOrgId": "org_GQ6LhcfkW1TSinM6",
              "orgName": "example-org"
            }
            """,
        ]

        let session = try #require(DevinSessionImporter.session(
            from: storage,
            organizationOverride: nil,
            sourceLabel: "Brave Default"))

        #expect(session.organization == "org/example-org")
        #expect(session.internalOrganizationID == "org_GQ6LhcfkW1TSinM6")
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
                "org_id": "org_GQ6LhcfkW1TSinM6",
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
        #expect(session.internalOrganizationID == "org_GQ6LhcfkW1TSinM6")
    }

    @Test
    func `session importer falls back to internal organization id`() {
        let result = DevinSessionImporter.organizationInfo(
            from: [
                "_https://app.devin.ai\u{0000}\u{0001}feature-flags-cache:org_GQ6LhcfkW1TSinM6": "{}",
                "_https://app.devin.ai\u{0000}\u{0001}member-info-v1-org-github|123": """
                {"value":{"org_id":"org_GQ6LhcfkW1TSinM6"}}
                """,
            ],
            organizationOverride: nil)

        #expect(result.organization == "organizations/org_GQ6LhcfkW1TSinM6")
        #expect(result.internalOrganizationID == "org_GQ6LhcfkW1TSinM6")
    }

    @Test
    func `session importer ignores org words inside storage key names`() {
        let result = DevinSessionImporter.organizationInfo(
            from: [
                "_https://app.devin.ai\u{0000}\u{0001}last-internal-org-for-external-org-v1-null": "\"null\"",
                "_https://app.devin.ai\u{0000}\u{0001}feature-flags-cache:org_GQ6LhcfkW1TSinM6": "{}",
            ],
            organizationOverride: nil)

        #expect(result.organization == "organizations/org_GQ6LhcfkW1TSinM6")
        #expect(result.internalOrganizationID == "org_GQ6LhcfkW1TSinM6")
    }

    @Test
    func `session importer deduplicates repeated browser tokens using richest organization metadata`() {
        let sessions = [
            DevinSessionImporter.SessionInfo(
                accessToken: "auth1_abcdefghijklmnopqrstuvwxyz0123456789",
                organization: nil,
                internalOrganizationID: nil,
                sourceLabel: "Chrome Default"),
            DevinSessionImporter.SessionInfo(
                accessToken: "auth1_abcdefghijklmnopqrstuvwxyz0123456789",
                organization: "org/example",
                internalOrganizationID: "org_GQ6LhcfkW1TSinM6",
                sourceLabel: "Chrome Profile 1"),
        ]

        let deduplicated = DevinSessionImporter.deduplicateSessions(sessions)

        #expect(deduplicated.count == 1)
        #expect(deduplicated.first?.sourceLabel == "Chrome Profile 1")
        #expect(deduplicated.first?.organization == "org/example")
        #expect(deduplicated.first?.internalOrganizationID == "org_GQ6LhcfkW1TSinM6")
    }

    @Test
    func `session importer ranks organization aware profiles first`() {
        let incomplete = DevinSessionImporter.SessionInfo(
            accessToken: "auth1_incomplete",
            organization: nil,
            internalOrganizationID: nil,
            sourceLabel: "Chrome Default")
        let complete = DevinSessionImporter.SessionInfo(
            accessToken: "auth1_complete",
            organization: "org/example",
            internalOrganizationID: "org_GQ6LhcfkW1TSinM6",
            sourceLabel: "Chrome Profile 1")

        let ranked = DevinSessionImporter.rankSessions([incomplete, complete])

        #expect(ranked.map(\.sourceLabel) == ["Chrome Profile 1", "Chrome Default"])
    }

    @Test
    func `missing organization retries the next browser profile`() {
        #expect(DevinUsageFetcher.shouldTryNextSession(after: DevinUsageError.missingOrganization))
        #expect(!DevinUsageFetcher.shouldTryNextSession(after: DevinUsageError.parseFailed("invalid response")))
    }

    @Test
    func `automatic local storage import does not fall back beyond Chrome`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }

        let braveRoot = temp
            .appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser/Default")
        try FileManager.default.createDirectory(at: braveRoot, withIntermediateDirectories: true)
        let detection = BrowserDetection(homeDirectory: temp.path, cacheTTL: 0)

        #expect(detection.hasUsableProfileData(.brave))
        #expect(!detection.hasUsableProfileData(.chrome))
        #expect(DevinSessionImporter.localStorageBrowsers(browserDetection: detection).isEmpty)
    }
    #endif
}
