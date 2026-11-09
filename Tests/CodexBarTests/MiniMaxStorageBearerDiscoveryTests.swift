import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
#if os(macOS)
import SweetCookieKit
#endif
@testable import CodexBarCore

struct MiniMaxStorageBearerDiscoveryTests {
    @Test(arguments: [false, true])
    func `pure browser storage bearer sessions fetch usage without a cookie header`(scoped: Bool) async throws {
        let session = MiniMaxWebSession(
            cookieHeader: "",
            sourceLabel: "Fixture Profile",
            domain: .global,
            cookies: scoped ? [] : nil)
        let stub = Self.bearerTransport(domain: .global)

        let snapshot = try await MiniMaxUsageFetcher.fetchBrowserUsage(
            browserSession: session,
            authorizationToken: "storage-fixture",
            includeBillingHistory: false,
            session: stub)

        #expect(snapshot.usedPercent == 25)
        #expect(await stub.requests().count == 1)
        #expect(session.cacheableCookieHeader == nil)
    }

    @Test(arguments: [nil, "", " \t\n"] as [String?])
    func `empty browser sessions without a usable bearer fail without a request`(bearer: String?) async {
        let session = MiniMaxWebSession(cookieHeader: "", sourceLabel: "Fixture Profile", domain: .global, cookies: [])
        let stub = Self.bearerTransport(domain: .global)

        await #expect(throws: MiniMaxUsageError.invalidCredentials) {
            try await MiniMaxUsageFetcher.fetchBrowserUsage(
                browserSession: session,
                authorizationToken: bearer,
                includeBillingHistory: false,
                session: stub)
        }
        #expect(await stub.requests().isEmpty)
    }

    @Test
    func `the public manual cookie entry still requires a cookie even with a bearer`() async {
        let stub = Self.bearerTransport(domain: .global)
        await #expect(throws: MiniMaxUsageError.invalidCredentials) {
            try await MiniMaxUsageFetcher.fetchUsage(
                cookieHeader: "",
                authorizationToken: "storage-fixture",
                environment: [:],
                includeBillingHistory: false,
                session: stub)
        }
        #expect(await stub.requests().isEmpty)
    }

    @Test(arguments: ["", " \t\n"], [false, true])
    func `absent cookie headers are neither sent nor cached`(header: String, scoped: Bool) throws {
        let session = MiniMaxWebSession(
            cookieHeader: header,
            sourceLabel: "Fixture Profile",
            domain: .global,
            cookies: scoped ? [] : nil)
        #expect(session.cacheableCookieHeader == nil)
        #expect(try session.cookieHeader(for: #require(URL(string: "https://platform.minimax.io/"))) == nil)
    }

    #if os(macOS)
    @Test(arguments: [MiniMaxWebSessionDomain.global, .chinaMainland, .legacyChina], [false, true])
    func `same family account and unrelated path records retain storage bearer discovery`(
        domain: MiniMaxWebSessionDomain,
        accountOnly: Bool) async throws
    {
        let host = "\(accountOnly ? "account" : "platform").\(domain.rootDomain)"
        let imported = MiniMaxCookieImporter.SessionInfo(
            records: [Self.record(
                host: host,
                path: accountOnly ? "/" : "/unrelated",
                name: domain == .chinaMainland ? "_token" : "HERTZ-SESSION")],
            sourceLabel: "Fixture Profile")
        let region: MiniMaxAPIRegion = domain == .global ? .global : .chinaMainland
        let sessions = imported.webSessions(for: region)
        let session = try #require(sessions.first)
        let stub = Self.bearerTransport(domain: domain)

        #expect(sessions.count == 1)
        #expect(session.domain == domain)
        #expect(session.cookieHeader.isEmpty)
        #expect(session.groupID == nil)
        #expect(session.usesTokenCookie == false)
        #expect(session.cacheableCookieHeader == nil)
        for url in domain.cookieURLs(for: region, environment: [:]) {
            #expect(session.cookieHeader(for: url) == nil)
        }
        let snapshot = try await MiniMaxUsageFetcher.fetchBrowserUsage(
            browserSession: session,
            authorizationToken: "storage-fixture",
            region: region,
            includeBillingHistory: false,
            session: stub)

        #expect(snapshot.usedPercent == 25)
        #expect(await stub.requests().count == 1)
    }

    @Test(arguments: ["account.minimax.cn", "account.minimaxi.com", "minimax.io.example"])
    func `other family records cannot admit a global storage bearer candidate`(host: String) {
        let imported = MiniMaxCookieImporter.SessionInfo(
            records: [Self.record(host: host, path: "/")],
            sourceLabel: "Fixture Profile")
        #expect(imported.webSessions(for: .global).isEmpty)
    }

    @Test
    func `profiles without records and overrides to another realm do not create candidates`() {
        let empty = MiniMaxCookieImporter.SessionInfo(records: [], sourceLabel: "Fixture Profile")
        #expect(empty.webSessions(for: .global).isEmpty)
        #expect(empty.webSessions(for: .chinaMainland).isEmpty)
        let imported = MiniMaxCookieImporter.SessionInfo(
            records: [Self.record(host: "account.minimax.io", path: "/")],
            sourceLabel: "Fixture Profile")
        let environment = [
            MiniMaxSettingsReader.codingPlanURLKey: "https://platform.minimax.cn/console/usage",
            MiniMaxSettingsReader.remainsURLKey: "https://www.minimax.cn/backend/account/token_plan/remains_percent",
        ]
        #expect(imported.webSessions(for: .global, environment: environment).isEmpty)
    }

    private static func record(host: String, path: String, name: String = "HERTZ-SESSION") -> BrowserCookieRecord {
        BrowserCookieRecord(
            domain: host,
            name: name,
            path: path,
            value: "out-of-scope-fixture",
            expires: nil,
            isSecure: true,
            isHTTPOnly: true,
            scope: .hostOnly)
    }
    #endif

    private static func bearerTransport(domain: MiniMaxWebSessionDomain) -> ProviderHTTPTransportStub {
        ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.host == "platform.\(domain.rootDomain)")
            #expect(url.path == (domain == .chinaMainland ? "/console/usage" : "/user-center/payment/coding-plan"))
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer storage-fixture")
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            return (Data(Self.quotaJSON.utf8), response)
        }
    }

    private static let quotaJSON = """
    {"base_resp":{"status_code":0},"model_remains":[{
      "model_name":"general","current_interval_used_percent":"25%","current_interval_total_percent":"100%"
    }]}
    """
}
