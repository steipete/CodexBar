import Foundation
import Testing
@testable import CodexBarCore

struct AntigravityQuotaSourceParityTests {
    /// #2427 supplies the grouped response; #3789 supplies the weekly-only Starter values.
    private static func summary(starter: Bool) -> [String: Any] {
        let families = [("Gemini Models", "gemini"), ("Claude and GPT models", "3p")]
        let groups: [[String: Any]] = families.map { title, id in
            var buckets: [[String: Any]] = [[
                "bucketId": "\(id)-weekly", "displayName": "Weekly Limit", "window": "weekly",
                "remainingFraction": starter ? 1.0 : 0.958,
            ]]
            if !starter {
                buckets.append([
                    "bucketId": "\(id)-5h", "displayName": "Five Hour Limit", "window": "5h",
                    "remainingFraction": 0.749, "resetTime": "2026-07-23T17:05:10Z",
                ])
            }
            return ["displayName": title, "buckets": buckets]
        }
        return ["groups": groups]
    }

    @Test(arguments: [true, false])
    func `OAuth preserves the same grouped quotas as local and print sources`(starter: Bool) async throws {
        let credentials = AntigravityOAuthCredentials(
            accessToken: "synthetic-token",
            refreshToken: nil,
            expiryDate: Date().addingTimeInterval(3600),
            idToken: nil,
            email: "quota@example.com",
            projectID: "synthetic-project")
        let token = try AntigravityOAuthCredentialsStore.tokenAccountValue(for: credentials)
        let summaryData = try JSONSerialization.data(withJSONObject: Self.summary(starter: starter))
        let fetcher = AntigravityRemoteUsageFetcher(
            homeDirectory: "/synthetic-antigravity-home",
            environment: [AntigravityOAuthCredentialsStore.environmentCredentialsKey: token],
            dataLoader: GeminiAPITestHelpers.dataLoader { request in
                let url = try #require(request.url)
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token")
                let body: Data
                switch url.path {
                case "/v1internal:loadCodeAssist":
                    body = GeminiAPITestHelpers.jsonData([
                        "currentTier": ["id": starter ? "free-tier" : "standard-tier"],
                    ])
                case "/v1internal:retrieveUserQuotaSummary":
                    let posted = try #require(request.httpBody)
                    let project = try JSONSerialization.jsonObject(with: posted) as? [String: String]
                    #expect(project?["project"] == "synthetic-project")
                    body = summaryData
                default:
                    // The old model endpoint loses all weekly/5h cadence information.
                    body = GeminiAPITestHelpers.jsonData(["models": [
                        "gemini-2.5-pro": ["quotaInfo": ["remainingFraction": 0.749]],
                    ]])
                }
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 200, body: body)
            })
        let remote = try await fetcher.fetch()
        let local = try AntigravityStatusProbe.parseQuotaSummaryResponse(summaryData)
        let report = try JSONSerialization.data(withJSONObject: [
            "status": "SUCCESS", "command": ["name": "usage", "data": Self.summary(starter: starter)],
        ])
        let cli = try AntigravityStatusProbe.parseCLIUsageReport(report)
        let localUsage = try local.toUsageSnapshot()
        let cliUsage = try cli.toUsageSnapshot()
        let usage = try AntigravityOAuthFetchStrategy.usageSnapshot(from: remote)
        let windows = try #require(usage.extraRateWindows)
        #expect(windows.count == (starter ? 2 : 4))
        #expect(windows == localUsage.extraRateWindows)
        #expect(windows == cliUsage.extraRateWindows)
        #expect(remote.source == .remote)
        #expect(usage.identity?.accountEmail == "quota@example.com")
        #expect(usage.identity?.loginMethod == (starter ? "Free" : "Paid"))
        #expect(usage.secondary != nil)
        if starter {
            #expect(windows.map(\.window.windowMinutes) == [10080, 10080])
            #expect(windows.map(\.window.remainingPercent) == [100, 100])
            #expect(AntigravityQuotaFamilyVisibility.idleWindowIDs(in: usage).isEmpty)
        }
    }

    @Test(arguments: ["weekly", "5h"])
    func `summary honors explicit cadence for opaque bucket IDs`(cadence: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["groups": [[
            "displayName": "Gemini Models", "buckets": [[
                "bucketId": "gemini-allowance", "displayName": "Limit Remaining",
                "window": cadence, "remainingFraction": 1,
            ]],
        ]]])
        let usage = try AntigravityStatusProbe.parseQuotaSummaryResponse(data).toUsageSnapshot()
        let window = try #require(usage.extraRateWindows?.first)
        #expect(window.id == "antigravity-quota-summary-gemini-allowance")
        #expect(window.title == (cadence == "weekly" ? "Gemini weekly" : "Gemini 5-hour"))
        #expect(window.window.windowMinutes == (cadence == "weekly" ? 10080 : 300))
    }

    @Test(arguments: ["weekly", "unknown"])
    func `explicit cadence takes precedence over legacy bucket names`(cadence: String) throws {
        let data = Data("""
        {"groups":[{"displayName":"Gemini Models","buckets":[{
          "bucketId":"gemini-5h","displayName":"Five Hour Limit",
          "window":"\(cadence)","remainingFraction":0.8
        }]}]}
        """.utf8)
        let usage = try AntigravityStatusProbe.parseQuotaSummaryResponse(data).toUsageSnapshot()
        #expect(usage.extraRateWindows?.first?.window.windowMinutes == (cadence == "weekly" ? 10080 : nil))
    }

    @Test(arguments: [200, 401, 403, 404, 500, -1])
    func `summary fallback preserves authentication and cancellation errors`(statusCode: Int) async throws {
        let credentials = AntigravityOAuthCredentials(
            accessToken: "synthetic-token",
            refreshToken: nil,
            expiryDate: nil,
            email: "quota@example.com",
            projectID: "synthetic-project")
        let token = try AntigravityOAuthCredentialsStore.tokenAccountValue(for: credentials)
        let fetcher = AntigravityRemoteUsageFetcher(
            homeDirectory: "/synthetic-antigravity-home",
            environment: [AntigravityOAuthCredentialsStore.environmentCredentialsKey: token],
            dataLoader: GeminiAPITestHelpers.dataLoader { request in
                let url = try #require(request.url)
                switch url.path {
                case "/v1internal:loadCodeAssist":
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString, status: 200, body: Data("{}".utf8))
                case "/v1internal:retrieveUserQuotaSummary":
                    #expect(request.timeoutInterval <= 2)
                    if statusCode == -1 { throw CancellationError() }
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString, status: statusCode, body: Data(#"{"buckets":[]}"#.utf8))
                default:
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.jsonData(["models": [
                            "gemini-2.5-pro": ["quotaInfo": ["remainingFraction": 0.5]],
                        ]]))
                }
            })
        if statusCode == 401 {
            await #expect(throws: AntigravityRemoteFetchError.notLoggedIn) { try await fetcher.fetch() }
        } else if statusCode == -1 {
            await #expect(throws: CancellationError.self) { try await fetcher.fetch() }
        } else {
            let snapshot = try await fetcher.fetch()
            let usage = try snapshot.toUsageSnapshot()
            #expect(usage.primary?.remainingPercent == 50)
            #expect(usage.identity?.accountEmail == "quota@example.com")
            #expect(snapshot.quotaSummary == nil)
        }
    }
}
