import Foundation
import SweetCookieKit
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct HelmcodeProviderTests {
    @Test
    func `quota and credits map to monthly model windows and prepaid balance`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let parsed = try HelmcodeUsageFetcher._parseSnapshotForTesting(
            quotaData: Data(Self.quotaFixture.utf8),
            creditsData: Data(#"{"balanceMicros":12500000,"currency":"eur"}"#.utf8),
            now: now)
        let snapshot = parsed.toUsageSnapshot()

        #expect(snapshot.identity?.providerID == .helmcode)
        #expect(snapshot.identity?.loginMethod == "Dashboard session")
        #expect(snapshot.primary?.usedPercent == 75)
        #expect(snapshot.primary?.resetDescription?.contains("helm-model-b") == true)
        #expect(snapshot.extraRateWindows?.map(\.title) == ["helm-model-a"])
        #expect(snapshot.extraRateWindows?.first?.window.usedPercent == 25)
        #expect(snapshot.providerCost?.used == 12.5)
        #expect(snapshot.providerCost?.currencyCode == "EUR")
        #expect(snapshot.providerCost?.period == "Prepaid balance")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let expectedReset = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        #expect(snapshot.primary?.resetsAt == expectedReset)
    }

    @Test
    func `unlimited models are omitted and credits default to euros`() throws {
        let quota = #"""
        {"periodStart":"2026-09-01T00:00:00Z","models":[{"model":"helm-unlimited","cap":0,"tokensUsed":123}]}
        """#
        let parsed = try HelmcodeUsageFetcher._parseSnapshotForTesting(
            quotaData: Data(quota.utf8),
            creditsData: Data(#"{"balanceMicros":2750000}"#.utf8))
        let snapshot = parsed.toUsageSnapshot()

        #expect(snapshot.primary == nil)
        #expect(snapshot.extraRateWindows == nil)
        #expect(snapshot.providerCost?.used == 2.75)
        #expect(snapshot.providerCost?.currencyCode == "EUR")
    }

    @Test
    func `malformed optional credits do not erase valid quota`() throws {
        let parsed = try HelmcodeUsageFetcher._parseSnapshotForTesting(
            quotaData: Data(Self.quotaFixture.utf8),
            creditsData: Data(#"{"balanceMicros":"unknown"}"#.utf8))

        #expect(parsed.credits == nil)
        #expect(parsed.toUsageSnapshot().primary?.usedPercent == 75)
    }

    @Test
    func `settings reader accepts cookie headers and curl captures`() {
        #expect(HelmcodeSettingsReader.cookieHeader(environment: [
            "HELMCODE_COOKIE": " Cookie: session=fixture; tenant=test ",
        ]) == "session=fixture; tenant=test")
        #expect(HelmcodeSettingsReader.cookieHeader(environment: [
            "helmcode_cookie": "curl 'https://cloud.helmcode.com' -H 'Cookie: session=fixture'",
        ]) == "session=fixture")
        #expect(HelmcodeSettingsReader.cookieHeader(environment: [:]) == nil)
    }

    @Test
    func `imported cookies honor request host path secure and expiry scope`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cookies = try [
            self.cookie(name: "root", value: "1", domain: ".helmcode.com", path: "/"),
            self.cookie(name: "api", value: "2", domain: "cloud-api.helmcode.com", path: "/api"),
            self.cookie(name: "dashboard", value: "3", domain: "cloud.helmcode.com", path: "/"),
            self.cookie(name: "wrongPath", value: "4", domain: "cloud-api.helmcode.com", path: "/settings"),
            self.cookie(
                name: "expired",
                value: "5",
                domain: "cloud-api.helmcode.com",
                path: "/",
                expires: now - 1),
            self.cookie(name: "secure", value: "6", domain: "cloud-api.helmcode.com", path: "/", secure: true),
        ]
        let secureURL = try #require(URL(string: "https://cloud-api.helmcode.com/api/usage/quota"))
        let insecureURL = try #require(URL(string: "http://cloud-api.helmcode.com/api/usage/quota"))

        #expect(HelmcodeCookieHeader.header(from: cookies, for: secureURL, now: now) ==
            "api=2; root=1; secure=6")
        #expect(HelmcodeCookieHeader.header(from: cookies, for: insecureURL, now: now) == "api=2; root=1")
    }

    @Test(arguments: [302, 401, 403, 500])
    func `fetch sends dashboard session headers and keeps quota when credits fail`(creditsStatus: Int) async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "session=fixture")
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://cloud.helmcode.com")
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://cloud.helmcode.com/credits")
            switch url.path {
            case "/api/usage/quota":
                return try Self.response(url: url, body: Self.quotaFixture)
            case "/api/billing/credits":
                return try Self.response(url: url, status: creditsStatus, body: #"{"error":"unavailable"}"#)
            default:
                Issue.record("Unexpected request path: \(url.path)")
                throw URLError(.badURL)
            }
        }

        let parsed = try await HelmcodeUsageFetcher.fetchUsage(
            cookieHeader: "session=fixture",
            transport: transport)

        #expect(parsed.credits == nil)
        #expect(parsed.toUsageSnapshot().primary?.usedPercent == 75)
        #expect(await transport.requests().contains { $0.url?.path == "/api/billing/credits" })
    }

    @Test(arguments: [302, 401, 403])
    func `fetch classifies rejected dashboard sessions`(status: Int) async {
        let transport = ProviderHTTPTransportStub { request in
            let url = request.url ?? HelmcodeUsageFetcher.quotaURL
            return try Self.response(url: url, status: status, body: #"{"error":"unauthenticated"}"#)
        }

        await #expect(throws: HelmcodeUsageError.invalidSession(.helmcode)) {
            _ = try await HelmcodeUsageFetcher.fetchUsage(
                cookieHeader: "session=expired",
                transport: transport)
        }
    }

    @Test
    func `strategy deployment prefers explicit environment over settings`() {
        let helmcodeSettings = HelmcodeProviderSettings(
            cookieSource: .auto,
            manualCookieHeader: nil,
            deployment: .helmcode)
        let nanSettings = HelmcodeProviderSettings(
            cookieSource: .auto,
            manualCookieHeader: nil,
            deployment: .nanBuilders)

        #expect(HelmcodeWebFetchStrategy.deployment(settings: nil, environment: [:]) == .helmcode)
        #expect(HelmcodeWebFetchStrategy.deployment(settings: helmcodeSettings, environment: [:]) == .helmcode)
        #expect(HelmcodeWebFetchStrategy.deployment(settings: nanSettings, environment: [:]) == .nanBuilders)
        #expect(HelmcodeWebFetchStrategy.deployment(
            settings: helmcodeSettings,
            environment: ["HELMCODE_DEPLOYMENT": "nan"]) == .nanBuilders)
        #expect(HelmcodeWebFetchStrategy.deployment(
            settings: nanSettings,
            environment: ["HELMCODE_DEPLOYMENT": ""]) == .nanBuilders)
    }

    @Test
    func `imported domain scoped cookies match subdomain api hosts`() throws {
        let record = BrowserCookieRecord(
            domain: "nan.builders",
            name: "nan_session",
            path: "/",
            value: "fixture",
            expires: Date(timeIntervalSince1970: 1_900_000_000),
            isSecure: true,
            isHTTPOnly: true,
            scope: .domain)
        let cookies = HelmcodeCookieImporter.makeCookies(from: [record])
        let nanURL = try #require(URL(string: "https://cloud-api.nan.builders/api/usage/quota"))
        let dashboardURL = try #require(URL(string: "https://cloud.nan.builders/dashboard"))

        #expect(cookies.first?.domain == ".nan.builders")
        #expect(HelmcodeCookieHeader.header(from: cookies, for: nanURL) == "nan_session=fixture")
        #expect(HelmcodeCookieHeader.header(from: cookies, for: dashboardURL) == "nan_session=fixture")

        let hostOnlyRecord = BrowserCookieRecord(
            domain: "cloud-api.nan.builders",
            name: "host_session",
            path: "/",
            value: "host",
            expires: Date(timeIntervalSince1970: 1_900_000_000),
            isSecure: true,
            isHTTPOnly: true,
            scope: .hostOnly)
        let hostOnlyCookies = HelmcodeCookieImporter.makeCookies(from: [hostOnlyRecord])
        #expect(HelmcodeCookieHeader.header(from: hostOnlyCookies, for: nanURL) == "host_session=host")
        let otherHost = try #require(URL(string: "https://cloud.nan.builders/dashboard"))
        #expect(HelmcodeCookieHeader.header(from: hostOnlyCookies, for: otherHost) == nil)
    }

    @Test
    func `nan builders deployment targets the community endpoints`() {
        let deployment = HelmcodeDeployment.nanBuilders
        #expect(deployment.displayName == "NaN Builders")
        #expect(deployment.quotaURL.absoluteString == "https://cloud-api.nan.builders/api/usage/quota")
        #expect(deployment.creditsURL.absoluteString == "https://cloud-api.nan.builders/api/billing/credits")
        #expect(deployment.dashboardURL.absoluteString == "https://cloud.nan.builders")
        #expect(deployment.dashboardCreditsURL.absoluteString == "https://cloud.nan.builders/credits")
        #expect(deployment.cookieDomains == [
            "cloud-api.nan.builders",
            "cloud.nan.builders",
            "nan.builders",
        ])
    }

    @Test
    func `deployment resolution reads environment with helmcode fallback`() {
        #expect(HelmcodeDeployment.resolve(environment: [:]) == .helmcode)
        #expect(HelmcodeDeployment.resolve(environment: ["HELMCODE_DEPLOYMENT": "helmcode"]) == .helmcode)
        #expect(HelmcodeDeployment.resolve(environment: ["HELMCODE_DEPLOYMENT": "nan"]) == .nanBuilders)
        #expect(HelmcodeDeployment.resolve(environment: ["HELMCODE_DEPLOYMENT": "nan.builders"]) == .nanBuilders)
        #expect(HelmcodeDeployment.resolve(environment: ["HELMCODE_DEPLOYMENT": "nanbuilders"]) == .nanBuilders)
        #expect(HelmcodeDeployment.resolve(environment: ["HELMCODE_DEPLOYMENT": " nan "]) == .nanBuilders)
        #expect(HelmcodeDeployment.resolve(environment: ["HELMCODE_DEPLOYMENT": "unknown"]) == .helmcode)
    }

    @Test
    func `nan deployment fetch targets community endpoints with scoped cookies`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.host == "cloud-api.nan.builders")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "session=fixture")
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://cloud.nan.builders")
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://cloud.nan.builders/credits")
            switch url.path {
            case "/api/usage/quota":
                return try Self.response(url: url, body: Self.quotaFixture)
            case "/api/billing/credits":
                return try Self.response(url: url, body: #"{"balanceMicros":5000000}"#)
            default:
                Issue.record("Unexpected request path: \(url.path)")
                throw URLError(.badURL)
            }
        }

        let parsed = try await HelmcodeUsageFetcher.fetchUsage(
            cookieHeader: "session=fixture",
            deployment: .nanBuilders,
            transport: transport)

        #expect(parsed.toUsageSnapshot().providerCost?.used == 5)
        #expect(await transport.requests().count == 2)
    }

    @Test
    func `nan cookies never leak into helmcode requests`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cookies = try [
            self.cookie(name: "session", value: "nan", domain: ".nan.builders", path: "/"),
            self.cookie(name: "session", value: "helm", domain: ".helmcode.com", path: "/"),
        ]
        let nanURL = try #require(URL(string: "https://cloud-api.nan.builders/api/usage/quota"))
        let helmcodeURL = try #require(URL(string: "https://cloud-api.helmcode.com/api/usage/quota"))

        #expect(HelmcodeCookieHeader.header(from: cookies, for: nanURL, now: now) == "session=nan")
        #expect(HelmcodeCookieHeader.header(from: cookies, for: helmcodeURL, now: now) == "session=helm")
    }

    @Test @MainActor
    func `settings store persists deployment and feeds snapshots`() throws {
        let settings = testSettingsStore(suiteName: "HelmcodeProviderTests-deployment")
        #expect(settings.helmcodeDeployment == .helmcode)
        #expect(settings.helmcodeSettingsSnapshot(tokenOverride: nil).deployment == .helmcode)

        settings.helmcodeDeployment = .nanBuilders
        #expect(settings.helmcodeDeployment == .nanBuilders)
        #expect(settings.providerConfig(for: .helmcode)?.region == "nanBuilders")

        let contribution = try ProviderDescriptorRegistry.descriptor(for: .helmcode)
            .settingsSection
            .credentialContribution(context: ProviderCredentialSettingsContext(
                config: #require(settings.providerConfig(for: .helmcode)),
                account: nil))
        let cliSnapshot = contribution.map { ProviderSettingsSnapshot(contributions: [$0]) }
        #expect(cliSnapshot?.helmcode?.deployment == .nanBuilders)
    }

    @Test @MainActor
    func `descriptor and app implementation are registered`() throws {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .helmcode)
        #expect(descriptor.metadata.displayName == "Helmcode")
        #expect(descriptor.metadata.browserCookieOrder == [.chrome])
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .web])
        #expect(descriptor.branding.color == ProviderColor(hex: 0x4934E1))
        #expect(try #require(ProviderImplementationRegistry.implementation(for: .helmcode))
            is HelmcodeProviderImplementation)

        let snapshot = try HelmcodeUsageFetcher._parseSnapshotForTesting(
            quotaData: Data(Self.quotaFixture.utf8),
            creditsData: nil).toUsageSnapshot()
        #expect(descriptor.presentation.extraRateWindows(snapshot: snapshot).map(\.title) == ["helm-model-a"])
        #expect(descriptor.presentation.menu.usesPrimaryDescriptionAsDetail(snapshot: snapshot))
    }

    private func cookie(
        name: String,
        value: String,
        domain: String,
        path: String,
        expires: Date? = nil,
        secure: Bool = false) throws -> HTTPCookie
    {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
        ]
        if let expires {
            properties[.expires] = expires
        }
        if secure {
            properties[.secure] = "TRUE"
        }
        return try #require(HTTPCookie(properties: properties))
    }

    private static func response(url: URL, status: Int = 200, body: String) throws -> (Data, URLResponse) {
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil))
        return (Data(body.utf8), response)
    }

    private static let quotaFixture = #"""
    {
      "periodStart": "2026-09-18T14:30:00Z",
      "models": [
        {
          "model": "helm-model-a",
          "cap": 1000000,
          "tokensUsed": 250000,
          "creditTokens": 2000,
          "creditSpendMicros": 12500,
          "addon": false
        },
        {
          "model": "helm-model-b",
          "cap": 2000000,
          "tokensUsed": 1500000,
          "creditTokens": 0,
          "creditSpendMicros": 0,
          "addon": true
        }
      ]
    }
    """#
}
