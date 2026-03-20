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
        let token = AlibabaCodingPlanSettingsReader
            .apiToken(environment: ["ALIBABA_CODING_PLAN_API_KEY": "\"token-xyz\""])
        #expect(token == "token-xyz")
    }

    @Test
    func quotaURLInfersScheme() {
        let url = AlibabaCodingPlanSettingsReader
            .quotaURL(environment: [AlibabaCodingPlanSettingsReader
                    .quotaURLKey: "modelstudio.console.alibabacloud.com/data/api.json"])
        #expect(url?.absoluteString == "https://modelstudio.console.alibabacloud.com/data/api.json")
    }

    @Test
    func missingCookieErrorIncludesAccessHintWhenPresent() {
        let error = AlibabaCodingPlanSettingsError
            .missingCookie(details: "Safari cookie file exists but is not readable.")
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
        #expect(usage.secondary?.windowMinutes == 10080)
        #expect(usage.tertiary?.usedPercent == 25)
        #expect(usage.tertiary?.windowMinutes == 43200)
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
    func multiInstanceQuotaPayloadUsesSelectedActiveInstancePlanName() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {
          "data": {
            "codingPlanInstanceInfos": [
              {
                "planName": "Expired Starter",
                "status": "EXPIRED",
                "endTime": "2025-04-01 17:00",
                "codingPlanQuotaInfo": {
                  "per5HourUsedQuota": 7,
                  "per5HourTotalQuota": 100,
                  "per5HourQuotaNextRefreshTime": 1700000100000
                }
              },
              {
                "planName": "Active Pro",
                "status": "VALID",
                "codingPlanQuotaInfo": {
                  "per5HourUsedQuota": 52,
                  "per5HourTotalQuota": 1000,
                  "per5HourQuotaNextRefreshTime": 1700000300000
                }
              }
            ]
          },
          "status_code": 0
        }
        """

        let snapshot = try AlibabaCodingPlanUsageFetcher.parseUsageSnapshot(from: Data(json.utf8), now: now)

        #expect(snapshot.planName == "Active Pro")
        #expect(snapshot.fiveHourUsedQuota == 52)
        #expect(snapshot.fiveHourTotalQuota == 1000)
        #expect(snapshot.fiveHourNextRefreshTime == Date(timeIntervalSince1970: 1_700_000_300))
    }

    @Test
    func missingQuotaDataWithoutPositiveActiveSignalFails() {
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

        #expect(throws: AlibabaCodingPlanUsageError.self) {
            try AlibabaCodingPlanUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))
        }
    }

    @Test
    func planUsageWithoutPositiveActiveProofFails() {
        let json = """
        {
          "data": {
            "codingPlanInstanceInfos": [
              {
                "planName": "Alibaba Coding Plan Pro",
                "planUsage": "18%"
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
    func planUsageFallbackStaysVisibleButNonQuantitative() throws {
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
        #expect(snapshot.fiveHourUsedQuota == nil)
        #expect(snapshot.fiveHourTotalQuota == nil)
        #expect(snapshot.fiveHourNextRefreshTime == nil)

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.loginMethod(for: .alibaba) == "Coding Plan Lite")
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
        #expect(snapshot.fiveHourUsedQuota == nil)
        #expect(snapshot.fiveHourTotalQuota == nil)

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.loginMethod(for: .alibaba) == "Coding Plan Lite")
    }

    @Test
    func futureEndTimeCountsAsPositiveActiveSignal() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {
          "data": {
            "codingPlanInstanceInfos": [
              {
                "planName": "Coding Plan Lite",
                "endTime": "2030-04-01 17:00"
              }
            ]
          },
          "status_code": 0
        }
        """

        let snapshot = try AlibabaCodingPlanUsageFetcher.parseUsageSnapshot(from: Data(json.utf8), now: now)

        #expect(snapshot.planName == "Coding Plan Lite")
        #expect(snapshot.fiveHourUsedQuota == nil)
        #expect(snapshot.weeklyTotalQuota == nil)

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.loginMethod(for: .alibaba) == "Coding Plan Lite")
    }

    @Test
    func multiInstanceFallbackUsesSelectedActiveInstancePlanName() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {
          "data": {
            "codingPlanInstanceInfos": [
              {
                "planName": "Expired Starter",
                "status": "EXPIRED",
                "endTime": "2025-04-01 17:00"
              },
              {
                "planName": "Active Pro",
                "status": "VALID",
                "planUsage": "42%"
              }
            ]
          },
          "status_code": 0
        }
        """

        let snapshot = try AlibabaCodingPlanUsageFetcher.parseUsageSnapshot(from: Data(json.utf8), now: now)

        #expect(snapshot.planName == "Active Pro")
        #expect(snapshot.fiveHourUsedQuota == nil)
        #expect(snapshot.fiveHourTotalQuota == nil)

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.loginMethod(for: .alibaba) == "Active Pro")
    }

    @Test
    func activeInstanceWithoutQuotaDoesNotBorrowQuotaFromAnotherInstance() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {
          "data": {
            "codingPlanInstanceInfos": [
              {
                "planName": "Expired Starter",
                "status": "EXPIRED",
                "endTime": "2025-04-01 17:00",
                "codingPlanQuotaInfo": {
                  "per5HourUsedQuota": 7,
                  "per5HourTotalQuota": 100,
                  "per5HourQuotaNextRefreshTime": 1700000100000
                }
              },
              {
                "planName": "Active Pro",
                "status": "VALID"
              }
            ]
          },
          "status_code": 0
        }
        """

        let snapshot = try AlibabaCodingPlanUsageFetcher.parseUsageSnapshot(from: Data(json.utf8), now: now)

        #expect(snapshot.planName == "Active Pro")
        #expect(snapshot.fiveHourUsedQuota == nil)
        #expect(snapshot.fiveHourTotalQuota == nil)
        #expect(snapshot.fiveHourNextRefreshTime == nil)
    }

    @Test
    func payloadLevelActiveProofDoesNotLabelFirstInstanceWhenNoInstanceIsActive() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {
          "data": {
            "status": "VALID",
            "codingPlanInstanceInfos": [
              {
                "planName": "Expired Starter",
                "status": "EXPIRED",
                "endTime": "2025-04-01 17:00"
              },
              {
                "planName": "No Proof Pro"
              }
            ]
          },
          "status_code": 0
        }
        """

        #expect(throws: AlibabaCodingPlanUsageError.self) {
            try AlibabaCodingPlanUsageFetcher.parseUsageSnapshot(from: Data(json.utf8), now: now)
        }
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

    @Test
    func consoleNeedLoginPayloadMapsToApiErrorForAPIKeyMode() {
        let json = """
        {
          "code": "ConsoleNeedLogin",
          "message": "You need to log in.",
          "requestId": "abc",
          "successResponse": false
        }
        """

        do {
            _ = try AlibabaCodingPlanUsageFetcher.parseUsageSnapshot(
                from: Data(json.utf8),
                authMode: .apiKey)
            Issue.record("Expected API-mode ConsoleNeedLogin payload to throw")
        } catch let error as AlibabaCodingPlanUsageError {
            guard case let .apiError(message) = error else {
                Issue.record("Expected apiError, got \(error)")
                return
            }
            #expect(message.contains("requires a console session"))
        } catch {
            Issue.record("Expected AlibabaCodingPlanUsageError, got \(error)")
        }
    }
}

