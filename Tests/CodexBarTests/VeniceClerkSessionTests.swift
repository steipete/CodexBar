import Foundation
import Testing
@testable import CodexBarCore

struct VeniceClerkSessionTests {
    @Test(arguments: ["__session", "__session_synthetic"])
    func `Clerk session family is accepted and sent only as Bearer`(name: String) async throws {
        #expect(VeniceCookieHeader.isSessionCookieName(name))
        let raw = "__client_uat=123; \(name)=synthetic-session; __client=private; clerk_active_synthetic=1"
        #expect(VeniceCookieHeader.header(from: raw) == "\(name)=synthetic-session")
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.url == VeniceWebUsageFetcher.sessionURL)
            #expect(request.httpMethod == "GET")
            #expect(!request.httpShouldHandleCookies)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-session")
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            return try Self.response(request, code: 200)
        }
        let snapshot = try await VeniceWebUsageFetcher.fetchUsage(cookieHeader: raw, transport: transport)
        #expect(snapshot.details.flatMap(\.rows).first { $0.label == "Subscription credits available" }?.value == "40")
        #expect(snapshot.primary == nil)
        #expect(snapshot.identity?.accountEmail == nil)
    }

    @Test
    func `legacy session retains priority over Clerk including numbered chunks`() {
        #expect(VeniceCookieHeader.header(from: "__session=clerk; __venice-auth.session-token=legacy")
            == "__venice-auth.session-token=legacy")
        #expect(VeniceCookieHeader.header(from:
            "__session=clerk; __venice-auth.session-token.1=b; __venice-auth.session-token.0=a")
            == "__venice-auth.session-token=ab")
        #expect(VeniceCookieHeader.header(from: "__session_synthetic=secondary; __session=primary")
            == "__session=primary")
        #expect(VeniceCookieHeader.header(from: "__session=primary; __session_synthetic=secondary")
            == "__session=primary")
    }

    @Test(arguments: ["venice.ai", ".venice.ai", "clerk.venice.ai", ".clerk.venice.ai", "notvenice.ai"])
    func `browser session cookies are restricted to the Venice site`(domain: String) throws {
        let cookie = try #require(HTTPCookie(properties: [
            .name: "__session", .value: "synthetic-session", .domain: domain, .path: "/",
        ]))
        let expected = ["venice.ai", ".venice.ai"].contains(domain) ? "__session=synthetic-session" : nil
        #expect(VeniceCookieHeader.header(from: [cookie]) == expected)
    }

    @Test(arguments: [
        "__client",
        "__client_uat",
        "__client_uat_synthetic",
        "clerk_active_synthetic",
        "__session_",
        "__sessionevil",
        "__Host-authjs.csrf-token",
        "__Secure-authjs.callback-url",
    ])
    func `non-session Clerk and Authjs cookies cannot authenticate`(name: String) async {
        #expect(!VeniceCookieHeader.isSessionCookieName(name))
        let transport = ProviderHTTPTransportHandler { _ in
            Issue.record("Missing session must fail before HTTP")
            throw VeniceUsageError.invalidCredentials
        }
        await #expect(throws: VeniceUsageError.missingCredentials) {
            _ = try await VeniceWebUsageFetcher.fetchUsage(cookieHeader: "\(name)=synthetic", transport: transport)
        }
        let message = VeniceUsageError.missingCredentials.localizedDescription
        #expect(message.contains("__session"))
        #expect(message.contains("__venice-auth.session-token"))
    }

    @Test(arguments: [401, 403])
    func `rejected Clerk sessions explain active tab recovery`(code: Int) async {
        let transport = ProviderHTTPTransportHandler { request in try Self.response(request, code: code) }
        await #expect(throws: VeniceUsageError.invalidCredentials) {
            _ = try await VeniceWebUsageFetcher.fetchUsage(cookieHeader: "__session=expired", transport: transport)
        }
        #expect(VeniceUsageError.invalidCredentials.localizedDescription.contains("tab"))
        #expect(VeniceUsageError.expiredSession.localizedDescription.contains("tab"))
    }

    @Test(arguments: [ProviderCookieSource.manual, .auto])
    func `Clerk sessions work through manual and browser strategies`(source: ProviderCookieSource) async throws {
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-session")
            return try Self.response(request, code: 200)
        }
        let strategy = VeniceWebFetchStrategy(
            usageLoader: { try await VeniceWebUsageFetcher.fetchUsage(cookieHeader: $0, transport: transport) },
            sessionLoader: { _ in
                #expect(source == .auto)
                return [VeniceResolvedSession(
                    cookieHeader: "__session=synthetic-session",
                    sourceLabel: "Chrome fixture")]
            })
        let settings = ProviderSettingsSnapshot.make(venice: VeniceProviderSettings(
            cookieSource: source, manualCookieHeader: "__client_uat=123; __session=synthetic-session"))
        let detection = BrowserDetection(cacheTTL: 0)
        let context = ProviderFetchContext(
            runtime: .cli,
            sourceMode: .web,
            includeCredits: true,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: settings,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: detection),
            browserDetection: detection)
        let result = try await strategy.fetch(context)
        #expect(result.sourceLabel == (source == .manual ? "manual cookie" : "Chrome fixture"))
        #expect(!result.usage.details.isEmpty)
    }

    private static func response(_ request: URLRequest, code: Int) throws -> (Data, URLResponse) {
        // #3940 confirmed these numeric claims; amounts below are synthetic, not the reporter's balances.
        let claims: [String: Any] = [
            "exp": 3_000_000_000,
            "bundledCredits": 40,
            "bundledCreditsUsage": [
                "availableCredits": 40, "monthlyRefillCredits": 100, "nextRefillAt": 1_900_000_000_000,
                "tierCap": 300, "usedThisCycle": 60,
            ],
        ]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let body = try JSONSerialization.data(withJSONObject: ["token": "e30.\(payload).synthetic"])
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: code, httpVersion: nil, headerFields: nil))
        return (body, response)
    }
}
