import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct AlibabaCodingPlanSettingsReaderTests {
    @Test
    func apiTokenReadsFromEnvironment() {
        let token = AlibabaCodingPlanSettingsReader.apiToken(environment: ["ALIBABA_CODING_PLAN_API_KEY": "abc123"])
        #expect(token == "abc123")
    }

    @Test
    func apiTokenStripsQuotes() {
        let token = AlibabaCodingPlanSettingsReader.apiToken(environment: ["ALIBABA_CODING_PLAN_API_KEY": "\"token-xyz\""])
        #expect(token == "token-xyz")
    }

    @Test
    func quotaURLInfersScheme() {
        let url = AlibabaCodingPlanSettingsReader
            .quotaURL(environment: [AlibabaCodingPlanSettingsReader.quotaURLKey: "modelstudio.console.alibabacloud.com/data/api.json"])
        #expect(url?.absoluteString == "https://modelstudio.console.alibabacloud.com/data/api.json")
    }

    @Test
    func missingCookieErrorIncludesAccessHintWhenPresent() {
        let error = AlibabaCodingPlanSettingsError.missingCookie(details: "Safari cookie file exists but is not readable.")
        #expect(error.errorDescription?.contains("Safari cookie file exists but is not readable.") == true)
    }
}

@Suite
struct AlibabaCodingPlanUsageSnapshotTests {
    @Test
    func mapsUsageSnapshotWindows() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset5h = Date(timeIntervalSince1970: 1_700_000_300)
        let resetWeek = Date(timeIntervalSince1970: 1_700_010_000)
        let resetMonth = Date(timeIntervalSince1970: 1_700_100_000)
        let snapshot = AlibabaCodingPlanUsageSnapshot(
            planName: "Pro",
            fiveHourUsedQuota: 20,
            fiveHourTotalQuota: 100,
            fiveHourNextRefreshTime: reset5h,
            weeklyUsedQuota: 120,
            weeklyTotalQuota: 400,
            weeklyNextRefreshTime: resetWeek,
            monthlyUsedQuota: 500,
            monthlyTotalQuota: 2000,
            monthlyNextRefreshTime: resetMonth,
            updatedAt: now)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 20)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.secondary?.usedPercent == 30)
        #expect(usage.secondary?.windowMinutes == 10_080)
        #expect(usage.tertiary?.usedPercent == 25)
        #expect(usage.tertiary?.windowMinutes == 43_200)
        #expect(usage.loginMethod(for: .alibaba) == "Pro")
    }

    @Test
    func shiftsPrimaryResetForwardWhenBackendResetIsNotFuture() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stalePrimaryReset = Date(timeIntervalSince1970: 1_699_999_900)
        let snapshot = AlibabaCodingPlanUsageSnapshot(
            planName: "Lite",
            fiveHourUsedQuota: 70,
            fiveHourTotalQuota: 1200,
            fiveHourNextRefreshTime: stalePrimaryReset,
            weeklyUsedQuota: 80,
            weeklyTotalQuota: 9000,
            weeklyNextRefreshTime: Date(timeIntervalSince1970: 1_700_010_000),
            monthlyUsedQuota: 80,
            monthlyTotalQuota: 18000,
            monthlyNextRefreshTime: Date(timeIntervalSince1970: 1_700_100_000),
            updatedAt: now)

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.resetsAt == stalePrimaryReset.addingTimeInterval(TimeInterval(5 * 60 * 60)))
    }
}

