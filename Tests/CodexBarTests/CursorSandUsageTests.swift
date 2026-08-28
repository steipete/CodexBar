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
            "hasNonZeroIncludedLimit": true
        }
        """
        let data = try #require(json.data(using: .utf8))
        let status = try JSONDecoder().decode(CursorSandUsageStatus.self, from: data)

        #expect(status.usagePercent == 100)
        #expect(status.hasAvailableUsage == true)
        #expect(status.hasNonZeroIncludedLimit == true)
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
            hasNonZeroIncludedLimit: false)
        #expect(status.extraRateWindow(resetDescription: { _ in "Resets" }) == nil)
    }

    @Test
    func `maps sand usage onto a grok bot extra window`() {
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
                hasNonZeroIncludedLimit: true))

        let usageSnapshot = snapshot.toUsageSnapshot()
        let grokBot = usageSnapshot.extraRateWindows?.first { $0.id == CursorSandUsageStatus.extraWindowID }
        #expect(grokBot?.title == "Grok Bot")
        #expect(grokBot?.window.usedPercent == 100)
        #expect(grokBot?.window.windowMinutes == 10080)
        #expect(grokBot?.window.resetsAt != nil)
    }

    @Test
    func `fetch maps sand usage status onto grok bot extra window`() async throws {
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
                      "currentPeriodStart": "2026-08-17T07:57:50.647Z",
                      "nextResetTimestampUtc": "2026-08-24T07:57:50.647Z",
                      "usagePercent": 100,
                      "hasAvailableUsage": true,
                      "hasNonZeroIncludedLimit": true
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
        #expect(snapshot.sandUsage?.hasNonZeroIncludedLimit == true)
        let grokBot = snapshot.toUsageSnapshot().extraRateWindows?.first {
            $0.id == CursorSandUsageStatus.extraWindowID
        }
        #expect(grokBot?.window.usedPercent == 100)
        #expect(grokBot?.window.windowMinutes == 10080)
        #expect(snapshot.rawJSON?.contains("get-sand-usage-status") == true)
    }
}
