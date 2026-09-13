import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
struct CursorSandTrialUsageTests {
    private static let now = Date(timeIntervalSince1970: 1_789_084_800) // 2026-09-11T00:00:00Z

    @Test(arguments: [false, true])
    func `unexpired trial does not require available or included usage`(available: Bool) throws {
        let status = try Self.decodeTrial(available: available)
        let extra = try #require(status.extraRateWindow(now: Self.now, resetDescription: { _ in "reset" }))

        #expect(extra.id == CursorSandUsageStatus.extraWindowID)
        #expect(extra.title == "Grok Bot")
        #expect(extra.window.usedPercent == 13.55)
        #expect(extra.window.windowMinutes == nil)
        #expect(extra.window.resetsAt == nil)
        #expect(extra.window.resetDescription == nil)
    }

    @Test
    func `exhausted unexpired trial stays visible`() throws {
        let status = try Self.decodeTrial(percent: "100", available: false)
        let extra = try #require(status.extraRateWindow(now: Self.now, resetDescription: { _ in "reset" }))
        #expect(extra.window.usedPercent == 100)
        #expect(extra.window.resetsAt == nil)
    }

    @Test(arguments: [
        "null", "42", "{}", "\"invalid\"", "\"2026-09-10T23:59:59Z\"", "\"2026-09-11T00:00:00Z\"",
    ])
    func `unavailable trial does not turn available usage into an allowance`(expiry: String) throws {
        let status = try Self.decodeTrial(expiry: expiry, available: true)
        #expect(status.extraRateWindow(now: Self.now, resetDescription: { _ in "reset" }) == nil)
    }

    @Test(arguments: [
        "null", "42", "{}", "\"invalid\"", "\"2026-09-10T23:59:59Z\"", "\"2026-09-11T00:00:00Z\"",
    ])
    func `invalid or ended trial preserves paid weekly allowance`(expiry: String) throws {
        let status = try Self.decodeTrial(expiry: expiry, included: true)
        let extra = try #require(status.extraRateWindow(now: Self.now, resetDescription: { _ in "reset" }))
        #expect(extra.window.usedPercent == 13.55)
        #expect(extra.window.windowMinutes == 10080)
        #expect(extra.window.resetsAt != nil)
        #expect(extra.window.resetDescription == "reset")
    }

    @Test
    func `future trial takes precedence over included weekly timing`() throws {
        let status = try Self.decodeTrial(expiry: "\"2026-09-14T00:00:00.123Z\"", included: true)
        let extra = try #require(status.extraRateWindow(now: Self.now, resetDescription: { _ in "reset" }))
        #expect(extra.window.windowMinutes == nil)
        #expect(extra.window.resetsAt == nil)
        #expect(extra.window.resetDescription == nil)
    }

    @Test
    func `unexpired trial without a percentage stays hidden`() throws {
        let status = try Self.decodeTrial(percent: "null")
        #expect(status.extraRateWindow(now: Self.now, resetDescription: { _ in "reset" }) == nil)
    }