@Suite
struct AlibabaCodingPlanUsageParsingTests {
    @Test
    func parsesQuotaPayload() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {
          "data": {
            "codingPlanInstanceInfos": [
              { "planName": "Alibaba Coding Plan Pro" }
            ],
            "codingPlanQuotaInfo": {
              "per5HourUsedQuota": 52,
              "per5HourTotalQuota": 1000,
              "per5HourQuotaNextRefreshTime": 1700000300000,
              "perWeekUsedQuota": 800,
              "perWeekTotalQuota": 5000,
              "perWeekQuotaNextRefreshTime": 1700100000000,
              "perBillMonthUsedQuota": 1200,
              "perBillMonthTotalQuota": 20000,
              "perBillMonthQuotaNextRefreshTime": 1701000000000
            }
          },
          "status_code": 0
        }
        """

        let snapshot = try AlibabaCodingPlanUsageFetcher.parseUsageSnapshot(from: Data(json.utf8), now: now)

        #expect(snapshot.planName == "Alibaba Coding Plan Pro")
        #expect(snapshot.fiveHourUsedQuota == 52)
        #expect(snapshot.fiveHourTotalQuota == 1000)
        #expect(snapshot.weeklyTotalQuota == 5000)
        #expect(snapshot.monthlyTotalQuota == 20000)
        #expect(snapshot.fiveHourNextRefreshTime == Date(timeIntervalSince1970: 1_700_000_300))
    }

    @Test
    func missingQuotaDataFallsBackToActivePlanSnapshot() throws {
        let json = """
        {
          "data": {
            "codingPlanInstanceInfos": [
              { "planName": "Alibaba Coding Plan Pro" }
            ]
          },
          "status_code": 0
        }
        """

        let snapshot = try AlibabaCodingPlanUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))
        #expect(snapshot.planName == "Alibaba Coding Plan Pro")
        #expect(snapshot.fiveHourUsedQuota == 0)
        #expect(snapshot.fiveHourTotalQuota == 100)
    }

    @Test
    func parsesWrappedJSONStringPayload() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let inner = """
        {
          "data": {
            "codingPlanInstanceInfos": [
              {
                "planName": "Coding Plan Lite",
                "status": "VALID",
                "codingPlanQuotaInfo": {
                  "per5HourUsedQuota": 0,
                  "per5HourTotalQuota": 1000,
                  "per5HourQuotaNextRefreshTime": 1700000300000
                }
              }
            ]
          },
          "statusCode": 200
        }
        """
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "  ", with: "")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let wrapped = """
        {
          "successResponse": {
            "body": "\(inner)"
          }
        }
        """

        let snapshot = try AlibabaCodingPlanUsageFetcher.parseUsageSnapshot(from: Data(wrapped.utf8), now: now)

        #expect(snapshot.planName == "Coding Plan Lite")
        #expect(snapshot.fiveHourTotalQuota == 1000)
        #expect(snapshot.fiveHourUsedQuota == 0)
    }

    @Test
    func fallsBackToPlanUsageWhenQuotaBlockMissing() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {
          "data": {
            "codingPlanInstanceInfos": [
              {
                "planName": "Coding Plan Lite",
                "status": "VALID",
                "planUsage": "0%",
                "endTime": "2026-04-01 17:00"
              }
            ]
          },
          "status_code": 0
        }
        """

        let snapshot = try AlibabaCodingPlanUsageFetcher.parseUsageSnapshot(from: Data(json.utf8), now: now)

