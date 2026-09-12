import Foundation
import Testing
@testable import CodexBarCore

struct VeniceWebUsageFetcherTests {
    private static let fixtureUsedThisCycle = 13400.0
    private static let fixtureMonthlyRefill = 22500.0
    private static let fixtureNextRefillAtMs: Double = 1_790_056_735_422
    private static let fixtureNow = Date(timeIntervalSince1970: 1_788_000_000)

    @Test
    func `web strategy is unavailable unless source is explicit web`() async {
        let strategy = VeniceWebFetchStrategy(
            usageLoader: { _ in fatalError("must not fetch") },
            sessionLoader: { fatalError("must not import cookies") })
        #expect(await strategy.isAvailable(Self.context(.auto)) == false)
        #expect(await strategy.isAvailable(Self.context(.api)) == false)
        await #expect(throws: VeniceUsageError.missingCredentials) {
            _ = try await strategy.fetch(Self.context(.auto))
        }
        await #expect(throws: VeniceUsageError.missingCredentials) {
            _ = try await strategy.fetch(Self.context(.api))
        }
        #if os(macOS)
        #expect(await strategy.isAvailable(Self.context(.web)) == true)
        #endif
    }

    @Test
    func `token account selection rejects before cookie import`() async {
        let strategy = VeniceWebFetchStrategy(
            usageLoader: { _ in fatalError("must not fetch") },
            sessionLoader: { fatalError("must not import cookies") })
        let account = Self.context(.web, selectedTokenAccountID: UUID())
        #expect(await strategy.isAvailable(account) == false)
        await #expect(throws: VeniceUsageError.tokenAccountUnsupported) {
            _ = try await strategy.fetch(account)
        }
    }

    @Test
    func `selected token account routes to api instead of ambient web`() {
        let credentials = VeniceProviderDescriptor.descriptor.credentials
        #expect(credentials?.selectedAccountSourceMode(base: .web, account: nil, config: nil) == .web)
        #expect(credentials?.selectedAccountSourceMode(base: .auto, account: nil, config: nil) == .auto)
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Work",
            token: "ven-account-key",
            addedAt: 1_700_000_000,
            lastUsed: nil)
        #expect(credentials?.selectedAccountSourceMode(base: .web, account: account, config: nil) == .api)
    }

    @Test
    func `revoked first session falls through to signed-in profile`() async throws {
        let snapshot = try VeniceWebUsageFetcher.snapshot(
            fromClaims: Self.fixtureClaims(),
            now: Self.fixtureNow)
        let strategy = VeniceWebFetchStrategy(
            usageLoader: { header in
                if header == "session=revoked" { throw VeniceUsageError.invalidCredentials }
                return snapshot
            },
            sessionLoader: {
                [
                    VeniceResolvedSession(cookieHeader: "session=revoked", sourceLabel: "Chrome A"),
                    VeniceResolvedSession(cookieHeader: "session=live", sourceLabel: "Chrome B"),
                ]
            })
        let result = try await strategy.fetch(Self.context(.web))
        #expect(result.strategyID == "venice.web")
        #expect(result.sourceLabel == "Chrome B")
    }

    @Test
    func `manual cookie is used without browser import`() async throws {
        let snapshot = try VeniceWebUsageFetcher.snapshot(
            fromClaims: Self.fixtureClaims(),
            now: Self.fixtureNow)
        let strategy = VeniceWebFetchStrategy(
            usageLoader: { header in
                #expect(header == "__venice-auth.session-token=manual-abc")
                return snapshot
            },
            sessionLoader: { fatalError("must not import cookies") })
        let settings = ProviderSettingsSnapshot.make(venice: VeniceProviderSettings(
            cookieSource: .manual,
            manualCookieHeader: "__venice-auth.session-token=manual-abc"))
        let result = try await strategy.fetch(Self.context(.web, settings: settings))
        #expect(result.strategyID == "venice.web")
        #expect(result.sourceLabel == "manual cookie")
    }

    @Test
    func `manual source without session cookie fails`() async {
        let strategy = VeniceWebFetchStrategy(
            usageLoader: { _ in fatalError("must not fetch") },
            sessionLoader: { fatalError("must not import cookies") })
        let settings = ProviderSettingsSnapshot.make(venice: VeniceProviderSettings(
            cookieSource: .manual,
            manualCookieHeader: "unrelated=1"))
        await #expect(throws: VeniceUsageError.missingCredentials) {
            _ = try await strategy.fetch(Self.context(.web, settings: settings))
        }
    }

    @Test
    func `venice settings section accepts snapshot contribution`() {
        // Startup assembles a snapshot per provider and precondition-fails on
        // mismatch; pin the contract so the app cannot launch-trap again.
        let registration = VeniceProviderDescriptor.descriptor.settingsSection
        let contribution = ProviderSettingsSnapshotContribution.venice(VeniceProviderSettings(
            cookieSource: .auto,
            manualCookieHeader: nil))
        #expect(registration.accepts(contribution))
    }

    @Test
    func `auto source ignores stored manual header`() async throws {
        let snapshot = try VeniceWebUsageFetcher.snapshot(
            fromClaims: Self.fixtureClaims(),
            now: Self.fixtureNow)
        let strategy = VeniceWebFetchStrategy(
            usageLoader: { _ in snapshot },
            sessionLoader: {
                [VeniceResolvedSession(cookieHeader: "session=live", sourceLabel: "Brave")]
            })
        let settings = ProviderSettingsSnapshot.make(venice: VeniceProviderSettings(
            cookieSource: .auto,
            manualCookieHeader: "__venice-auth.session-token=manual-abc"))
        let result = try await strategy.fetch(Self.context(.web, settings: settings))
        #expect(result.sourceLabel == "Brave")
    }

    @Test
    func `descriptor presentation labels monthly quota`() throws {
        let monthly = try VeniceWebUsageFetcher.snapshot(
            fromClaims: Self.fixtureClaims(),
            now: Self.fixtureNow)
        let metadata = VeniceProviderDescriptor.descriptor.metadata
        let monthlyLabels = VeniceProviderDescriptor.descriptor.presentation.rateWindowLabels(
            metadata: metadata,
            snapshot: monthly,
            now: Self.fixtureNow)
        #expect(monthlyLabels.primary == "Monthly credits")

        let hourly = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Self.fixtureNow,
            identity: nil)
        let hourlyLabels = VeniceProviderDescriptor.descriptor.presentation.rateWindowLabels(
            metadata: metadata,
            snapshot: hourly,
            now: Self.fixtureNow)
        #expect(hourlyLabels.primary == "Balance")
    }

    @Test
    func `live quota fixture maps cycle used over monthly refill`() throws {
        let snapshot = try VeniceWebUsageFetcher.snapshot(
            fromClaims: Self.fixtureClaims(),
            now: Self.fixtureNow)
        let expectedPercent = Self.fixtureUsedThisCycle / Self.fixtureMonthlyRefill * 100
        let reset = Date(timeIntervalSince1970: Self.fixtureNextRefillAtMs / 1000)

        #expect(snapshot.primary?.usedPercent == expectedPercent)
        #expect(((snapshot.primary?.usedPercent ?? 0) * 10000).rounded() / 10000 == 59.5556)
        #expect(snapshot.primary?.windowMinutes == ProviderPaceCapability.monthlyWindowSentinelMinutes)
        #expect(snapshot.primary?.resetsAt == reset)
        #expect(VeniceProviderDescriptor.primaryLabel(window: snapshot.primary) == "Monthly credits")
        #expect(snapshot.subscriptionRenewsAt == reset)
        #expect(snapshot.dataConfidence == .exact)
        #expect(snapshot.identity?.providerID == .venice)
        #expect(snapshot.identity?.accountEmail == nil)
        #expect(snapshot.identity?.accountOrganization == nil)
        #expect(snapshot.identity?.loginMethod == nil)
        #expect(snapshot.identity?.accountID == nil)

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let parts = utc.dateComponents([.year, .month, .day], from: reset)
        #expect(parts.year == 2026)
        #expect(parts.month == 9)
        #expect(parts.day == 22)

        let rows = Dictionary(uniqueKeysWithValues: snapshot.details.flatMap(\.rows).map { ($0.label, $0.value) })
        #expect(rows["Used this cycle"] == "13,400")
        #expect(rows["Monthly allowance"] == "22,500")
        #expect(rows["Subscription remaining"] == "9,100")
        #expect(rows["Bank cap"] == "67,500")
        #expect(rows["Total credits"] == "9,600")
        #expect(rows["Plan"] == "MAX")
        #expect(!rows.contains(where: { $0.value.contains("9,100") && $0.value.contains("22,500") }))
    }

    @Test
    func `does not treat banked remaining as leftover monthly allowance`() throws {
        var claims = Self.fixtureClaims()
        var usage = try #require(claims["bundledCreditsUsage"] as? [String: Any])
        usage["usedThisCycle"] = 30000
        usage["availableCredits"] = 40000
        claims["bundledCreditsUsage"] = usage
        claims["bundledCredits"] = 40000

        let snapshot = try VeniceWebUsageFetcher.snapshot(fromClaims: claims, now: Self.fixtureNow)
        #expect(snapshot.primary?.usedPercent == 30000.0 / 22500.0 * 100)
        let rows = Dictionary(uniqueKeysWithValues: snapshot.details.flatMap(\.rows).map { ($0.label, $0.value) })
        #expect(rows["Subscription remaining"] == "40,000")
        #expect(rows["Monthly allowance"] == "22,500")
        #expect(rows["Bank cap"] == "67,500")
    }

    @Test
    func `ignores JWT identity claims`() throws {
        var claims = Self.fixtureClaims()
        claims["email"] = "hidden@example.com"
        claims["sub"] = "user-123"
        claims["accountId"] = "acct-9"
        let snapshot = try VeniceWebUsageFetcher.snapshot(fromClaims: claims, now: Self.fixtureNow)
        #expect(snapshot.identity?.accountEmail == nil)
        #expect(snapshot.identity?.accountID == nil)
        #expect(snapshot.identity?.loginMethod == nil)
    }

    @Test
    func `cookie-authenticated fetch uses session cookie only`() async throws {
        let body = try Self.sessionJSON(payload: Self.fixtureClaims())
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.url == VeniceWebUsageFetcher.sessionURL)
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(
                request.value(forHTTPHeaderField: "Cookie")
                    == "\(VeniceCookieHeader.sessionCookieName)=session-cookie")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            return try Self.response(request: request, status: 200, body: body)
        }

        let snapshot = try await VeniceWebUsageFetcher.fetchUsage(
            cookieHeader: "\(VeniceCookieHeader.sessionCookieName)=session-cookie; _ga=tracker; cf_clearance=cf",
            transport: transport,
            now: Self.fixtureNow)
        #expect(((snapshot.primary?.usedPercent ?? 0) * 10000).rounded() / 10000 == 59.5556)
    }

    @Test
    func `fetch honors caller timeout`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.timeoutInterval == 42)
            return try Self.response(
                request: request,
                status: 200,
                body: Self.sessionJSON(payload: Self.fixtureClaims()))
        }
        _ = try await VeniceWebUsageFetcher.fetchUsage(
            cookieHeader: "\(VeniceCookieHeader.sessionCookieName)=session-cookie",
            transport: transport,
            timeout: 42,
            now: Self.fixtureNow)
    }

    @Test
    func `auth failure does not send an API key`() async {
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return try Self.response(request: request, status: 403, body: #"{"error":"forbidden"}"#)
        }
        await #expect(throws: VeniceUsageError.invalidCredentials) {
            _ = try await VeniceWebUsageFetcher.fetchUsage(
                cookieHeader: "\(VeniceCookieHeader.sessionCookieName)=session-cookie",
                transport: transport,
                now: Self.fixtureNow)
        }
    }

    @Test(arguments: [
        #"{"token":"not-a-jwt"}"#,
        "{ invalid json }",
        "[]",
        #"{"token":null}"#,
        "{}",
    ])
    func `malformed session payloads fail`(_ body: String) async {
        let transport = ProviderHTTPTransportHandler { request in
            try Self.response(request: request, status: 200, body: body)
        }
        await #expect(throws: VeniceUsageError.self) {
            _ = try await VeniceWebUsageFetcher.fetchUsage(
                cookieHeader: "\(VeniceCookieHeader.sessionCookieName)=session-cookie",
                transport: transport,
                now: Self.fixtureNow)
        }
    }

    @Test
    func `expired JWT payload is rejected`() throws {
        var claims = Self.fixtureClaims()
        claims["exp"] = 1_600_000_000
        #expect(throws: VeniceUsageError.expiredSession) {
            _ = try VeniceWebUsageFetcher.snapshot(fromClaims: claims, now: Self.fixtureNow)
        }
    }

    @Test
    func `anonymous session is rejected even with quota fields`() throws {
        var claims = Self.fixtureClaims()
        claims["userType"] = "ANONYMOUS"
        #expect(throws: VeniceUsageError.anonymousSession) {
            _ = try VeniceWebUsageFetcher.snapshot(fromClaims: claims, now: Self.fixtureNow)
        }
    }

    @Test
    func `missing quota is rejected`() throws {
        let claims: [String: Any] = [
            "userType": "MAX",
            "exp": 1_893_456_000,
        ]
        #expect(throws: VeniceUsageError.missingQuota) {
            _ = try VeniceWebUsageFetcher.snapshot(fromClaims: claims, now: Self.fixtureNow)
        }
    }

    @Test
    func `negative quota fields are rejected`() throws {
        var claims = Self.fixtureClaims()
        var usage = try #require(claims["bundledCreditsUsage"] as? [String: Any])
        usage["usedThisCycle"] = -1
        claims["bundledCreditsUsage"] = usage
        #expect(throws: VeniceUsageError.missingQuota) {
            _ = try VeniceWebUsageFetcher.snapshot(fromClaims: claims, now: Self.fixtureNow)
        }
    }

    @Test
    func `web fetch does not copy API-key identity`() async throws {
        let snapshot = try VeniceWebUsageFetcher.snapshot(
            fromClaims: Self.fixtureClaims(),
            now: Self.fixtureNow)
        let strategy = VeniceWebFetchStrategy(
            usageLoader: { _ in snapshot },
            sessionLoader: {
                [VeniceResolvedSession(
                    cookieHeader: "\(VeniceCookieHeader.sessionCookieName)=session-cookie",
                    sourceLabel: "Chrome Default")]
            })
        let result = try await strategy.fetch(Self.context(
            .web,
            environment: ["VENICE_API_KEY": "ven-admin-key"]))
        #expect(result.strategyID == "venice.web")
        #expect(result.sourceLabel == "Chrome Default")
        #expect(result.usage.identity?.accountEmail == nil)
        #expect(result.usage.identity?.loginMethod == nil)
    }

    @Test
    func `session cookie header keeps only the auth cookie and chunk variants`() {
        #expect(
            VeniceCookieHeader.header(from: [
                (name: "_ga", value: "tracker"),
                (name: VeniceCookieHeader.sessionCookieName, value: "live"),
                (name: "cf_clearance", value: "cf"),
            ]) == "\(VeniceCookieHeader.sessionCookieName)=live")

        #expect(
            VeniceCookieHeader.header(from: [
                (name: "\(VeniceCookieHeader.sessionCookieName).0", value: "aaa"),
                (name: "\(VeniceCookieHeader.sessionCookieName).1", value: "bbb"),
                (name: "_clck", value: "track"),
            ]) == "\(VeniceCookieHeader.sessionCookieName)=aaabbb")
    }

    @Test
    func `zero cycle usage remains a valid fresh allowance`() throws {
        var claims = Self.fixtureClaims()
        var usage = try #require(claims["bundledCreditsUsage"] as? [String: Any])
        usage["usedThisCycle"] = 0
        claims["bundledCreditsUsage"] = usage
        let data = try Data(Self.sessionJSON(payload: claims).utf8)
        let snapshot = try VeniceWebUsageFetcher.snapshot(fromSessionData: data, now: Self.fixtureNow)
        #expect(snapshot.primary?.usedPercent == 0)
    }

    @Test
    func `sparse cookie chunks do not allocate by attacker supplied index`() {
        #expect(VeniceCookieHeader.header(from: [
            (name: "\(VeniceCookieHeader.sessionCookieName).0", value: "a"),
            (name: "\(VeniceCookieHeader.sessionCookieName).\(Int.max)", value: "b"),
        ]) == nil)
    }

    private static func fixtureClaims() -> [String: Any] {
        [
            "userType": "MAX",
            "bundledCredits": 9100,
            "veniceCredits": 9600,
            "email": "hidden@example.com",
            "sub": "should-not-become-identity",
            "exp": 1_893_456_000,
            "bundledCreditsUsage": [
                "availableCredits": 9100,
                "monthlyRefillCredits": 22500,
                "nextRefillAt": self.fixtureNextRefillAtMs,
                "tierCap": 67500,
                "usedThisCycle": 13400,
            ] as [String: Any],
        ]
    }

    private static func sessionJSON(payload: [String: Any]) throws -> String {
        let token = try Self.jwt(payload: payload)
        let data = try JSONSerialization.data(withJSONObject: ["token": token])
        return try #require(String(data: data, encoding: .utf8))
    }

    private static func jwt(payload: [String: Any]) throws -> String {
        let header = Self.base64URL(Data(#"{"alg":"none"}"#.utf8))
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        return "\(header).\(Self.base64URL(payloadData)).sig"
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func context(
        _ sourceMode: ProviderSourceMode,
        environment: [String: String] = [:],
        selectedTokenAccountID: UUID? = nil,
        settings: ProviderSettingsSnapshot? = nil) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: sourceMode,
            includeCredits: true,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: settings,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection,
            selectedTokenAccountID: selectedTokenAccountID)
    }

    private static func response(
        request: URLRequest,
        status: Int,
        body: String) throws -> (Data, URLResponse)
    {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]))
        return (Data(body.utf8), response)
    }
}
