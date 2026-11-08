import Foundation
import Testing
@testable import CodexBarCore

struct MiniMaxBrowserSessionTests {
    @Test
    func `same host opaque bearer remains usable while mismatched groups are rejected`() {
        #expect(MiniMaxCodingPlanFetchStrategy.isCompatibleGroupID(nil, sessionGroupID: "123456"))
        #expect(MiniMaxCodingPlanFetchStrategy.isCompatibleGroupID("123456", sessionGroupID: "123456"))
        #expect(MiniMaxCodingPlanFetchStrategy.isCompatibleGroupID("987654", sessionGroupID: "123456") == false)
    }

    @Test
    func `current China cookies are tried without unrelated storage bearers`() {
        let attempts = MiniMaxCodingPlanFetchStrategy.authorizationCandidates(
            cookieHeader: "_token=current-session; minimax_group_id_v2=123456",
            tokens: ["old-global-token", "old-global-token", "current-storage-token"],
            domain: .chinaMainland)

        #expect(attempts == [nil])
    }

    @Test
    func `legacy bearer fallback order is preserved without duplicate attempts`() {
        let attempts = MiniMaxCodingPlanFetchStrategy.authorizationCandidates(
            cookieHeader: "HERTZ-SESSION=cookie-token",
            tokens: ["storage-token", "storage-token", "cookie-token"],
            domain: .global)

        #expect(attempts == ["storage-token", "cookie-token", nil])
    }

    @Test(arguments: [MiniMaxWebSessionDomain.global, .legacyChina])
    func `other host families keep bearer fallback even when another product has a token cookie`(
        domain: MiniMaxWebSessionDomain)
    {
        #expect(MiniMaxCodingPlanFetchStrategy.authorizationCandidates(
            cookieHeader: "_token=other-product; HERTZ-SESSION=cookie-token",
            tokens: ["storage-token"],
            domain: domain) == ["storage-token", "cookie-token", nil])
    }

    @Test
    func `current China optional requests do not send cookies to legacy hosts`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.host == "platform.minimax.cn" || url.host == "www.minimax.cn")
            let isPage = url.path == "/console/usage"
            let body = isPage ? "<html>fixture without usage</html>" : """
            {"base_resp":{"status_code":0},"model_remains":[{
              "current_interval_total_count":100,"current_interval_usage_count":25
            }]}
            """
            return (Data(body.utf8), HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": isPage ? "text/html" : "application/json"])!)
        }
        _ = try await MiniMaxUsageFetcher.fetchUsage(
            cookieHeader: "_token=current-fixture; minimax_group_id_v2=123456",
            groupID: "123456",
            region: .chinaMainland,
            environment: MiniMaxWebSessionDomain.chinaMainland.environment([:]),
            includeBillingHistory: true,
            session: transport)
        #expect(await transport.requests().contains { $0.url?.path.hasSuffix("remains_percent") == true })
    }

    @Test
    func `manual legacy China session keeps optional enrichment`() {
        let context = MiniMaxUsageFetcher.WebFetchContext(
            cookie: "HERTZ-SESSION=fixture",
            authorizationToken: "fixture-bearer",
            region: .chinaMainland,
            environment: [:],
            transport: ProviderHTTPTransportStub { _ in throw URLError(.unsupportedURL) })
        #expect(context.usesCurrentChinaEndpoint == false)
    }

    @Test
    func `legacy China source routes both page and quota to its own host`() {
        let environment = MiniMaxWebSessionDomain.legacyChina.environment([:])
        let pageURL = MiniMaxUsageFetcher.resolveCodingPlanURL(region: .chinaMainland, environment: environment)
        let remainsURLs = MiniMaxUsageFetcher.resolveRemainsURLs(region: .chinaMainland, environment: environment)

        #expect(pageURL.host == "platform.minimaxi.com")
        #expect(pageURL.path == "/user-center/payment/coding-plan")
        #expect(remainsURLs.count == 1)
        #expect(remainsURLs[0].host == "platform.minimaxi.com")
        #expect(remainsURLs[0].path == "/v1/api/openplatform/coding_plan/remains")
    }

    @Test
    func `current China source and explicit endpoint overrides keep their routes`() {
        let current = MiniMaxWebSessionDomain.chinaMainland.environment([:])
        #expect(MiniMaxUsageFetcher.resolveRemainsURLs(region: .chinaMainland, environment: current)[0].host ==
            "www.minimax.cn")

        let explicit = [MiniMaxSettingsReader.remainsURLKey: "https://fixture.example/remains"]
        #expect(MiniMaxWebSessionDomain.chinaMainland.environment(explicit) == explicit)
        #expect(MiniMaxWebSessionDomain.legacyChina.environment(explicit) == explicit)
        #expect(MiniMaxUsageFetcher.resolveRemainsURLs(region: .chinaMainland, environment: current).count == 1)
    }

    #if os(macOS)
    @Test
    func `one browser profile yields isolated current and legacy China sessions`() throws {
        let session = try MiniMaxCookieImporter.SessionInfo(cookies: [
            self.cookie(name: "_token", value: "global-session", domain: ".minimax.io"),
            self.cookie(name: "_token", value: "legacy-session", domain: ".minimaxi.com"),
            self.cookie(name: "_token", value: "current-session", domain: ".minimax.cn"),
            self.cookie(name: "minimax_group_id_v2", value: "123456", domain: ".minimax.cn"),
            self.cookie(name: "_token", value: "lookalike-session", domain: "minimax.cn.example"),
        ], sourceLabel: "Chrome Default")

        let china = session.webSessions(for: .chinaMainland)
        #expect(china.count == 2)
        #expect(Set(CookieHeaderNormalizer.pairs(from: china[0].cookieHeader).map { "\($0.name)=\($0.value)" }) ==
            Set(["_token=current-session", "minimax_group_id_v2=123456"]))
        #expect(china[0].sourceLabel == "Chrome Default")
        #expect(china[0].domain == .chinaMainland)
        #expect(china[0].groupID == "123456")
        #expect(china[1].cookieHeader == "_token=legacy-session")
        #expect(china[1].sourceLabel == "Chrome Default")
        #expect(china[1].domain == .legacyChina)
        #expect(session.webSessions(for: .global).map(\.cookieHeader) == ["_token=global-session"])
    }

    @Test
    func `quota session excludes unrelated subdomains and chooses the matching cookie path`() throws {
        let session = try MiniMaxCookieImporter.SessionInfo(cookies: [
            self.cookie(name: "_token", value: "account-session", domain: "account.minimax.cn"),
            self.cookie(name: "_token", value: "console-session", domain: "platform.minimax.cn"),
            self.cookie(name: "_token", value: "root-session", domain: ".minimax.cn"),
            self.cookie(name: "_token", value: "quota-session", domain: "www.minimax.cn", path: "/backend"),
            self.cookie(name: "_token", value: "wrong-path", domain: "www.minimax.cn", path: "/console"),
        ], sourceLabel: "Fixture Profile")

        #expect(session.webSessions(for: .chinaMainland).map(\.cookieHeader) == ["_token=quota-session"])
    }

    private func cookie(name: String, value: String, domain: String, path: String = "/") throws -> HTTPCookie {
        try #require(HTTPCookie(properties: [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
            .secure: "TRUE",
        ]))
    }
    #endif
}