        #expect(snapshot.planName == "Coding Plan Lite")
        #expect(snapshot.fiveHourUsedQuota == 0)
        #expect(snapshot.fiveHourTotalQuota == 100)
        #expect(snapshot.fiveHourNextRefreshTime != nil)
    }

    @Test
    func fallsBackToActivePlanWhenQuotaAndUsageMissing() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {
          "data": {
            "codingPlanInstanceInfos": [
              {
                "planName": "Coding Plan Lite",
                "status": "VALID",
                "endTime": "2026-04-01 17:00"
              }
            ]
          },
          "status_code": 0
        }
        """

        let snapshot = try AlibabaCodingPlanUsageFetcher.parseUsageSnapshot(from: Data(json.utf8), now: now)

        #expect(snapshot.planName == "Coding Plan Lite")
        #expect(snapshot.fiveHourUsedQuota == 0)
        #expect(snapshot.fiveHourTotalQuota == 100)
    }

    @Test
    func doesNotFallbackForInactivePlanWithoutQuota() {
        let json = """
        {
          "data": {
            "codingPlanInstanceInfos": [
              {
                "planName": "Coding Plan Lite",
                "status": "EXPIRED"
              }
            ]
          },
          "status_code": 0
        }
        """

        #expect(throws: AlibabaCodingPlanUsageError.self) {
            try AlibabaCodingPlanUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))
        }
    }

    @Test
    func consoleNeedLoginPayloadMapsToLoginRequired() {
        let json = """
        {
          "code": "ConsoleNeedLogin",
          "message": "You need to log in.",
          "requestId": "abc",
          "successResponse": false
        }
        """

        #expect(throws: AlibabaCodingPlanUsageError.loginRequired) {
            try AlibabaCodingPlanUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))
        }
    }
}

@Suite
struct AlibabaCodingPlanRegionTests {
    @Test
    func defaultsToInternationalEndpoint() {
        let url = AlibabaCodingPlanUsageFetcher.resolveQuotaURL(region: .international, environment: [:])
        #expect(url.host == "modelstudio.console.alibabacloud.com")
        #expect(url.path == "/data/api.json")
    }

    @Test
    func usesChinaMainlandHost() {
        let url = AlibabaCodingPlanUsageFetcher.resolveQuotaURL(region: .chinaMainland, environment: [:])
        #expect(url.host == "bailian.console.aliyun.com")
    }

    @Test
    func hostOverrideWinsForQuotaURL() {
        let env = [AlibabaCodingPlanSettingsReader.hostKey: "custom.aliyun.com"]
        let url = AlibabaCodingPlanUsageFetcher.resolveQuotaURL(region: .international, environment: env)
        #expect(url.host == "custom.aliyun.com")
        #expect(url.path == "/data/api.json")
    }

    @Test
    func hostOverrideUsesSelectedRegionForQuotaURL() {
        let env = [AlibabaCodingPlanSettingsReader.hostKey: "custom.aliyun.com"]
        let url = AlibabaCodingPlanUsageFetcher.resolveQuotaURL(region: .chinaMainland, environment: env)
        #expect(url.host == "custom.aliyun.com")

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let currentRegion = components?.queryItems?.first(where: { $0.name == "currentRegionId" })?.value
        #expect(currentRegion == AlibabaCodingPlanAPIRegion.chinaMainland.currentRegionID)
    }

    @Test
    func bareHostOverrideBuildsConsoleDashboardURL() {
        let env = [AlibabaCodingPlanSettingsReader.hostKey: "custom.aliyun.com"]
        let url = AlibabaCodingPlanUsageFetcher.resolveConsoleDashboardURL(region: .international, environment: env)
        #expect(url.scheme == "https")
        #expect(url.host == "custom.aliyun.com")
        #expect(url.path == AlibabaCodingPlanAPIRegion.international.dashboardURL.path)

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let tab = components?.queryItems?.first(where: { $0.name == "tab" })?.value
        #expect(tab == "coding-plan")
    }

    @Test
    func quotaUrlOverrideBeatsHost() {
        let env = [AlibabaCodingPlanSettingsReader.quotaURLKey: "https://example.com/custom/quota"]
        let url = AlibabaCodingPlanUsageFetcher.resolveQuotaURL(region: .international, environment: env)
        #expect(url.absoluteString == "https://example.com/custom/quota")
    }
}

@Suite(.serialized)
struct AlibabaCodingPlanUsageFetcherRequestTests {
    @Test
    func api401MapsToInvalidCredentials() async throws {
        let registered = URLProtocol.registerClass(AlibabaUsageFetcherStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(AlibabaUsageFetcherStubURLProtocol.self)
            }
            AlibabaUsageFetcherStubURLProtocol.handler = nil
        }

        AlibabaUsageFetcherStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            return Self.makeResponse(url: url, body: #"{"message":"unauthorized"}"#, statusCode: 401)
        }

        await #expect(throws: AlibabaCodingPlanUsageError.invalidCredentials) {
            _ = try await AlibabaCodingPlanUsageFetcher.fetchUsage(
                apiKey: "cpk-test",
                region: .chinaMainland,
                environment: [AlibabaCodingPlanSettingsReader.quotaURLKey: "https://alibaba-api.test/data/api.json"])
        }
    }

    private static func makeResponse(url: URL, body: String, statusCode: Int) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (response, Data(body.utf8))
    }
}

final class AlibabaUsageFetcherStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "alibaba-api.test"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