    @Test
    func `unknown trial objects do not establish eligibility`() throws {
        let data = Data(#"{"usagePercent":13.55,"hasAvailableUsage":true,"sandTrial":{"active":true}}"#.utf8)
        let status = try JSONDecoder().decode(CursorSandUsageStatus.self, from: data)
        #expect(status.extraRateWindow(now: Self.now, resetDescription: { _ in "reset" }) == nil)
    }

    @Test
    func `legacy request plan still hides trial usage`() throws {
        let status = try Self.snapshot(sandUsage: Self.decodeTrial(), requestsUsed: 1, requestsLimit: 50)
        let snapshot = status.toUsageSnapshot(now: Self.now)
        #expect(snapshot.primary?.usedPercent == 2)
        #expect(snapshot.extraRateWindows == nil)
    }

    @Test(arguments: [13.55, 100.0])
    func `trial fetch preserves monthly usage without creating weekly semantics`(percent: Double) async throws {
        // Synthetic REST fixture: the native Grok Bot protocol confirms the field and lifecycle,
        // but a trial response from the web endpoint still needs independent verification.
        let session = CursorStatusProbeTestSession { request in
            let url = try #require(request.url)
            switch url.path {
            case "/api/usage-summary":
                return makeCursorStatusProbeResponse(
                    url: url,
                    body: """
                    {"membershipType":"pro","individualUsage":{"plan":{"used":0,"limit":2000,"totalPercentUsed":0}}}
                    """,
                    statusCode: 200)
            case "/api/auth/me":
                return makeCursorStatusProbeResponse(url: url, body: "{}", statusCode: 200)
            case CursorSandUsageStatus.endpointPath:
                return makeCursorStatusProbeResponse(
                    url: url,
                    body: Self.trialJSON(percent: String(percent), available: percent < 100),
                    statusCode: 200)
            default:
                throw URLError(.badURL)
            }
        }
        let status = try await CursorStatusProbe(
            baseURL: #require(URL(string: "https://cursor.test")),
            browserDetection: BrowserDetection(cacheTTL: 0),
            urlSession: session.urlSession).fetchWithManualCookies("auth=test")
        let snapshot = status.toUsageSnapshot(now: Self.now)
        let extra = try #require(snapshot.extraRateWindows?.first)

        #expect(snapshot.primary?.usedPercent == 0)
        #expect(snapshot.loginMethod(for: .cursor) == "Cursor Pro")
        #expect(extra.window.usedPercent == percent)
        #expect(ProviderUsagePresentation.standardSemanticWindows(snapshot: snapshot).weekly == nil)
        #expect(ProviderUsagePresentation.standardPlanUtilizationSeries(snapshot: snapshot) == nil)
        #expect(UsageFormatter.resetLine(for: extra.window, style: .countdown, now: Self.now) == nil)
    }

    @Test(arguments: [13.55, 100.0])
    func `automatic metric respects usable monthly subquota alongside trial`(percent: Double) throws {
        let snapshot = try Self.snapshot(sandUsage: Self.decodeTrial(percent: String(percent)))
            .toUsageSnapshot(now: Self.now)
        let selected = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .cursor,
            snapshot: snapshot,
            supportsAverage: false,
            now: Self.now)
        #expect(selected?.usedPercent == (percent < 100 ? percent : 0))
    }

    @Test
    func `trial card retains percentage without promising a reset`() throws {
        let snapshot = try Self.snapshot(sandUsage: Self.decodeTrial()).toUsageSnapshot(now: Self.now)
        let model = try UsageMenuCardView.Model.make(.init(
            provider: .cursor,
            metadata: #require(ProviderDefaults.metadata[.cursor]),
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: Self.now))

        #expect(model.metrics.map(\.title) == ["Total", "Cursor", "Third Party", "Grok Bot"])
        #expect(model.metrics.last?.percentLabel == "86% left")
        #expect(model.metrics.last?.resetText == nil)
    }

    private static func decodeTrial(
        expiry: String = "\"2026-09-14T00:00:00Z\"",
        percent: String = "13.55",
        available: Bool = true,
        included: Bool = false) throws -> CursorSandUsageStatus
    {
        try JSONDecoder().decode(CursorSandUsageStatus.self, from: Data(self.trialJSON(
            expiry: expiry, percent: percent, available: available, included: included).utf8))
    }

    private static func trialJSON(
        expiry: String = "\"2026-09-14T00:00:00Z\"",
        percent: String = "13.55",
        available: Bool = true,
        included: Bool = false) -> String
    {
        """
        {
          "currentPeriodStart": "2026-09-07T00:00:00Z",
          "nextResetTimestampUtc": "2026-09-14T00:00:00Z",
          "usagePercent": \(percent),
          "hasAvailableUsage": \(available),
          "hasNonZeroIncludedLimit": \(included),
          "sandTrialExpiresAt": \(expiry)
        }
        """
    }

    private static func snapshot(
        sandUsage: CursorSandUsageStatus,
        requestsUsed: Int? = nil,
        requestsLimit: Int? = nil) -> CursorStatusSnapshot
    {
        CursorStatusSnapshot(
            planPercentUsed: 0,
            autoPercentUsed: 0,
            apiPercentUsed: 0,
            planUsedUSD: 0,
            planLimitUSD: 20,
            onDemandUsedUSD: 0,
            onDemandLimitUSD: nil,
            teamOnDemandUsedUSD: nil,
            teamOnDemandLimitUSD: nil,
            billingCycleEnd: nil,
            membershipType: "pro",
            accountEmail: nil,
            accountName: nil,
            rawJSON: nil,
            sandUsage: sandUsage,
            requestsUsed: requestsUsed,
            requestsLimit: requestsLimit)
    }
}
