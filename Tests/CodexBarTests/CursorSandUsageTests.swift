import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CursorSandUsageTests {
    @Test
    func `parses sand usage status`() throws {
        let json = """
        {
            "currentPeriodStart": "2026-08-17T07:57:50.647Z",
            "nextResetTimestampUtc": "2026-08-24T07:57:50.647Z",
            "usagePercent": 100,
            "hasAvailableUsage": true,
            "includedLimitZero": false
        }
        """
        let data = try #require(json.data(using: .utf8))
        let status = try JSONDecoder().decode(CursorSandUsageStatus.self, from: data)

        #expect(status.usagePercent == 100)
        #expect(status.hasAvailableUsage == true)
        #expect(status.includedLimitZero == false)
        let window = try #require(status.extraRateWindow(resetDescription: { _ in "Resets" }))
        #expect(window.id == CursorSandUsageStatus.extraWindowID)
        #expect(window.title == "Grok Bot")
        #expect(window.window.usedPercent == 100)
        #expect(window.window.windowMinutes == 10080)
        #expect(window.window.resetsAt != nil)
    }

    @Test
    func `hides grok bot extra window without an included limit`() {
        let status = CursorSandUsageStatus(
            currentPeriodStart: "2026-08-17T07:57:50.647Z",
            nextResetTimestampUtc: "2026-08-24T07:57:50.647Z",
            usagePercent: 100,
            hasAvailableUsage: false,
            includedLimitZero: true)
        #expect(status.extraRateWindow(resetDescription: { _ in "Resets" }) == nil)
    }

    @Test(arguments: [12.3, 100.0])
    func `reported trial schema keeps available and exhausted usage without recurring reset`(used: Double) throws {
        let status = try Self.status(expiry: "2026-09-21T09:12:32.776Z", used: used)
        let window = try #require(status.extraRateWindow(now: Self.now, resetDescription: { _ in "Resets" }))
        #expect(window.window.usedPercent == used)
        #expect(window.window.windowMinutes == nil)
        #expect(window.window.resetsAt == nil)
        #expect(window.window.resetDescription == nil)
    }

    @Test(arguments: [nil, "", "not-a-date", "2026-09-14T00:00:00Z", "2026-09-13T23:59:59.999Z"])
    func `missing malformed and expired trials require a paid allowance`(expiry: String?) throws {
        let trial = try Self.status(expiry: expiry)
        #expect(trial.extraRateWindow(now: Self.now, resetDescription: { _ in "Resets" }) == nil)
        let paid = try Self.status(expiry: expiry, includedLimitZero: false)
        let window = try #require(paid.extraRateWindow(now: Self.now, resetDescription: { _ in "Resets" }))
        #expect(window.window.windowMinutes == 10080)
        #expect(window.window.resetsAt != nil)
    }

    @Test
    func `trial without percentage remains unavailable`() throws {
        let status = try Self.status(expiry: "2026-09-21T09:12:32.776Z", used: nil)
        #expect(status.extraRateWindow(now: Self.now, resetDescription: { _ in "Resets" }) == nil)
    }

    @Test
    func `current allowance field wins while released API and old payload stay readable`() throws {
        let oldPayload = Data(#"{"hasNonZeroIncludedLimit":true,"usagePercent":42}"#.utf8)
        let old = try JSONDecoder().decode(CursorSandUsageStatus.self, from: oldPayload)
        #expect(old.extraRateWindow(resetDescription: { _ in "Resets" })?.window.usedPercent == 42)
        let status = CursorSandUsageStatus(
            currentPeriodStart: nil,
            nextResetTimestampUtc: nil,
            usagePercent: 42,
            hasAvailableUsage: true,
            hasNonZeroIncludedLimit: true)
        #expect(status.hasNonZeroIncludedLimit == true)
        #expect(status.extraRateWindow(resetDescription: { _ in "Resets" })?.window.usedPercent == 42)
        let conflicting = Data(#"{"hasNonZeroIncludedLimit":true,"includedLimitZero":true,"usagePercent":42}"#.utf8)
        let current = try JSONDecoder().decode(CursorSandUsageStatus.self, from: conflicting)
        #expect(current.extraRateWindow(resetDescription: { _ in "Resets" }) == nil)
    }

    @Test(arguments: [true, false])
    func `paid allowance preserves timing even with a future trial expiry`(hasTrial: Bool) {
        let snapshot = CursorStatusSnapshot(
            planPercentUsed: 0.6,
            autoPercentUsed: 0.75,
            apiPercentUsed: 0,
            planUsedUSD: 14.99,
            planLimitUSD: 400.0,
            onDemandUsedUSD: 0,
            onDemandLimitUSD: nil,
            teamOnDemandUsedUSD: nil,
            teamOnDemandLimitUSD: nil,
            billingCycleEnd: nil,
            membershipType: "ultra",
            accountEmail: nil,
            accountName: nil,
            rawJSON: nil,
            sandUsage: CursorSandUsageStatus(
                currentPeriodStart: "2026-08-17T07:57:50.647Z",
                nextResetTimestampUtc: "2026-08-24T07:57:50.647Z",
                usagePercent: 100,
                hasAvailableUsage: true,
                includedLimitZero: false,
                sandTrialExpiresAt: hasTrial ? "2026-09-21T09:12:32.776Z" : nil))

        let usageSnapshot = snapshot.toUsageSnapshot(now: Self.now)
        let grokBot = usageSnapshot.extraRateWindows?.first { $0.id == CursorSandUsageStatus.extraWindowID }
        #expect(grokBot?.title == "Grok Bot")
        #expect(grokBot?.window.usedPercent == 100)
        #expect(grokBot?.window.windowMinutes == 10080)
        #expect(grokBot?.window.resetsAt != nil)
        #expect(usageSnapshot.updatedAt == Self.now)
        #expect(usageSnapshot.primary?.usedPercent == 0.6)
        #expect(usageSnapshot.secondary?.usedPercent == 0.75)
        #expect(usageSnapshot.tertiary?.usedPercent == 0)
    }

    @Test(arguments: [true, false])
    func `fetch maps paid and trial usage onto grok bot extra window`(isTrial: Bool) async throws {
        let testSession = CursorStatusProbeTestSession { request in
            let requestURL = try #require(request.url)

            switch requestURL.path {
            case "/api/usage-summary":
                #expect(request.timeoutInterval == 15)
                return makeCursorStatusProbeResponse(
                    url: requestURL,
                    body: """
                    {
                      "membershipType": "ultra",
                      "individualUsage": {
                        "plan": {
                          "used": 1499,
                          "limit": 40000,
                          "totalPercentUsed": 0.6
                        }
                      }
                    }
                    """,
                    statusCode: 200)
            case "/api/auth/me":
                return makeCursorStatusProbeResponse(
                    url: requestURL,
                    body: #"{"error":"nope"}"#,
                    statusCode: 500)
            case "/api/dashboard/get-sand-usage-status":
                #expect(request.httpMethod == "POST")
                #expect(request.timeoutInterval == 5)
                #expect(request.value(forHTTPHeaderField: "Origin") == "https://cursor.test")
                #expect(request.value(forHTTPHeaderField: "Cookie") == "auth=test")
                return makeCursorStatusProbeResponse(
                    url: requestURL,
                    body: """
                    {
                      "currentPeriodStart": "2026-09-14T09:12:32.776Z",
                      "nextResetTimestampUtc": "2026-09-21T09:12:32.776Z",
                      "usagePercent": 100,
                      "hasAvailableUsage": true,
                      "includedLimitZero": \(isTrial ? "true" : "false"),
                      "sandTrialExpiresAt": "2026-09-21T09:12:32.776Z"
                    }
                    """,
                    statusCode: 200)
            default:
                throw URLError(.badURL)
            }
        }

        let baseURL = try #require(URL(string: "https://cursor.test"))
        let snapshot = try await CursorStatusProbe(
            baseURL: baseURL,
            browserDetection: BrowserDetection(cacheTTL: 0),
            urlSession: testSession.urlSession).fetchWithManualCookies("auth=test")

        #expect(snapshot.sandUsage?.usagePercent == 100)
        #expect(snapshot.sandUsage?.includedLimitZero == isTrial)
        let grokBot = snapshot.toUsageSnapshot(now: Self.now).extraRateWindows?.first {
            $0.id == CursorSandUsageStatus.extraWindowID
        }
        #expect(grokBot?.window.usedPercent == 100)
        #expect(grokBot?.window.windowMinutes == (isTrial ? nil : 10080))
        #expect((grokBot?.window.resetsAt == nil) == isTrial)
        #expect(snapshot.rawJSON?.contains("get-sand-usage-status") == true)
    }

    @Test
    func `mid-week period start keeps the weekly grok bot window`() throws {
        let status = CursorSandUsageStatus(
            currentPeriodStart: "2026-10-02T18:03:04Z",
            nextResetTimestampUtc: "2026-10-05T11:20:04Z",
            usagePercent: 44.935,
            hasAvailableUsage: true,
            includedLimitZero: false)
        let now = try #require(ISO8601DateParser.parse("2026-10-03T00:02:00Z"))
        let window = try #require(status.extraRateWindow(now: now, resetDescription: { _ in "Resets" }))
        let start = try #require(ISO8601DateParser.parse(status.currentPeriodStart))
        let reset = try #require(ISO8601DateParser.parse(status.nextResetTimestampUtc))
        #expect(CursorSandUsageStatus.windowMinutes(start: start, end: reset) == 3917)
        #expect(window.window.usedPercent == 44.935)
        #expect(window.window.resetsAt == reset)
        #expect(window.window.windowMinutes == 10080)
        let pace = try #require(UsagePace.weekly(window: window.window, now: now))
        #expect(abs(pace.expectedUsedPercent - 64.702) < 0.001)
        #expect(abs(pace.deltaPercent + 19.767) < 0.001)
        #expect(pace.willLastToReset)
    }

    @Test(arguments: [nil, "not-a-date", "2026-09-27T11:20:04Z", "2026-10-05T11:20:04Z", "2026-10-06T11:20:04Z"])
    func `paid weekly cadence does not depend on the reported start`(start: String?) {
        let status = CursorSandUsageStatus(
            currentPeriodStart: start,
            nextResetTimestampUtc: "2026-10-05T11:20:04Z",
            usagePercent: 10,
            hasAvailableUsage: true,
            includedLimitZero: false)
        let window = status.extraRateWindow(now: Self.now, resetDescription: { _ in "Resets" })
        #expect(window?.window.windowMinutes == 10080)
    }

    @Test(arguments: [nil, "not-a-date"])
    func `paid allowance without a reset has no pace window`(reset: String?) throws {
        let status = CursorSandUsageStatus(
            currentPeriodStart: "2026-10-02T18:03:04Z",
            nextResetTimestampUtc: reset,
            usagePercent: 44.935,
            hasAvailableUsage: true,
            includedLimitZero: false)
        let window = try #require(status.extraRateWindow(resetDescription: { _ in "Resets" }))
        #expect(window.window.windowMinutes == nil)
        #expect(window.window.resetsAt == nil)
        #expect(window.window.resetDescription == nil)
    }

    @Test(arguments: [true, false])
    func `x subscription shared weekly pool replaces stale monthly lanes`(isUnified: Bool) async throws {
        // Responses reported in #4545, captured from one Enterprise account on The X Subscription.
        let testSession = CursorStatusProbeTestSession { request in
            let requestURL = try #require(request.url)
            switch requestURL.path {
            case "/api/usage-summary":
                return makeCursorStatusProbeResponse(url: requestURL, body: Self.xSubscriptionSummary, statusCode: 200)
            case "/api/auth/me":
                return makeCursorStatusProbeResponse(url: requestURL, body: #"{"error":"nope"}"#, statusCode: 500)
            case "/api/dashboard/get-sand-usage-status":
                return makeCursorStatusProbeResponse(
                    url: requestURL,
                    body: Self.xSubscriptionSandStatus(isUnified: isUnified),
                    statusCode: 200)
            default:
                throw URLError(.badURL)
            }
        }

        let baseURL = try #require(URL(string: "https://cursor.test"))
        let snapshot = try await CursorStatusProbe(
            baseURL: baseURL,
            browserDetection: BrowserDetection(cacheTTL: 0),
            urlSession: testSession.urlSession).fetchWithManualCookies("auth=test")
        let now = try #require(ISO8601DateParser.parse("2026-10-16T06:50:00Z"))
        let usage = snapshot.toUsageSnapshot(now: now)
        let descriptor = CursorProviderDescriptor.descriptor
        let labels = descriptor.presentation.rateWindowLabels(metadata: descriptor.metadata, snapshot: usage)
        let weeklyReset = try #require(ISO8601DateParser.parse("2026-10-22T10:27:36.178Z"))

        #expect(snapshot.sandUsage?.isUnified == isUnified)
        #expect(usage.providerCost?.used == 4.47)
        #expect(usage.providerCost?.period == "Monthly")
        if isUnified {
            let primary = try #require(usage.primary)
            #expect(abs(primary.usedPercent - 10.205850487540628) < 0.000001)
            #expect(primary.windowMinutes == 10080)
            #expect(primary.resetsAt == weeklyReset)
            #expect(usage.secondary == nil)
            #expect(usage.tertiary == nil)
            #expect(usage.extraRateWindows == nil)
            #expect(labels.primary == "Weekly")
            #expect(descriptor.presentation.semanticWindows(snapshot: usage).weekly == primary)
        } else {
            #expect(usage.primary?.usedPercent == 100)
            #expect(usage.secondary?.usedPercent == 62.860238353196095)
            #expect(usage.tertiary?.usedPercent == 0)
            #expect(usage.extraRateWindows?.first?.id == CursorSandUsageStatus.extraWindowID)
            #expect(labels.primary == "Total")
        }
    }

    @Test
    func `valid request quotas remain binding alongside a unified weekly feed`() throws {
        let now = try #require(ISO8601DateParser.parse("2026-10-16T06:50:00Z"))
        let sand = try JSONDecoder().decode(
            CursorSandUsageStatus.self, from: Data(Self.xSubscriptionSandStatus(isUnified: true).utf8))
        let snapshot = CursorStatusSnapshot(
            planPercentUsed: 0,
            planUsedUSD: 0,
            planLimitUSD: 0,
            onDemandUsedUSD: 0,
            onDemandLimitUSD: nil,
            teamOnDemandUsedUSD: nil,
            teamOnDemandLimitUSD: nil,
            billingCycleEnd: now.addingTimeInterval(30 * 86400),
            membershipType: "enterprise",
            accountEmail: nil,
            accountName: nil,
            rawJSON: nil,
            sandUsage: sand,
            requestsUsed: 250,
            requestsLimit: 500)
        let usage = snapshot.toUsageSnapshot(now: now)
        #expect(usage.primary?.usedPercent == 50)
        #expect(usage.detailRow(label: "Request quota")?.value == "250 / 500")
    }

    @Test(arguments: ["", "2020-01-01T00:00:00Z"])
    func `unified pools without a current weekly reset preserve monthly usage`(reset: String) throws {
        let sand = try JSONDecoder().decode(CursorSandUsageStatus.self, from: Data("""
        {"isUnified":true,"usagePercent":10,"hasNonZeroIncludedLimit":true,
         "nextResetTimestampUtc":"\(reset)"}
        """.utf8))
        let snapshot = CursorStatusSnapshot(
            planPercentUsed: 100,
            planUsedUSD: 10,
            planLimitUSD: 10,
            onDemandUsedUSD: 0,
            onDemandLimitUSD: nil,
            teamOnDemandUsedUSD: nil,
            teamOnDemandLimitUSD: nil,
            billingCycleEnd: Self.now.addingTimeInterval(30 * 86400),
            membershipType: "enterprise",
            accountEmail: nil,
            accountName: nil,
            rawJSON: nil,
            sandUsage: sand)
        #expect(snapshot.toUsageSnapshot(now: Self.now).primary?.usedPercent == 100)
    }

    private static let now = Date(timeIntervalSince1970: 1_789_344_000)

    private static func status(
        expiry: String?,
        used: Double? = 12.3,
        includedLimitZero: Bool = true) throws -> CursorSandUsageStatus
    {
        var payload: [String: Any] = [
            "currentPeriodStart": "2026-09-14T09:12:32.776Z",
            "nextResetTimestampUtc": "2026-09-21T09:12:32.776Z",
            "includedLimitZero": includedLimitZero,
            "hasAvailableUsage": used.map { $0 < 100 } ?? false,
        ]
        payload["sandTrialExpiresAt"] = expiry
        payload["usagePercent"] = used
        return try JSONDecoder().decode(
            CursorSandUsageStatus.self,
            from: JSONSerialization.data(withJSONObject: payload))
    }

    private static let xSubscriptionSummary = """
    {
      "billingCycleStart": "2026-10-01T00:00:00.000Z",
      "billingCycleEnd": "2026-11-01T00:00:00.000Z",
      "membershipType": "enterprise",
      "limitType": "team",
      "isUnlimited": false,
      "individualUsage": {
        "plan": {
          "enabled": true,
          "used": 4615,
          "limit": 4615,
          "remaining": 0,
          "breakdown": { "included": 4615, "bonus": 2288, "total": 6903 },
          "autoPercentUsed": 62.860238353196095,
          "apiPercentUsed": 0,
          "totalPercentUsed": 100
        },
        "onDemand": { "enabled": true, "used": 447, "limit": null, "remaining": null }
      },
      "teamUsage": {
        "onDemand": { "enabled": true, "used": 447, "limit": 0, "remaining": 0 }
      }
    }
    """

    private static func xSubscriptionSandStatus(isUnified: Bool) -> String {
        """
        {
          "currentPeriodStart": "2026-10-15T10:27:36.178Z",
          "nextResetTimestampUtc": "2026-10-22T10:27:36.178Z",
          "usagePercent": 10.205850487540628,
          "hasAvailableUsage": true,
          "hasNonZeroIncludedLimit": true,
          "onDemandSettings": {
            "visible": true,
            "eligible": true,
            "enabled": true,
            "dashboardUrl": "https://cursor.com/dashboard/spending?for=redacted"
          },
          "grokPlanLabel": "Grok Bot Plan",
          "cursorPlanName": "Premium",
          "isUnified": \(isUnified),
          "billingBrand": "SAND_BILLING_BRAND_GROK",
          "unifiedBillingUrl": "https://cursor.com/dashboard?tab=billing",
          "unifiedUpsellButtons": [
            { "label": "Buy Credits", "url": { "url": "https://cursor.com/dashboard?tab=billing" } }
          ]
        }
        """
    }
}
