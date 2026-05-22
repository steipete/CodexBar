import Foundation
import Testing
@testable import CodexBarCore

struct AlibabaTokenPlanSettingsReaderTests {
    @Test
    func `cookie reads from environment`() {
        let cookie = AlibabaTokenPlanSettingsReader.cookieHeader(environment: [
            AlibabaTokenPlanSettingsReader.cookieHeaderKey: "\"login_aliyunid_ticket=ticket\"",
        ])
        #expect(cookie == "login_aliyunid_ticket=ticket")
    }

    @Test
    func `default quota URL targets token plan API`() {
        let url = AlibabaTokenPlanUsageFetcher.defaultQuotaURL
        #expect(url.host == "bailian-cs.console.aliyun.com")
        #expect(url.absoluteString.contains("queryTokenPlanInstanceInfo"))
        #expect(url.absoluteString.contains("BroadScopeAspnGateway"))
    }
}

struct AlibabaTokenPlanCookieHeaderTests {
    @Test
    func `builds URL scoped headers for API and dashboard`() throws {
        let cookies = [
            self.cookie(name: "login_aliyunid_ticket", value: "ticket", domain: ".aliyun.com"),
            self.cookie(name: "login_current_pk", value: "account", domain: ".aliyun.com"),
            self.cookie(name: "sec_token", value: "shared", domain: ".console.aliyun.com"),
            self.cookie(name: "sec_token", value: "dashboard", domain: "bailian.console.aliyun.com"),
            self.cookie(name: "sec_token", value: "api", domain: "bailian-cs.console.aliyun.com"),
        ]

        let headers = try #require(AlibabaTokenPlanCookieHeader.headers(from: cookies))

        #expect(headers.apiCookieHeader.contains("login_aliyunid_ticket=ticket"))
        #expect(headers.apiCookieHeader.contains("login_current_pk=account"))
        #expect(headers.apiCookieHeader.contains("sec_token=api"))
        #expect(!headers.apiCookieHeader.contains("sec_token=dashboard"))
        #expect(headers.dashboardCookieHeader.contains("sec_token=dashboard"))
        #expect(!headers.dashboardCookieHeader.contains("sec_token=api"))
    }

    @Test
    func `cached token plan headers preserve URL scoping`() throws {
        let headers = AlibabaTokenPlanCookieHeaders(
            apiCookieHeader: "login_aliyunid_ticket=ticket; api_only=api",
            dashboardCookieHeader: "login_aliyunid_ticket=ticket; dashboard_only=dashboard")

        let cached = try #require(AlibabaTokenPlanCookieHeaders(cachedHeader: headers.cacheCookieHeader))

        #expect(cached.apiCookieHeader.contains("api_only=api"))
        #expect(!cached.apiCookieHeader.contains("dashboard_only=dashboard"))
        #expect(cached.dashboardCookieHeader.contains("dashboard_only=dashboard"))
        #expect(!cached.dashboardCookieHeader.contains("api_only=api"))
    }

    private func cookie(
        name: String,
        value: String,
        domain: String,
        path: String = "/",
        expires: Date = Date(timeIntervalSinceNow: 3600)) -> HTTPCookie
    {
        HTTPCookie(properties: [
            .domain: domain,
            .path: path,
            .name: name,
            .value: value,
            .expires: expires,
            .secure: true,
        ])!
    }
}

struct AlibabaTokenPlanUsageSnapshotTests {
    @Test
    func `maps used and total quota to primary window`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = Date(timeIntervalSince1970: 1_700_100_000)
        let snapshot = AlibabaTokenPlanUsageSnapshot(
            planName: "TOKEN PLAN",
            usedQuota: 250,
            totalQuota: 1000,
            remainingQuota: nil,
            resetsAt: reset,
            updatedAt: now)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.primary?.resetsAt == reset)
        #expect(usage.primary?.resetDescription == "250 / 1,000 credits used")
        #expect(usage.loginMethod(for: .alibabatokenplan) == "TOKEN PLAN")
    }

    @Test
    func `does not create primary window from balance only`() {
        let snapshot = AlibabaTokenPlanUsageSnapshot(
            planName: "TOKEN PLAN",
            usedQuota: nil,
            totalQuota: nil,
            remainingQuota: 700,
            resetsAt: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.loginMethod(for: .alibabatokenplan) == "TOKEN PLAN")
    }
}

