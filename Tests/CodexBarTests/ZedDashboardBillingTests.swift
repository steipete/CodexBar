import CodexBarCore
import Foundation
import Testing

struct ZedDashboardBillingTests {
    private static let redactedSessionCookie =
        #"zed.session=redacted-token={"sid":"fake-session-id"}; __cf_bm=redacted-cloudflare"#

    private static func proResponse() throws -> ZedAuthenticatedUserResponse {
        let url = Bundle.module.url(
            forResource: "users-me-pro",
            withExtension: "json",
            subdirectory: "Fixtures/Zed")!
        return try ZedStatusProbe.parseResponse(Data(contentsOf: url))
    }

    private static func fixtureData(named name: String) throws -> Data {
        let url = Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/Zed")!
        return try Data(contentsOf: url)
    }

    @Test
    func `provider settings default dashboard cookies off`() {
        let settings = ProviderSettingsSnapshot.ZedProviderSettings()

        #expect(settings.cookieSource == .off)
        #expect(settings.manualCookieHeader == nil)
    }

    @Test
    func `off source preserves neutral token placeholders`() async throws {
        let billing = try await ZedDashboardBillingFetcher.fetch(
            browserDetection: BrowserDetection(),
            cookieSource: .off,
            manualCookieHeader: nil)
        let snapshot = try ZedUsageSnapshot(response: Self.proResponse()).toUsageSnapshot(tokenBilling: billing)
        let spendNote = snapshot.extraRateWindows?.first(where: { $0.id == "zed.token-spend-note" })
        let tokenCredits = snapshot.extraRateWindows?.first(where: { $0.id == "zed.token-credits" })

        #expect(billing == nil)
        #expect(spendNote?.usageKnown == true)
        #expect(spendNote?.window.resetDescription == "Sign in on dashboard or enable cookies")
        #expect(tokenCredits?.usageKnown == true)
    }

