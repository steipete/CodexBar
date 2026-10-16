import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CursorUnifiedUsageStatusTests {
    static let now = Date(timeIntervalSince1970: 1_792_152_000)
    static let monthly = """
    {"availability":"available","monthlyUsage":{
      "usedCents":725,"limitCents":1000,"creditsUsedCents":125,
      "periodStart":"2026-10-01T00:00:00.000Z","resetsAt":"2026-11-01T00:00:00.000Z"}}
    """

    @Test(arguments: [200, 403, 500])
    func `unified spend replaces legacy request lookup without changing included quota`(statusCode: Int) async throws {
        let session = CursorStatusProbeTestSession { request in
            let url = try #require(request.url)
            let body: String
            var code = 200
            switch url.path {
            case "/api/usage-summary":
                body = #"{"membershipType":"unified_ultra","individualUsage":{"onDemand":{"used":0,"limit":1000}}}"#
            case "/api/auth/me":
                body = #"{"sub":"fixture-user","email":"user@example.com"}"#
            case CursorSandUsageStatus.endpointPath:
                body = #"{"hasNonZeroIncludedLimit":true,"usagePercent":75}"#
            case CursorUnifiedUsageStatus.endpointPath:
                #expect(url.query == "scope=user")
                #expect(request.httpMethod == "GET")
                #expect(request.timeoutInterval <= 5)
                #expect(request.value(forHTTPHeaderField: "Cookie") == "auth=fixture")
                body = Self.monthly
                code = statusCode
            default:
                Issue.record("Unexpected request: \(url.path)")
                throw URLError(.badURL)
            }
            return makeCursorStatusProbeResponse(url: url, body: body, statusCode: code)
        }
        let probe = try CursorStatusProbe(
            baseURL: #require(URL(string: "https://cursor.test")),
            browserDetection: BrowserDetection(cacheTTL: 0),
            urlSession: session.urlSession)
        let snapshot = try await probe.fetchWithManualCookies("auth=fixture")
        let usage = snapshot.toUsageSnapshot(now: Self.now)
        #expect(session.requestCount == 4)
        #expect(!session.requestPaths.contains("/api/usage"))
        #expect(usage.extraRateWindows?.first?.window.usedPercent == 75)
        #expect(usage.identity?.accountEmail == "user@example.com")
        if statusCode == 200 {
            #expect(usage.providerCost?.used == 7.25)
            #expect(usage.providerCost?.limit == 10)
            #expect(usage.providerCost?.resetsAt == ISO8601DateParser.parse("2026-11-01T00:00:00Z"))
        } else {
            #expect(usage.providerCost == nil)
        }
    }

    @Test
    func `monthly amounts preserve zero and unlimited without adding prepaid consumption`() throws {
        let status = try JSONDecoder().decode(CursorUnifiedUsageStatus.self, from: Data(Self.monthly.utf8))
        #expect(status.currentMonthlyUsage(at: Self.now)?.usedCents == 725)
        let zero = Self.monthly.replacingOccurrences(of: "725", with: "0")
            .replacingOccurrences(of: "\"limitCents\":1000", with: "\"limitCents\":null")
        let unlimited = try JSONDecoder().decode(CursorUnifiedUsageStatus.self, from: Data(zero.utf8))
        #expect(unlimited.currentMonthlyUsage(at: Self.now)?.usedCents == 0)
        #expect(unlimited.currentMonthlyUsage(at: Self.now)?.limitCents == nil)
    }

    @Test(arguments: [
        ("\"available\"", "\"identity_unlinked\""),
        ("725", "-1"),
        ("\"limitCents\":1000", "\"limitCents\":-1"),
        ("2026-10-01", "2026-12-01"),
        ("2026-11-01", "2026-10-01"),
        ("2026-11-01T00:00:00.000Z", "bad-date"),
    ])
    func `unavailable malformed or out of period billing is not a zero`(replacement: (String, String)) throws {
        let json = Self.monthly.replacingOccurrences(of: replacement.0, with: replacement.1)
        let status = try JSONDecoder().decode(CursorUnifiedUsageStatus.self, from: Data(json.utf8))
        #expect(status.currentMonthlyUsage(at: Self.now) == nil)
    }

    @Test
    func `unified team budgets keep their existing scope and spend`() throws {
        let json = """
        {"membershipType":"unified_ultra","limitType":"team",
         "teamUsage":{"onDemand":{"used":5000,"limit":10000}}}
        """
        let summary = try JSONDecoder().decode(CursorUsageSummary.self, from: Data(json.utf8))
        #expect(!summary.usesUnifiedPersonalBilling)
        let probe = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
        let snapshot = probe.parseUsageSummary(summary, userInfo: nil, rawJSON: nil)
        #expect(snapshot.toUsageSnapshot(now: Self.now).providerCost?.used == 50)
        #expect(snapshot.toUsageSnapshot(now: Self.now).providerCost?.limit == 100)
    }

    @Test
    func `legacy plans retain their existing request and spend path`() async throws {
        let session = CursorStatusProbeTestSession { request in
            let url = try #require(request.url)
            let body: String
            switch url.path {
            case "/api/usage-summary":
                body = #"{"membershipType":"pro","individualUsage":{"onDemand":{"used":250,"limit":1000}}}"#
            case "/api/auth/me":
                body = #"{"sub":"fixture-user","email":"user@example.com"}"#
            case CursorSandUsageStatus.endpointPath:
                body = #"{"hasNonZeroIncludedLimit":true,"usagePercent":75}"#
            case "/api/usage":
                body = #"{"gpt-4":{"numRequests":3,"maxRequestUsage":10}}"#
            default:
                Issue.record("Unexpected request: \(url.path)")
                throw URLError(.badURL)
            }
            return makeCursorStatusProbeResponse(url: url, body: body, statusCode: 200)
        }
        let probe = try CursorStatusProbe(
            baseURL: #require(URL(string: "https://cursor.test")),
            browserDetection: BrowserDetection(cacheTTL: 0),
            urlSession: session.urlSession)
        let snapshot = try await probe.fetchWithManualCookies("auth=fixture")
        let usage = snapshot.toUsageSnapshot(now: Self.now)
        #expect(session.requestCount == 4)
        #expect(session.requestPaths.contains("/api/usage"))
        #expect(!session.requestPaths.contains(CursorUnifiedUsageStatus.endpointPath))
        #expect(usage.primary?.usedPercent == 30)
        #expect(usage.providerCost?.used == 2.5)
        #expect(usage.providerCost?.limit == 10)
    }
}
