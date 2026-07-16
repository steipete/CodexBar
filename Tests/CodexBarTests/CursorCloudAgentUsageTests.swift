import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CursorCloudAgentUsageTests {
    @Test
    func `aggregates cloud agent spend from usage events`() {
        let events = [
            CursorUsageEvent(
                timestamp: "1",
                model: "default",
                kind: "USAGE_EVENT_KIND_INCLUDED_IN_PRO",
                chargedCents: 1200,
                isChargeable: true,
                isHeadless: true,
                cloudAgentId: "bc-1",
                tokenUsage: nil),
            CursorUsageEvent(
                timestamp: "2",
                model: "claude-4",
                kind: "USAGE_EVENT_KIND_INCLUDED_IN_PRO",
                chargedCents: 800,
                isChargeable: true,
                isHeadless: false,
                cloudAgentId: nil,
                tokenUsage: nil),
            CursorUsageEvent(
                timestamp: "3",
                model: "default",
                kind: "USAGE_EVENT_KIND_ERRORED_NOT_CHARGED",
                chargedCents: 500,
                isChargeable: false,
                isHeadless: true,
                cloudAgentId: "bc-2",
                tokenUsage: nil),
            CursorUsageEvent(
                timestamp: "4",
                model: "default",
                kind: "USAGE_EVENT_KIND_USAGE_BASED",
                chargedCents: nil,
                isChargeable: true,
                isHeadless: true,
                cloudAgentId: "bc-3",
                tokenUsage: CursorUsageEventTokenUsage(totalCents: 300)),
        ]

        let usage = CursorCloudAgentUsageAggregator.aggregate(events: events)
        #expect(usage.usedUSD == 15.0) // 1200 + 300 cents
        #expect(usage.totalSpendUSD == 23.0) // 1200 + 800 + 300
        #expect(usage.eventCount == 2)
        #expect(abs(usage.usedPercent - (15.0 / 23.0 * 100)) < 0.0001)
    }

    @Test
    func `explicitly nonchargeable events do not contribute spend`() {
        let events = [
            CursorUsageEvent(
                timestamp: "1",
                model: "default",
                kind: "USAGE_EVENT_KIND_FUTURE_NONCHARGED",
                chargedCents: 999,
                isChargeable: false,
                isHeadless: true,
                cloudAgentId: "bc-1",
                tokenUsage: nil),
        ]

        let usage = CursorCloudAgentUsageAggregator.aggregate(events: events)
        #expect(usage.usedUSD == 0)
        #expect(usage.totalSpendUSD == 0)
        #expect(usage.eventCount == 0)
    }

    @Test
    func `cloud agent window projects as extra rate window`() throws {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = CursorStatusSnapshot(
            planPercentUsed: 40,
            autoPercentUsed: 20,
            apiPercentUsed: 60,
            planUsedUSD: 20,
            planLimitUSD: 20,
            onDemandUsedUSD: 1,
            onDemandLimitUSD: 50,
            teamOnDemandUsedUSD: nil,
            teamOnDemandLimitUSD: nil,
            billingCycleStart: Date(timeIntervalSince1970: 1_797_000_000),
            billingCycleEnd: reset,
            membershipType: "pro",
            accountEmail: "user@example.com",
            accountName: nil,
            rawJSON: nil,
            cloudAgentUsage: CursorCloudAgentUsage(usedUSD: 48.03, totalSpendUSD: 74.39, eventCount: 35))

        let usage = snapshot.toUsageSnapshot()
        let cloud = try #require(usage.extraRateWindows?.first)
        #expect(cloud.id == CursorCloudAgentUsage.windowID)
        #expect(cloud.title == "Cloud")
        #expect(abs(cloud.window.usedPercent - (48.03 / 74.39 * 100)) < 0.01)
        #expect(cloud.window.resetsAt == reset)
        #expect(usage.cursorCloudAgentUsage?.usedUSD == 48.03)
        #expect(usage.cursorCloudAgentUsage?.eventCount == 35)
    }

    @Test
    func `zero cloud spend omits cloud rate window`() {
        let snapshot = CursorStatusSnapshot(
            planPercentUsed: 10,
            planUsedUSD: 2,
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
            cloudAgentUsage: CursorCloudAgentUsage(usedUSD: 0, totalSpendUSD: 5, eventCount: 0))

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.extraRateWindows == nil)
        #expect(usage.cursorCloudAgentUsage?.usedUSD == 0)
    }

    @Test
    func `billing cycle milliseconds conversion`() {
        #expect(
            CursorStatusProbe.billingCycleMillisecondsString("2026-06-20T02:07:06.000Z")
                == "1781921226000")
        #expect(CursorStatusProbe.billingCycleMillisecondsString(nil) == nil)
    }

    @Test
    func `fetch aggregates cloud agent usage from dashboard events`() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CursorStatusProbeStubURLProtocol.self]
        let sessionID = CursorStatusProbeStubURLProtocol.configure(config) { request in
            let requestURL = try #require(request.url)
            switch requestURL.path {
            case "/api/usage-summary":
                return Self.makeResponse(
                    url: requestURL,
                    body: """
                    {
                      "membershipType": "pro",
                      "billingCycleStart": "2026-06-20T02:07:06.000Z",
                      "billingCycleEnd": "2026-07-20T02:07:06.000Z",
                      "individualUsage": {
                        "plan": {
                          "used": 2000,
                          "limit": 2000,
                          "totalPercentUsed": 38.0,
                          "autoPercentUsed": 18.0,
                          "apiPercentUsed": 100.0
                        },
                        "onDemand": {
                          "used": 17,
                          "limit": 5000
                        }
                      }
                    }
                    """)
            case "/api/auth/me":
                return Self.makeResponse(
                    url: requestURL,
                    body: #"{"email":"user@example.com","name":"Test"}"#)
            case "/api/dashboard/get-filtered-usage-events":
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Origin") == "https://cursor.com")
                if let body = request.httpBody,
                   let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
                {
                    #expect(json["teamId"] as? Int == 0)
                    #expect(json["startDate"] as? String == "1781921226000")
                    #expect(json["endDate"] as? String == "1784513226000")
                }
                return Self.makeResponse(
                    url: requestURL,
                    body: """
                    {
                      "totalUsageEventsCount": 2,
                      "usageEventsDisplay": [
                        {
                          "timestamp": "1",
                          "model": "default",
                          "kind": "USAGE_EVENT_KIND_INCLUDED_IN_PRO",
                          "chargedCents": 4803,
                          "isHeadless": true,
                          "cloudAgentId": "bc-1"
                        },
                        {
                          "timestamp": "2",
                          "model": "claude-4",
                          "kind": "USAGE_EVENT_KIND_INCLUDED_IN_PRO",
                          "chargedCents": 2636,
                          "isHeadless": false
                        }
                      ]
                    }
                    """)
            default:
                throw URLError(.badURL)
            }
        }
        defer { CursorStatusProbeStubURLProtocol.removeSession(sessionID) }

        let urlSession = URLSession(configuration: config)
        defer { urlSession.invalidateAndCancel() }

        let baseURL = try #require(URL(string: "https://cursor.test"))
        let snapshot = try await CursorStatusProbe(
            baseURL: baseURL,
            browserDetection: BrowserDetection(cacheTTL: 0),
            urlSession: urlSession).fetchWithManualCookies("auth=test")

        let cloud = try #require(snapshot.cloudAgentUsage)
        #expect(cloud.usedUSD == 48.03)
        #expect(cloud.totalSpendUSD == 74.39)
        #expect(cloud.eventCount == 1)
        #expect(abs(cloud.usedPercent - (48.03 / 74.39 * 100)) < 0.01)

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.extraRateWindows?.first?.id == CursorCloudAgentUsage.windowID)
        #expect(usage.cursorCloudAgentUsage?.usedUSD == 48.03)
    }

    private static func makeResponse(url: URL, body: String, statusCode: Int = 200) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        return (response, Data(body.utf8))
    }
}
