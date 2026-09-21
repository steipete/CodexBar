import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
@Suite(.serialized)
struct DevinEnterpriseUsageTests {
    private static let now = Date(timeIntervalSince1970: 1_780_000_000)

    // MARK: - Personal analytics (enterprise ACU cycle)

    @Test
    func `parses personal analytics usage-limit into a monthly cycle window`() throws {
        let cycleEnd = "2030-02-15T12:00:00Z"
        let cycleStart = "2030-01-15T12:00:00Z"
        let data = Data("""
        {
          "tier_name": "enterprise_tier",
          "cycle_usage_limit": 100,
          "cycle_usage": 37.5,
          "cycle_start": "\(cycleStart)",
          "cycle_end": "\(cycleEnd)"
        }
        """.utf8)

        let snapshot = try DevinUsageParser.parsePersonalAnalytics(
            data,
            organization: "org/synthetic-team",
            now: Self.now)

        #expect(snapshot.cycle != nil)
        #expect(snapshot.daily == nil)
        #expect(snapshot.weekly == nil)
        let percent = try #require(snapshot.cycle?.usedPercent)
        #expect(percent == 37.5)
        #expect(snapshot.cycle?.startsAt == ISO8601DateFormatter().date(from: cycleStart))
        #expect(snapshot.cycle?.resetsAt == ISO8601DateFormatter().date(from: cycleEnd))
        #expect(snapshot.cycle?.used == 37.5)
        #expect(snapshot.cycle?.limit == 100)
        #expect(snapshot.planName == "Enterprise Tier")
        #expect(snapshot.organization == "synthetic-team")

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.windowMinutes == 31 * 24 * 60)
        let section = try #require(usage.details.first)
        #expect(section.title == "Personal ACU cycle")
        #expect(section.rows.map(\.label) == ["ACUs left", "ACUs used", "ACUs total"])
        #expect(section.rows.map(\.value) == ["62.5", "37.5", "100"])
    }

    @Test
    func `personal analytics cycle maps to a single monthly primary window`() throws {
        let data = Data(#"{"cycle_usage_limit":100,"cycle_usage":20,"cycle_end":"2030-02-15T12:00:00Z"}"#.utf8)

        let usage = try DevinUsageParser
            .parsePersonalAnalytics(data, organization: nil, now: Self.now)
            .toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 20)
        #expect(usage.primary?.windowMinutes == nil)
        #expect(usage.primary?.resetDescription == "Monthly")
        #expect(usage.primary?.resetsAt == ISO8601DateFormatter().date(from: "2030-02-15T12:00:00Z"))
        #expect(usage.secondary == nil)
        #expect(usage.providerCost == nil)
        #expect(usage.details.count == 1)
        #expect(usage.details.first?.rows.map(\.value) == ["80", "20", "100"])
    }

    @Test
    func `enterprise cycle uses credits label while standard Devin stays daily`() throws {
        let descriptor = DevinProviderDescriptor.descriptor
        let enterprise = try DevinUsageParser.parsePersonalAnalytics(
            ["cycle_usage_limit": 100, "cycle_usage": 20],
            organization: nil,
            now: Self.now)
            .toUsageSnapshot()
        let standard = try DevinUsageParser.parse(
            ["daily_percentage": 20, "weekly_percentage": 30],
            organization: nil,
            now: Self.now)
            .toUsageSnapshot()

        let enterpriseLabels = descriptor.presentation.rateWindowLabels(
            metadata: descriptor.metadata,
            snapshot: enterprise,
            now: Self.now)
        let standardLabels = descriptor.presentation.rateWindowLabels(
            metadata: descriptor.metadata,
            snapshot: standard,
            now: Self.now)

        #expect(enterpriseLabels.primary == "Credits")
        #expect(standardLabels.primary == "Daily")
    }

    @Test
    func `personal analytics accepts numeric strings and preserves zero usage`() throws {
        let snapshot = try DevinUsageParser.parsePersonalAnalytics(
            [
                "cycle_usage_limit": "40",
                "cycle_usage": "0",
                "cycle_end": "not-a-date",
            ],
            organization: nil,
            now: Self.now)

        #expect(snapshot.cycle?.usedPercent == 0)
        #expect(snapshot.cycle?.used == 0)
        #expect(snapshot.cycle?.limit == 40)
        #expect(snapshot.cycle?.resetsAt == nil)
        #expect(snapshot.toUsageSnapshot().primary?.windowMinutes == nil)
    }

    @Test
    func `personal analytics only uses a positive finite cycle date interval`() throws {
        let invalidDateIntervals: [[String: Any]] = [
            [
                "cycle_usage_limit": 10,
                "cycle_usage": 1,
                "cycle_start": "2030-02-15T12:00:00Z",
                "cycle_end": "2030-01-15T12:00:00Z",
            ],
            [
                "cycle_usage_limit": 10,
                "cycle_usage": 1,
                "cycle_start": "not-a-date",
                "cycle_end": "2030-02-15T12:00:00Z",
            ],
            [
                "cycle_usage_limit": 10,
                "cycle_usage": 1,
                "cycle_start": "2030-01-15T12:00:00Z",
                "cycle_end": Double.infinity,
            ],
        ]

        for payload in invalidDateIntervals {
            let usage = try DevinUsageParser.parsePersonalAnalytics(
                payload,
                organization: nil,
                now: Self.now)
                .toUsageSnapshot()

            #expect(usage.primary?.windowMinutes == nil)
        }
    }

    @Test
    func `personal analytics clamps over-limit percentage and remaining ACUs`() throws {
        let usage = try DevinUsageParser.parsePersonalAnalytics(
            ["cycle_usage_limit": 100, "cycle_usage": 125],
            organization: nil,
            now: Self.now)
            .toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.details.first?.rows.map(\.value) == ["0", "125", "100"])
    }

    @Test
    func `personal analytics rejects missing or invalid cycle values`() {
        let invalidPayloads: [[String: Any]] = [
            ["cycle_usage": 10],
            ["cycle_usage_limit": 100],
            ["cycle_usage_limit": 0, "cycle_usage": 10],
            ["cycle_usage_limit": -1, "cycle_usage": 10],
            ["cycle_usage_limit": Double.nan, "cycle_usage": 10],
            ["cycle_usage_limit": Double.infinity, "cycle_usage": 10],
            ["cycle_usage_limit": 100, "cycle_usage": -1],
            ["cycle_usage_limit": 100, "cycle_usage": Double.nan],
            ["cycle_usage_limit": 100, "cycle_usage": Double.infinity],
            ["cycle_usage_limit": "invalid", "cycle_usage": 10],
        ]

        for payload in invalidPayloads {
            #expect(throws: DevinUsageError.self) {
                _ = try DevinUsageParser.parsePersonalAnalytics(payload, organization: nil, now: Self.now)
            }
        }
    }

    @Test
    func `personal analytics reports malformed JSON as a provider parse error`() {
        do {
            _ = try DevinUsageParser.parsePersonalAnalytics(
                Data("not-json".utf8),
                organization: nil,
                now: Self.now)
            Issue.record("Expected a parseFailed error")
        } catch let error as DevinUsageError {
            guard case let .parseFailed(message) = error else {
                Issue.record("Expected parseFailed, got \(error)")
                return
            }
            #expect(message == "Devin personal analytics payload was not valid JSON.")
        } catch {
            Issue.record("Expected DevinUsageError, got \(error)")
        }
    }

    @Test
    func `enterprise host accepts only a canonical HTTPS origin`() {
        let validHosts = [
            ("your-team.devinenterprise.com", "https://your-team.devinenterprise.com"),
            ("https://your-team.devinenterprise.com", "https://your-team.devinenterprise.com"),
            ("https://your-team.devinenterprise.com/", "https://your-team.devinenterprise.com"),
            ("  HTTPS://YOUR-TEAM.DEVINENTERPRISE.COM/  ", "https://your-team.devinenterprise.com"),
        ]
        for (input, expected) in validHosts {
            #expect(DevinUsageFetcher.customHost(input)?.absoluteString == expected)
        }

        let invalidHosts = [
            "https://your-team.devinenterprise.com/settings",
            "your-team.devinenterprise.com/settings",
            "https://your-team.devinenterprise.com?tab=usage",
            "https://your-team.devinenterprise.com#usage",
            "https://user:fixture@your-team.devinenterprise.com",
            "http://your-team.devinenterprise.com",
            "ftp://your-team.devinenterprise.com",
            "your team.devinenterprise.com",
            "localhost",
            "127.0.0.1",
            "your-team.devinenterprise.com:8443",
            "your-team.devinenterprise.com:443",
            "https://",
            "//your-team.devinenterprise.com",
        ]
        for input in invalidHosts {
            #expect(DevinUsageFetcher.customHost(input) == nil)
        }
        #expect(DevinUsageFetcher.customHost(nil) == nil)
        #expect(DevinUsageFetcher.customHost("") == nil)
        #expect(DevinUsageFetcher.customHost("  ") == nil)
        #expect(DevinUsageFetcher.dashboardURL(organization: nil).absoluteString ==
            "https://app.devin.ai/settings/usage")
    }

    @Test
    func `empty enterprise host keeps the standard quota endpoint`() async throws {
        let auth = DevinUsageFetcher.RequestAuth(
            bearerToken: "synthetic-standard-bearer",
            organization: "org/synthetic-team",
            internalOrganizationID: "org_synthetic123456",
            sourceLabel: "test")
        let stub = ProviderHTTPTransportStub { request in
            #expect(request.url?.host == "app.devin.ai")
            #expect(request.url?.path == "/api/org_synthetic123456/billing/quota/usage")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            return (Data(#"{"daily_percentage":10,"weekly_percentage":20}"#.utf8), response)
        }

        let snapshot = try await DevinUsageFetcher.fetchQuotaUsage(
            auth: auth,
            apiHost: "  ",
            now: Self.now,
            transport: stub)

        #expect(snapshot.daily?.usedPercent == 10)
        #expect(snapshot.weekly?.usedPercent == 20)
        #expect(await stub.requests().count == 1)
    }

    @Test
    func `enterprise fetch uses only the configured personal-analytics endpoint`() async throws {
        let auth = DevinUsageFetcher.RequestAuth(
            bearerToken: "synthetic-enterprise-bearer",
            organization: "org/enterprise-team",
            internalOrganizationID: "org_enterprise123456",
            sourceLabel: "test")
        let stub = ProviderHTTPTransportStub { request in
            #expect(request.url?.host == "your-team.devinenterprise.com")
            #expect(request.url?.path == "/api/personal-analytics/usage-limit")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-enterprise-bearer")
            #expect(request.value(forHTTPHeaderField: "x-cog-org-id") ==
                "org_enterprise123456")
            let body = #"{"cycle_usage_limit":100,"cycle_usage":25,"cycle_end":"2030-02-15T12:00:00Z"}"#
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            return (Data(body.utf8), response)
        }

        let snapshot = try await DevinUsageFetcher.fetchQuotaUsage(
            auth: auth,
            organizationOverride: "standard-org",
            apiHost: "https://your-team.devinenterprise.com/",
            now: Self.now,
            transport: stub)

        #expect(snapshot.cycle?.usedPercent == 25)
        #expect(snapshot.organization == "enterprise-team")
        #expect(await stub.requests().count == 1)
    }

    @Test
    func `enterprise personal analytics does not require an organization override`() async throws {
        let auth = DevinUsageFetcher.RequestAuth(
            bearerToken: "synthetic-enterprise-bearer",
            organization: nil,
            internalOrganizationID: nil,
            sourceLabel: "test")
        let stub = ProviderHTTPTransportStub { request in
            #expect(request.url?.host == "your-team.devinenterprise.com")
            #expect(request.url?.path == "/api/personal-analytics/usage-limit")
            #expect(request.value(forHTTPHeaderField: "x-cog-org-id") == nil)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            return (Data(#"{"cycle_usage_limit":10,"cycle_usage":2}"#.utf8), response)
        }

        let snapshot = try await DevinUsageFetcher.fetchQuotaUsage(
            auth: auth,
            organizationOverride: "standard-org",
            apiHost: "your-team.devinenterprise.com",
            now: Self.now,
            transport: stub)

        #expect(snapshot.organization == nil)
        #expect(snapshot.cycle?.usedPercent == 20)
        #expect(await stub.requests().count == 1)
    }

    @Test
    func `invalid configured enterprise host fails without a standard-host request`() async {
        let auth = DevinUsageFetcher.RequestAuth(
            bearerToken: "synthetic-bearer",
            organization: "org/synthetic-team",
            internalOrganizationID: nil,
            sourceLabel: "test")
        let stub = ProviderHTTPTransportStub { request in
            Issue.record("Invalid Enterprise host must not make a request to \(request.url?.host ?? "unknown").")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil)!
            return (Data(), response)
        }

        do {
            _ = try await DevinUsageFetcher.fetchQuotaUsage(
                auth: auth,
                apiHost: "http://your-team.devinenterprise.com",
                now: Self.now,
                transport: stub)
            Issue.record("Expected invalidEnterpriseHost")
        } catch let error as DevinUsageError {
            guard case .invalidEnterpriseHost = error else {
                Issue.record("Expected invalidEnterpriseHost, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected DevinUsageError, got \(error)")
        }
        #expect(await stub.requests().isEmpty)
    }

    @Test
    func `enterprise unauthorized response reports expired credentials`() async {
        let auth = DevinUsageFetcher.RequestAuth(
            bearerToken: "synthetic-enterprise-bearer",
            organization: nil,
            internalOrganizationID: nil,
            sourceLabel: "test")
        let stub = ProviderHTTPTransportStub { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil)!
            return (Data(#"{"detail":"unauthorized"}"#.utf8), response)
        }

        do {
            _ = try await DevinUsageFetcher.fetchQuotaUsage(
                auth: auth,
                apiHost: "your-team.devinenterprise.com",
                now: Self.now,
                transport: stub)
            Issue.record("Expected invalidCredentials")
        } catch let error as DevinUsageError {
            guard case .invalidCredentials = error else {
                Issue.record("Expected invalidCredentials, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected DevinUsageError, got \(error)")
        }
        #expect(await stub.requests().count == 1)
    }

    @Test
    func `enterprise forbidden response explains the personal analytics permission`() async {
        let auth = DevinUsageFetcher.RequestAuth(
            bearerToken: "synthetic-enterprise-bearer",
            organization: nil,
            internalOrganizationID: nil,
            sourceLabel: "test")
        let stub = ProviderHTTPTransportStub { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 403,
                httpVersion: nil,
                headerFields: nil)!
            return (Data(#"{"detail":"permission denied"}"#.utf8), response)
        }

        do {
            _ = try await DevinUsageFetcher.fetchQuotaUsage(
                auth: auth,
                apiHost: "your-team.devinenterprise.com",
                now: Self.now,
                transport: stub)
            Issue.record("Expected missingPersonalAnalyticsPermission")
        } catch let error as DevinUsageError {
            guard case .missingPersonalAnalyticsPermission = error else {
                Issue.record("Expected missingPersonalAnalyticsPermission, got \(error)")
                return
            }
            #expect(error.localizedDescription.contains("View Personal Analytics"))
            #expect(!error.localizedDescription.contains("synthetic-enterprise-bearer"))
        } catch {
            Issue.record("Expected DevinUsageError, got \(error)")
        }
        #expect(await stub.requests().count == 1)
    }

    @Test
    func `enterprise invalid response is a parser error without endpoint fallback`() async {
        let auth = DevinUsageFetcher.RequestAuth(
            bearerToken: "synthetic-enterprise-bearer",
            organization: nil,
            internalOrganizationID: nil,
            sourceLabel: "test")
        let stub = ProviderHTTPTransportStub { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            return (Data("{}".utf8), response)
        }

        do {
            _ = try await DevinUsageFetcher.fetchQuotaUsage(
                auth: auth,
                apiHost: "your-team.devinenterprise.com",
                now: Self.now,
                transport: stub)
            Issue.record("Expected personal analytics parsing to fail")
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
    func `enterprise origin ignores the standard manual bearer and organization override`() async throws {
        try await DevinSessionImporter.withImportSessionOverrideForTesting { _, organizationOverride, _ in
            #expect(organizationOverride == nil)
            return DevinSessionImporter.SessionInfo(
                accessToken: "synthetic-enterprise-auth0",
                organization: "org/enterprise-team",
                internalOrganizationID: "org_enterprise123456",
                sourceLabel: "Chrome Enterprise")
        } operation: {
            let stub = ProviderHTTPTransportStub { request in
                #expect(request.url?.host == "your-team.devinenterprise.com")
                #expect(request.value(forHTTPHeaderField: "Authorization") ==
                    "Bearer synthetic-enterprise-auth0")
                #expect(request.value(forHTTPHeaderField: "x-cog-org-id") == "org_enterprise123456")
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil)!
                return (Data(#"{"cycle_usage_limit":20,"cycle_usage":5}"#.utf8), response)
            }
            let fetcher = DevinUsageFetcher(browserDetection: BrowserDetection(cacheTTL: 0))

            let snapshot = try await fetcher.fetch(
                bearerTokenOverride: "synthetic-standard-bearer",
                organizationOverride: "standard-org",
                apiHost: "your-team.devinenterprise.com",
                now: Self.now,
                transport: stub)

            #expect(snapshot.organization == "enterprise-team")
            #expect(snapshot.cycle?.usedPercent == 25)
            #expect(await stub.requests().count == 1)
        }
    }
}
#endif