@Suite(.serialized)
struct AlibabaCodingPlanFallbackTests {
    private struct StubClaudeFetcher: ClaudeUsageFetching {
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
            throw ClaudeUsageError.parseFailed("stub")
        }

        func debugRawProbe(model _: String) async -> String {
            "stub"
        }

        func detectVersion() -> String? {
            nil
        }
    }

    private func makeContext(
        sourceMode: ProviderSourceMode,
        settings: ProviderSettingsSnapshot? = nil,
        env: [String: String] = [:]) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: settings,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: browserDetection)
    }

    @Test
    func fallsBackOnTLSFailureInAutoMode() {
        let strategy = AlibabaCodingPlanWebFetchStrategy()
        let context = self.makeContext(sourceMode: .auto)
        #expect(strategy.shouldFallback(on: URLError(.secureConnectionFailed), context: context))
    }

    @Test
    func doesNotFallbackOnTLSFailureWhenSourceForcedToWeb() {
        let strategy = AlibabaCodingPlanWebFetchStrategy()
        let context = self.makeContext(sourceMode: .web)
        #expect(strategy.shouldFallback(on: URLError(.secureConnectionFailed), context: context) == false)
    }

    @Test
    func autoModeDoesNotBorrowManualCookieAuthorityWhenBrowserImportFails() {
        let strategy = AlibabaCodingPlanWebFetchStrategy()
        let settings = ProviderSettingsSnapshot.make(
            alibaba: ProviderSettingsSnapshot.AlibabaCodingPlanProviderSettings(
                cookieSource: .auto,
                manualCookieHeader: "session=manual-cookie",
                apiRegion: .international))
        let context = self.makeContext(sourceMode: .auto, settings: settings)

        CookieHeaderCache.clear(provider: .alibaba)
        AlibabaCodingPlanCookieImporter.importSessionOverrideForTesting = { _, _ in
            throw AlibabaCodingPlanSettingsError.missingCookie()
        }
        defer {
            AlibabaCodingPlanCookieImporter.importSessionOverrideForTesting = nil
        }

        do {
            _ = try AlibabaCodingPlanWebFetchStrategy.resolveCookieHeader(context: context, allowCached: false)
            Issue.record("Expected auto mode to fail instead of borrowing the manual cookie header")
        } catch let error as AlibabaCodingPlanSettingsError {
            guard case .missingCookie = error else {
                Issue.record("Expected missingCookie, got \(error)")
                return
            }
            #expect(strategy.shouldFallback(on: error, context: context))
        } catch {
            Issue.record("Expected AlibabaCodingPlanSettingsError, got \(error)")
        }
    }

    @Test
    func autoModeSkipsWebWhenNoAlibabaSessionIsAvailable() async {
        let strategy = AlibabaCodingPlanWebFetchStrategy()
        let settings = ProviderSettingsSnapshot.make(
            alibaba: ProviderSettingsSnapshot.AlibabaCodingPlanProviderSettings(
                cookieSource: .auto,
                manualCookieHeader: nil,
                apiRegion: .international))
        let context = self.makeContext(
            sourceMode: .auto,
            settings: settings,
            env: [AlibabaCodingPlanSettingsReader.apiTokenKey: "token-abc"])

        #expect(await strategy.isAvailable(context) == false)
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

    @Test
    func cookieSECTokenFallbackSurvivesUserInfoRequestFailure() async throws {
        let registered = URLProtocol.registerClass(AlibabaConsoleSECTokenStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(AlibabaConsoleSECTokenStubURLProtocol.self)
            }
            AlibabaConsoleSECTokenStubURLProtocol.handler = nil
        }

        AlibabaConsoleSECTokenStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }

            if url.host == "modelstudio.console.alibabacloud.com", request.httpMethod == "GET" {
                return Self.makeResponse(url: url, body: "<html></html>", statusCode: 200)
            }

            if url.host == "modelstudio.console.alibabacloud.com", url.path == "/tool/user/info.json" {
                throw URLError(.timedOut)
            }

            if url.host == "bailian-singapore-cs.alibabacloud.com", request.httpMethod == "POST" {
                let body = Self.requestBodyString(from: request)
                #expect(body.contains("sec_token=cookie-sec-token"))
                let json = """
                {
                  "data": {
                    "codingPlanInstanceInfos": [
                      { "planName": "Alibaba Coding Plan Pro", "status": "VALID" }
                    ],
                    "codingPlanQuotaInfo": {
                      "per5HourUsedQuota": 52,
                      "per5HourTotalQuota": 1000,
                      "per5HourQuotaNextRefreshTime": 1700000300000
                    }
                  },
                  "status_code": 0
                }
                """
                return Self.makeResponse(url: url, body: json, statusCode: 200)
            }

            throw URLError(.unsupportedURL)
        }

        let snapshot = try await AlibabaCodingPlanUsageFetcher.fetchUsage(
            cookieHeader: "sec_token=cookie-sec-token; login_aliyunid_ticket=ticket; login_aliyunid_pk=user",
            region: .international,
            environment: [:],
            now: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(snapshot.planName == "Alibaba Coding Plan Pro")
        #expect(snapshot.fiveHourUsedQuota == 52)
        #expect(snapshot.fiveHourTotalQuota == 1000)
    }

    @Test
    func hostOverrideAppliesToUserInfoSECTokenFallback() async throws {
        let registered = URLProtocol.registerClass(AlibabaConsoleSECTokenStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(AlibabaConsoleSECTokenStubURLProtocol.self)
            }
            AlibabaConsoleSECTokenStubURLProtocol.handler = nil
        }

        AlibabaConsoleSECTokenStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            #expect(url.host == "alibaba-proxy.test")

            if request.httpMethod == "GET", url.path == AlibabaCodingPlanAPIRegion.international.dashboardURL.path {
                return Self.makeResponse(url: url, body: "<html></html>", statusCode: 200)
            }

            if request.httpMethod == "GET", url.path == "/tool/user/info.json" {
                return Self.makeResponse(
                    url: url,
                    body: #"{"data":{"secToken":"override-sec-token"}}"#,
                    statusCode: 200)
            }

            if request.httpMethod == "POST", url.path == "/data/api.json" {
                let body = Self.requestBodyString(from: request)
                #expect(body.contains("sec_token=override-sec-token"))
                let json = """
                {
                  "data": {
                    "codingPlanInstanceInfos": [
                      { "planName": "Alibaba Coding Plan Pro", "status": "VALID" }
                    ],
                    "codingPlanQuotaInfo": {
                      "per5HourUsedQuota": 21,
                      "per5HourTotalQuota": 1000,
                      "per5HourQuotaNextRefreshTime": 1700000300000
                    }
                  },
                  "status_code": 0
                }
                """
                return Self.makeResponse(url: url, body: json, statusCode: 200)
            }

            throw URLError(.unsupportedURL)
        }

        let snapshot = try await AlibabaCodingPlanUsageFetcher.fetchUsage(
            cookieHeader: "sec_token=cookie-sec-token; login_aliyunid_ticket=ticket; login_aliyunid_pk=user",
            region: .international,
            environment: [AlibabaCodingPlanSettingsReader.hostKey: "https://alibaba-proxy.test"],
            now: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(snapshot.planName == "Alibaba Coding Plan Pro")
        #expect(snapshot.fiveHourUsedQuota == 21)
        #expect(snapshot.fiveHourTotalQuota == 1000)
    }

    @Test
    func consoleRequestBodyUsesRegionSpecificMetadata() async throws {
        let registered = URLProtocol.registerClass(AlibabaConsoleSECTokenStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(AlibabaConsoleSECTokenStubURLProtocol.self)
            }
            AlibabaConsoleSECTokenStubURLProtocol.handler = nil
        }

        AlibabaConsoleSECTokenStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }

            if request.httpMethod == "GET", url.path == AlibabaCodingPlanAPIRegion.chinaMainland.dashboardURL.path {
                return Self.makeResponse(url: url, body: "<html></html>", statusCode: 200)
            }

            if request.httpMethod == "GET", url.path == "/tool/user/info.json" {
                return Self.makeResponse(url: url, body: #"{"data":{"secToken":"cn-sec-token"}}"#, statusCode: 200)
            }

            if request.httpMethod == "POST", url.path == "/data/api.json" {
                let body = Self.requestBodyString(from: request)
                let params = try #require(Self.requestParamsDictionary(from: body))
                let data = try #require(params["Data"] as? [String: Any])
                let cornerstone = try #require(data["cornerstoneParam"] as? [String: Any])
                #expect(cornerstone["domain"] as? String == AlibabaCodingPlanAPIRegion.chinaMainland.consoleDomain)
                #expect(cornerstone["consoleSite"] as? String == AlibabaCodingPlanAPIRegion.chinaMainland.consoleSite)
                #expect(
                    cornerstone["feURL"] as? String
                        == AlibabaCodingPlanAPIRegion.chinaMainland.dashboardURL.absoluteString)

                let json = """
                {
                  "data": {
                    "codingPlanInstanceInfos": [
                      { "planName": "Alibaba Coding Plan Pro", "status": "VALID" }
                    ],
                    "codingPlanQuotaInfo": {
                      "per5HourUsedQuota": 21,
                      "per5HourTotalQuota": 1000,
                      "per5HourQuotaNextRefreshTime": 1700000300000
                    }
                  },
                  "status_code": 0
                }
                """
                return Self.makeResponse(url: url, body: json, statusCode: 200)
            }

            throw URLError(.unsupportedURL)
        }

        let snapshot = try await AlibabaCodingPlanUsageFetcher.fetchUsage(
            cookieHeader: "sec_token=cookie-sec-token; login_aliyunid_ticket=ticket; login_aliyunid_pk=user",
            region: .chinaMainland,
            environment: [:],
            now: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(snapshot.planName == "Alibaba Coding Plan Pro")
        #expect(snapshot.fiveHourUsedQuota == 21)
        #expect(snapshot.fiveHourTotalQuota == 1000)
    }

    private static func makeResponse(url: URL, body: String, statusCode: Int) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (response, Data(body.utf8))
    }

    private static func requestBodyString(from request: URLRequest) -> String {
        if let data = request.httpBody {
            return String(data: data, encoding: .utf8) ?? ""
        }

        guard let stream = request.httpBodyStream else {
            return ""
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 {
                break
            }
            data.append(buffer, count: count)
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func requestParamsDictionary(from body: String) -> [String: Any]? {
        guard var components = URLComponents(string: "https://example.invalid/?\(body)"),
              let params = components.queryItems?.first(where: { $0.name == "params" })?.value,
              let data = params.data(using: .utf8)
        else {
            return nil
        }

        let object = try? JSONSerialization.jsonObject(with: data, options: [])
        return object as? [String: Any]
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

final class AlibabaConsoleSECTokenStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return [
            "alibaba-proxy.test",
            "modelstudio.console.alibabacloud.com",
            "bailian-singapore-cs.alibabacloud.com",
            "bailian.console.aliyun.com",
            "bailian-beijing-cs.aliyuncs.com",
        ].contains(host)
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