    @Test
    func `empty manual source is rejected before any request`() async {
        await #expect(throws: ZedDashboardBillingError.invalidManualCookie) {
            _ = try await ZedDashboardBillingFetcher.fetch(
                browserDetection: BrowserDetection(),
                cookieSource: .manual,
                manualCookieHeader: "  ")
        }
    }

    @Test
    func `cloudflare only manual cookie is rejected`() async {
        await #expect(throws: ZedDashboardBillingError.missingSessionCookie) {
            _ = try await ZedDashboardBillingFetcher.fetch(
                browserDetection: BrowserDetection(),
                cookieSource: .manual,
                manualCookieHeader: "__cf_bm=only-cloudflare")
        }
    }

    @Test
    func `legacy session cookie without zed dot session is rejected`() async {
        await #expect(throws: ZedDashboardBillingError.missingSessionCookie) {
            _ = try await ZedDashboardBillingFetcher.fetch(
                browserDetection: BrowserDetection(),
                cookieSource: .manual,
                manualCookieHeader: "session=legacy-only")
        }
    }

    @Test
    func `zed session cookie header filters ancillary cookies`() {
        let filtered = ZedCookieHeader.filteredBillingHeader(from: Self.redactedSessionCookie)

        #expect(filtered == #"zed.session=redacted-token={"sid":"fake-session-id"}; __cf_bm=redacted-cloudflare"#)
        #expect(ZedCookieHeader.hasSessionCookie(Self.redactedSessionCookie))
        #expect(ZedCookieHeader.isCloudflareOnly("__cf_bm=only") == true)
        #expect(ZedCookieHeader.isCloudflareOnly(Self.redactedSessionCookie) == false)
    }

    @Test
    func `parses pro billing usage fixture`() throws {
        let billing = try ZedDashboardBillingFetcher.parseResponse(Self.fixtureData(named: "billing-usage-pro"))

        #expect(billing.spentUSD == 1.25)
        #expect(billing.includedUSD == 5)
        #expect(billing.spendLimitUSD == nil)
    }

    @Test
    func `parses spend limit fixture with included and threshold`() throws {
        let billing = try ZedDashboardBillingFetcher.parseResponse(
            Self.fixtureData(named: "billing-usage-spend-limit"))

        #expect(billing.spentUSD == 6)
        #expect(billing.includedUSD == 5)
        #expect(billing.spendLimitUSD == 15)
    }

    @Test
    func `manual source fetches billing usage with stub transport`() async throws {
        let fixture = try Self.fixtureData(named: "billing-usage-pro")
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.url?.absoluteString == ZedDashboardBillingFetcher.billingUsageURL.absoluteString)
            #expect(request.value(forHTTPHeaderField: "Cookie") == #"zed.session=redacted"#)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            return (fixture, response)
        }

        let billing = try await ZedDashboardBillingFetcher.fetch(
            browserDetection: BrowserDetection(),
            cookieSource: .manual,
            manualCookieHeader: "zed.session=redacted; _rdt_uuid=tracking",
            transport: transport)

        #expect(billing?.spentUSD == 1.25)
        #expect(billing?.includedUSD == 5)
    }

    @Test
    func `typed billing snapshot replaces static token windows`() throws {
        let billing = ZedTokenBillingSnapshot(
            spentUSD: 1.25,
            includedUSD: 5,
            spendLimitUSD: nil,
            periodEnd: nil)
        let snapshot = try ZedUsageSnapshot(response: Self.proResponse()).toUsageSnapshot(tokenBilling: billing)
        let tokenWindow = snapshot.extraRateWindows?.first(where: { $0.id == "zed.token-credits" })

        #expect(snapshot.extraRateWindows?.contains(where: { $0.id == "zed.token-spend-note" }) == false)
        #expect(tokenWindow?.usageKnown == true)
        #expect(tokenWindow?.window.usedPercent == 25)
        #expect(tokenWindow?.window.resetDescription == "$1.25 of $5.00 included")
    }

    @Test
    func `billing snapshot uses larger live spend limit denominator`() throws {
        let billing = ZedTokenBillingSnapshot(
            spentUSD: 6,
            includedUSD: 5,
            spendLimitUSD: 15,
            periodEnd: nil)
        let snapshot = try ZedUsageSnapshot(response: Self.proResponse()).toUsageSnapshot(tokenBilling: billing)
        let tokenWindow = snapshot.extraRateWindows?.first(where: { $0.id == "zed.token-credits" })

        #expect(tokenWindow?.usageKnown == true)
        #expect(tokenWindow?.window.usedPercent == 40)
        #expect(tokenWindow?.window.resetDescription == "$6.00 / $15.00")
    }

    @Test
    func `billing error replaces placeholders when cookies enabled`() throws {
        let error = try #require(ZedDashboardBillingError.unauthorized.errorDescription)
        let snapshot = try ZedUsageSnapshot(response: Self.proResponse()).toUsageSnapshot(
            tokenBilling: nil,
            dashboardCookieSource: .manual,
            billingError: error)
        let errorWindow = snapshot.extraRateWindows?.first(where: { $0.id == "zed.token-billing-error" })

        #expect(snapshot.extraRateWindows?.contains(where: { $0.id == "zed.token-spend-note" }) == false)
        #expect(errorWindow?.usageKnown == false)
        #expect(errorWindow?.window.resetDescription == error)
    }

    @Test
    func `cookies off keeps neutral placeholders when billing is nil`() throws {
        let snapshot = try ZedUsageSnapshot(response: Self.proResponse()).toUsageSnapshot(tokenBilling: nil)

        #expect(snapshot.extraRateWindows?.contains(where: { $0.id == "zed.token-spend-note" }) == true)
        #expect(snapshot.extraRateWindows?.first(where: { $0.id == "zed.token-credits" })?.usageKnown == true)
        #expect(snapshot.extraRateWindows?.contains(where: { $0.id == "zed.token-billing-error" }) == false)
    }

    @Test
    func `unauthorized billing response surfaces auth error`() async {
        let transport = ProviderHTTPTransportStub { _ in
            let response = HTTPURLResponse(
                url: ZedDashboardBillingFetcher.billingUsageURL,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil)!
            return (Data("{}".utf8), response)
        }

        await #expect(throws: ZedDashboardBillingError.unauthorized) {
            _ = try await ZedDashboardBillingFetcher.fetch(
                browserDetection: BrowserDetection(),
                cookieSource: .manual,
                manualCookieHeader: "zed.session=redacted",
                transport: transport)
        }
    }

    @Test
    func `billing fetch preserves transport cancellation`() async {
        let transport = ProviderHTTPTransportStub { _ in
            throw CancellationError()
        }

        await #expect(throws: CancellationError.self) {
            _ = try await ZedDashboardBillingFetcher.fetch(
                browserDetection: BrowserDetection(),
                cookieSource: .manual,
                manualCookieHeader: "zed.session=redacted",
                transport: transport)
        }
    }

    @Test
    func `billing fetch classifies transport failures as network errors`() async {
        let transport = ProviderHTTPTransportStub { _ in
            throw URLError(.notConnectedToInternet)
        }

        await #expect(throws: ZedDashboardBillingError.networkError(
            URLError(.notConnectedToInternet).localizedDescription))
        {
            _ = try await ZedDashboardBillingFetcher.fetch(
                browserDetection: BrowserDetection(),
                cookieSource: .manual,
                manualCookieHeader: "zed.session=redacted",
                transport: transport)
        }
    }
}