struct AlibabaTokenPlanUsageParsingTests {
    @Test
    func `parses token plan payload`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {
          "data": {
            "tokenPlanInstanceInfo": {
              "planName": "TOKEN PLAN",
              "status": "VALID",
              "quotaInfo": {
                "usedQuota": 125,
                "totalQuota": 1000,
                "remainingQuota": 875
              },
              "periodEndTime": 1701000000000
            }
          },
          "status_code": 0
        }
        """

        let snapshot = try AlibabaTokenPlanUsageFetcher.parseUsageSnapshot(from: Data(json.utf8), now: now)

        #expect(snapshot.planName == "TOKEN PLAN")
        #expect(snapshot.usedQuota == 125)
        #expect(snapshot.totalQuota == 1000)
        #expect(snapshot.remainingQuota == 875)
        #expect(snapshot.resetsAt == Date(timeIntervalSince1970: 1_701_000_000))
        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 12.5)
    }

    @Test
    func `parses remaining and total quota`() throws {
        let body = """
        {
          "data": {
            "tokenPlanInstanceInfo": {
              "packageName": "TOKEN PLAN",
              "quotaInfo": {
                "remainingCredits": 750,
                "totalCredits": 1000
              }
            }
          },
          "statusCode": 200
        }
        """
        let payload = ["successResponse": ["body": body]]
        let data = try JSONSerialization.data(withJSONObject: payload)

        let snapshot = try AlibabaTokenPlanUsageFetcher.parseUsageSnapshot(from: data)

        #expect(snapshot.planName == "TOKEN PLAN")
        #expect(snapshot.usedQuota == nil)
        #expect(snapshot.remainingQuota == 750)
        #expect(snapshot.totalQuota == 1000)
        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 25)
    }

    @Test
    func `plan only payload stays visible without quota window`() throws {
        let json = """
        {
          "data": {
            "tokenPlanInstanceInfo": {
              "planName": "TOKEN PLAN",
              "status": "VALID"
            }
          },
          "status_code": 0
        }
        """

        let snapshot = try AlibabaTokenPlanUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))

        #expect(snapshot.planName == "TOKEN PLAN")
        #expect(snapshot.totalQuota == nil)
        #expect(snapshot.toUsageSnapshot().primary == nil)
    }

    @Test
    func `login payload maps to login required`() {
        let json = """
        {
          "code": "ConsoleNeedLogin",
          "message": "You need to log in.",
          "successResponse": false
        }
        """

        #expect(throws: AlibabaTokenPlanUsageError.loginRequired) {
            try AlibabaTokenPlanUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))
        }
    }

    @Test
    func `forbidden payload maps to invalid credentials`() {
        let json = """
        {
          "statusCode": 403,
          "message": "Forbidden"
        }
        """

        #expect(throws: AlibabaTokenPlanUsageError.invalidCredentials) {
            try AlibabaTokenPlanUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))
        }
    }

    @Test
    func `cookie only request continues without SEC token`() async throws {
        let registered = URLProtocol.registerClass(AlibabaTokenPlanStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(AlibabaTokenPlanStubURLProtocol.self)
            }
            AlibabaTokenPlanStubURLProtocol.handler = nil
        }

        AlibabaTokenPlanStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }

            if url.host == "alibaba-token-plan.test", request.httpMethod == "GET" {
                return Self.makeResponse(url: url, body: "<html></html>", statusCode: 200)
            }

            if url.host == "alibaba-token-plan.test", request.httpMethod == "POST" {
                #expect(request.value(forHTTPHeaderField: "Cookie") == "login_aliyunid_ticket=ticket; raw_only=keep")
                #expect(request.value(forHTTPHeaderField: "Origin") == "https://bailian.console.aliyun.com")
                #expect(request.value(forHTTPHeaderField: "Referer") == AlibabaTokenPlanUsageFetcher.dashboardURL
                    .absoluteString)
                let body = Self.requestBodyString(from: request)
                #expect(!body.contains("sec_token="))
                #expect(body.contains("commodityCode"))
                #expect(body.contains("sfm_tokenplanteams_dp_cn"))
                #expect(body.contains("onlyLatestOne"))
                let json = """
                {
                  "data": {
                    "tokenPlanInstanceInfo": {
                      "planName": "TOKEN PLAN"
                    }
                  },
                  "status_code": 0
                }
                """
                return Self.makeResponse(url: url, body: json, statusCode: 200)
            }

            throw URLError(.unsupportedURL)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AlibabaTokenPlanStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let snapshot = try await AlibabaTokenPlanUsageFetcher.fetchUsage(
            apiCookieHeader: "login_aliyunid_ticket=ticket; raw_only=keep",
            dashboardCookieHeader: "login_aliyunid_ticket=ticket; raw_only=keep",
            environment: [AlibabaTokenPlanSettingsReader.hostKey: "https://alibaba-token-plan.test"],
            session: session)

        #expect(snapshot.planName == "TOKEN PLAN")
    }

    @Test
    func `redirect preserves cookie only for same host HTTPS requests`() throws {
        let sourceURL = try #require(URL(string: "https://bailian-cs.console.aliyun.com/data/api.json"))
        let sameHostURL = try #require(URL(string: "https://bailian-cs.console.aliyun.com/redirected"))
        let crossHostURL = try #require(URL(string: "https://signin.aliyun.com/login"))
        let insecureURL = try #require(URL(string: "http://bailian-cs.console.aliyun.com/redirected"))
        let response = try #require(HTTPURLResponse(
            url: sourceURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: nil))

        var sameHostRequest = URLRequest(url: sameHostURL)
        sameHostRequest.setValue("old=value", forHTTPHeaderField: "Cookie")
        let sameHostRedirect = try #require(AlibabaTokenPlanUsageFetcher.redirectedRequest(
            response: response,
            request: sameHostRequest,
            cookieHeader: "login_aliyunid_ticket=ticket"))
        #expect(sameHostRedirect.value(forHTTPHeaderField: "Cookie") == "login_aliyunid_ticket=ticket")

        var crossHostRequest = URLRequest(url: crossHostURL)
        crossHostRequest.setValue("old=value", forHTTPHeaderField: "Cookie")
        let crossHostRedirect = try #require(AlibabaTokenPlanUsageFetcher.redirectedRequest(
            response: response,
            request: crossHostRequest,
            cookieHeader: "login_aliyunid_ticket=ticket"))
        #expect(crossHostRedirect.value(forHTTPHeaderField: "Cookie") == nil)

        let insecureRedirect = AlibabaTokenPlanUsageFetcher.redirectedRequest(
            response: response,
            request: URLRequest(url: insecureURL),
            cookieHeader: "login_aliyunid_ticket=ticket")
        #expect(insecureRedirect == nil)
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
        if let stream = request.httpBodyStream {
            stream.open()
            defer {
                stream.close()
            }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 {
                    break
                }
                data.append(buffer, count: count)
            }
            return String(data: data, encoding: .utf8) ?? ""
        }
        return ""
    }
}

@Suite(.serialized)
struct AlibabaTokenPlanWebStrategyTests {
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

    @Test
    func `auto web strategy surfaces cookie import errors`() async throws {
        let strategy = AlibabaTokenPlanWebFetchStrategy()
        let settings = ProviderSettingsSnapshot.make(
            alibabaTokenPlan: ProviderSettingsSnapshot.AlibabaTokenPlanProviderSettings(
                cookieSource: .auto,
                manualCookieHeader: nil))
        let context = ProviderFetchContext(
            runtime: .cli,
            sourceMode: .web,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: settings,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))

        CookieHeaderCache.clear(provider: .alibabatokenplan)
        AlibabaCodingPlanCookieImporter.importSessionOverrideForTesting = { _, _ in
            throw AlibabaCodingPlanSettingsError.missingCookie(
                details: "macOS Keychain denied access to Chrome Safe Storage.")
        }
        defer {
            AlibabaCodingPlanCookieImporter.importSessionOverrideForTesting = nil
        }

        #expect(await strategy.isAvailable(context))

        do {
            _ = try AlibabaTokenPlanWebFetchStrategy.resolveCookieHeader(context: context, allowCached: false)
            Issue.record("Expected cookie import failure to be surfaced")
        } catch let error as AlibabaTokenPlanSettingsError {
            guard case let .missingCookie(details) = error else {
                Issue.record("Expected missingCookie, got \(error)")
                return
            }
            #expect(details == "macOS Keychain denied access to Chrome Safe Storage.")
            #expect(error.localizedDescription.contains("Alibaba Token Plan"))
            #expect(!error.localizedDescription.contains("Alibaba Coding Plan"))
        }
    }

    @Test
    func `auto web strategy imports URL scoped token plan cookies`() throws {
        let strategy = AlibabaTokenPlanWebFetchStrategy()
        let settings = ProviderSettingsSnapshot.make(
            alibabaTokenPlan: ProviderSettingsSnapshot.AlibabaTokenPlanProviderSettings(
                cookieSource: .auto,
                manualCookieHeader: nil))
        let context = ProviderFetchContext(
            runtime: .cli,
            sourceMode: .web,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: settings,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))

        CookieHeaderCache.clear(provider: .alibabatokenplan)
        AlibabaCodingPlanCookieImporter.importSessionOverrideForTesting = { _, _ in
            AlibabaCodingPlanCookieImporter.SessionInfo(
                cookies: [
                    self.cookie(name: "login_aliyunid_ticket", value: "ticket", domain: ".aliyun.com"),
                    self.cookie(name: "login_current_pk", value: "account", domain: ".aliyun.com"),
                    self.cookie(name: "dashboard_only", value: "dashboard", domain: "bailian.console.aliyun.com"),
                    self.cookie(name: "api_only", value: "api", domain: "bailian-cs.console.aliyun.com"),
                    self.cookie(name: "alibabacloud_only", value: "cloud", domain: ".alibabacloud.com"),
                ],
                sourceLabel: "Chrome Default")
        }
        defer {
            AlibabaCodingPlanCookieImporter.importSessionOverrideForTesting = nil
            CookieHeaderCache.clear(provider: .alibabatokenplan)
        }

        let headers = try AlibabaTokenPlanWebFetchStrategy.resolveCookieHeaders(context: context, allowCached: false)

        #expect(headers.apiCookieHeader != headers.dashboardCookieHeader)
        #expect(!headers.apiCookieHeader.contains("dashboard_only=dashboard"))
        #expect(headers.apiCookieHeader.contains("api_only=api"))
        #expect(!headers.apiCookieHeader.contains("alibabacloud_only=cloud"))
        #expect(headers.dashboardCookieHeader.contains("dashboard_only=dashboard"))
        #expect(!headers.dashboardCookieHeader.contains("api_only=api"))
        #expect(!headers.dashboardCookieHeader.contains("alibabacloud_only=cloud"))

        AlibabaCodingPlanCookieImporter.importSessionOverrideForTesting = { _, _ in
            throw AlibabaCodingPlanSettingsError.missingCookie(details: "unexpected import")
        }
        let cachedHeaders = try AlibabaTokenPlanWebFetchStrategy.resolveCookieHeaders(
            context: context,
            allowCached: true)
        #expect(cachedHeaders.apiCookieHeader == headers.apiCookieHeader)
        #expect(cachedHeaders.dashboardCookieHeader == headers.dashboardCookieHeader)
        #expect(strategy.id == "alibaba-token-plan.web")
    }

    private func cookie(
        name: String,
        value: String,
        domain: String,
        path: String = "/",
        expires: Date = Date(timeIntervalSinceNow: 3600)) -> HTTPCookie
    {
        HTTPCookie(properties: [
            .domain: domain,
            .path: path,
            .name: name,
            .value: value,
            .expires: expires,
            .secure: true,
        ])!
    }
}

final class AlibabaTokenPlanStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host == "bailian.console.aliyun.com" ||
            host == "bailian-cs.console.aliyun.com" ||
            host == "alibaba-token-plan.test"
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
