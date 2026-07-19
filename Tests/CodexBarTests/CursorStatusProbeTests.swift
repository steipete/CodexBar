import Foundation
import SQLite3
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CursorStatusProbeTests {
    // MARK: - Usage Summary Parsing

    @Test
    func `parses basic usage summary`() throws {
        let json = """
        {
            "billingCycleStart": "2025-01-01T00:00:00.000Z",
            "billingCycleEnd": "2025-02-01T00:00:00.000Z",
            "membershipType": "pro",
            "individualUsage": {
                "plan": {
                    "enabled": true,
                    "used": 1500,
                    "limit": 5000,
                    "remaining": 3500,
                    "totalPercentUsed": 30.0
                },
                "onDemand": {
                    "enabled": true,
                    "used": 500,
                    "limit": 10000,
                    "remaining": 9500
                }
            },
            "teamUsage": {
                "onDemand": {
                    "enabled": true,
                    "used": 2000,
                    "limit": 50000,
                    "remaining": 48000
                }
            }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let summary = try JSONDecoder().decode(CursorUsageSummary.self, from: data)

        #expect(summary.membershipType == "pro")
        #expect(summary.individualUsage?.plan?.used == 1500)
        #expect(summary.individualUsage?.plan?.limit == 5000)
        #expect(summary.individualUsage?.plan?.totalPercentUsed == 30.0)
        #expect(summary.individualUsage?.onDemand?.used == 500)
        #expect(summary.teamUsage?.onDemand?.used == 2000)
        #expect(summary.teamUsage?.onDemand?.limit == 50000)
    }

    @Test
    func `parses minimal usage summary`() throws {
        let json = """
        {
            "membershipType": "hobby",
            "individualUsage": {
                "plan": {
                    "used": 0,
                    "limit": 2000
                }
            }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let summary = try JSONDecoder().decode(CursorUsageSummary.self, from: data)

        #expect(summary.membershipType == "hobby")
        #expect(summary.individualUsage?.plan?.used == 0)
        #expect(summary.individualUsage?.plan?.limit == 2000)
        #expect(summary.teamUsage == nil)
    }

    @Test
    func `parses enterprise usage summary`() throws {
        let json = """
        {
            "membershipType": "enterprise",
            "isUnlimited": true,
            "individualUsage": {
                "plan": {
                    "enabled": true,
                    "used": 50000,
                    "limit": 100000,
                    "totalPercentUsed": 50.0
                }
            }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let summary = try JSONDecoder().decode(CursorUsageSummary.self, from: data)

        #expect(summary.membershipType == "enterprise")
        #expect(summary.isUnlimited == true)
        #expect(summary.individualUsage?.plan?.totalPercentUsed == 50.0)
    }

    // MARK: - User Info Parsing

    @Test
    func `parses user info`() throws {
        let json = """
        {
            "email": "user@example.com",
            "email_verified": true,
            "name": "Test User",
            "sub": "auth0|12345"
        }
        """
        let data = try #require(json.data(using: .utf8))
        let userInfo = try JSONDecoder().decode(CursorUserInfo.self, from: data)

        #expect(userInfo.email == "user@example.com")
        #expect(userInfo.emailVerified == true)
        #expect(userInfo.name == "Test User")
        #expect(userInfo.sub == "auth0|12345")
    }

    // MARK: - Snapshot Conversion

    @Test
    func `prefers plan ratio over percent field`() {
        let snapshot = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
            .parseUsageSummary(
                CursorUsageSummary(
                    billingCycleStart: nil,
                    billingCycleEnd: nil,
                    membershipType: "enterprise",
                    limitType: nil,
                    isUnlimited: false,
                    autoModelSelectedDisplayMessage: nil,
                    namedModelSelectedDisplayMessage: nil,
                    individualUsage: CursorIndividualUsage(
                        plan: CursorPlanUsage(
                            enabled: true,
                            used: 4900,
                            limit: 50000,
                            remaining: nil,
                            breakdown: nil,
                            autoPercentUsed: nil,
                            apiPercentUsed: nil,
                            totalPercentUsed: 0.40625),
                        onDemand: nil),
                    teamUsage: nil),
                userInfo: nil,
                rawJSON: nil)

        // totalPercentUsed is already expressed in percentage units.
        #expect(snapshot.planPercentUsed == 0.40625)
    }

    @Test
    func `plan ratio caps at 100 percent when usage exceeds the limit`() {
        // Usage-based plan reporting only used/limit (no precomputed percent lanes), with the plan
        // cap exceeded (on-demand billing engaged). The headline percent must stay within [0, 100]
        // like every other planPercentUsed branch — overage is surfaced separately via on-demand USD.
        let snapshot = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
            .parseUsageSummary(
                CursorUsageSummary(
                    billingCycleStart: nil,
                    billingCycleEnd: nil,
                    membershipType: "pro",
                    limitType: nil,
                    isUnlimited: false,
                    autoModelSelectedDisplayMessage: nil,
                    namedModelSelectedDisplayMessage: nil,
                    individualUsage: CursorIndividualUsage(
                        plan: CursorPlanUsage(
                            enabled: true,
                            used: 15000,
                            limit: 10000,
                            remaining: nil,
                            breakdown: nil,
                            autoPercentUsed: nil,
                            apiPercentUsed: nil,
                            totalPercentUsed: nil),
                        onDemand: nil),
                    teamUsage: nil),
                userInfo: nil,
                rawJSON: nil)

        #expect(snapshot.planPercentUsed == 100)
    }

    @Test
    func `uses percent field when limit missing`() {
        let snapshot = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
            .parseUsageSummary(
                CursorUsageSummary(
                    billingCycleStart: nil,
                    billingCycleEnd: nil,
                    membershipType: "pro",
                    limitType: nil,
                    isUnlimited: false,
                    autoModelSelectedDisplayMessage: nil,
                    namedModelSelectedDisplayMessage: nil,
                    individualUsage: CursorIndividualUsage(
                        plan: CursorPlanUsage(
                            enabled: true,
                            used: 0,
                            limit: nil,
                            remaining: nil,
                            breakdown: nil,
                            autoPercentUsed: nil,
                            apiPercentUsed: nil,
                            totalPercentUsed: 0.5),
                        onDemand: nil),
                    teamUsage: nil),
                userInfo: nil,
                rawJSON: nil)

        #expect(snapshot.planPercentUsed == 0.5)
    }

    @Test
    func `headline total prefers provided total percent over lane average`() {
        let snapshot = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
            .parseUsageSummary(
                CursorUsageSummary(
                    billingCycleStart: nil,
                    billingCycleEnd: nil,
                    membershipType: "pro",
                    limitType: nil,
                    isUnlimited: false,
                    autoModelSelectedDisplayMessage: nil,
                    namedModelSelectedDisplayMessage: nil,
                    individualUsage: CursorIndividualUsage(
                        plan: CursorPlanUsage(
                            enabled: true,
                            used: 5400,
                            limit: 2000,
                            remaining: nil,
                            breakdown: nil,
                            autoPercentUsed: 0,
                            apiPercentUsed: 0.01,
                            totalPercentUsed: 0.27),
                        onDemand: nil),
                    teamUsage: nil),
                userInfo: nil,
                rawJSON: nil)

        #expect(snapshot.planPercentUsed == 0.27)
        #expect(snapshot.autoPercentUsed == 0)
        #expect(snapshot.apiPercentUsed == 0.01)
    }

    @Test
    func `sub pool percents accept plain percent scale`() {
        let snapshot = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
            .parseUsageSummary(
                CursorUsageSummary(
                    billingCycleStart: nil,
                    billingCycleEnd: nil,
                    membershipType: "pro",
                    limitType: nil,
                    isUnlimited: false,
                    autoModelSelectedDisplayMessage: nil,
                    namedModelSelectedDisplayMessage: nil,
                    individualUsage: CursorIndividualUsage(
                        plan: CursorPlanUsage(
                            enabled: true,
                            used: 0,
                            limit: 2000,
                            remaining: nil,
                            breakdown: nil,
                            autoPercentUsed: 12.5,
                            apiPercentUsed: 3.0,
                            totalPercentUsed: nil),
                        onDemand: nil),
                    teamUsage: nil),
                userInfo: nil,
                rawJSON: nil)

        #expect(snapshot.autoPercentUsed == 12.5)
        #expect(snapshot.apiPercentUsed == 3.0)
        // Dashboard-style total ≈ average of Auto and API lanes
        #expect(snapshot.planPercentUsed == 7.75)
    }

    @Test
    func `headline total matches dashboard blend when lanes match totalPercentUsed`() {
        let snapshot = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
            .parseUsageSummary(
                CursorUsageSummary(
                    billingCycleStart: nil,
                    billingCycleEnd: nil,
                    membershipType: "pro",
                    limitType: nil,
                    isUnlimited: false,
                    autoModelSelectedDisplayMessage: nil,
                    namedModelSelectedDisplayMessage: nil,
                    individualUsage: CursorIndividualUsage(
                        plan: CursorPlanUsage(
                            enabled: true,
                            used: 0,
                            limit: 2000,
                            remaining: nil,
                            breakdown: nil,
                            autoPercentUsed: 35,
                            apiPercentUsed: 97,
                            totalPercentUsed: 66),
                        onDemand: nil),
                    teamUsage: nil),
                userInfo: nil,
                rawJSON: nil)

        #expect(snapshot.planPercentUsed == 66)
        #expect(snapshot.autoPercentUsed == 35)
        #expect(snapshot.apiPercentUsed == 97)
    }

    @Test
    func `live cursor payload keeps fractional percents without scaling`() {
        let snapshot = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
            .parseUsageSummary(
                CursorUsageSummary(
                    billingCycleStart: "2026-03-18T20:45:42.000Z",
                    billingCycleEnd: "2026-04-18T20:45:42.000Z",
                    membershipType: "pro",
                    limitType: "user",
                    isUnlimited: false,
                    autoModelSelectedDisplayMessage: "You've used 1% of your included total usage",
                    namedModelSelectedDisplayMessage: "You've used 1% of your included API usage",
                    individualUsage: CursorIndividualUsage(
                        plan: CursorPlanUsage(
                            enabled: true,
                            used: 86,
                            limit: 2000,
                            remaining: 1914,
                            breakdown: CursorPlanBreakdown(
                                included: 86,
                                bonus: 0,
                                total: 86),
                            autoPercentUsed: 0.36,
                            apiPercentUsed: 0.7111111111111111,
                            totalPercentUsed: 0.441025641025641),
                        onDemand: CursorOnDemandUsage(
                            enabled: false,
                            used: 0,
                            limit: nil,
                            remaining: nil)),
                    teamUsage: CursorTeamUsage(onDemand: nil)),
                userInfo: nil,
                rawJSON: nil)

        #expect(snapshot.planPercentUsed == 0.441025641025641)
        #expect(snapshot.autoPercentUsed == 0.36)
        #expect(snapshot.apiPercentUsed == 0.7111111111111111)
        #expect(snapshot.billingCycleStart != nil)
        let usageSnapshot = snapshot.toUsageSnapshot()
        #expect(usageSnapshot.primary?.remainingPercent == 99.55897435897436)
        #expect(usageSnapshot.primary?.windowMinutes == 44640)
        #expect(usageSnapshot.secondary?.windowMinutes == 44640)
        #expect(usageSnapshot.tertiary?.windowMinutes == 44640)
    }

    @Test
    func `converts snapshot to usage snapshot`() throws {
        let snapshot = CursorStatusSnapshot(
            planPercentUsed: 45.0,
            autoPercentUsed: 5.0,
            apiPercentUsed: nil,
            planUsedUSD: 22.50,
            planLimitUSD: 50.0,
            onDemandUsedUSD: 5.0,
            onDemandLimitUSD: 100.0,
            teamOnDemandUsedUSD: 25.0,
            teamOnDemandLimitUSD: 500.0,
            billingCycleStart: Date(timeIntervalSince1970: 1_735_689_600), // Jan 1, 2025
            billingCycleEnd: Date(timeIntervalSince1970: 1_738_368_000), // Feb 1, 2025
            membershipType: "pro",
            accountEmail: "user@example.com",
            accountID: "auth0|12345",
            accountName: "Test User",
            rawJSON: nil)

        let usageSnapshot = snapshot.toUsageSnapshot()

        #expect(usageSnapshot.primary?.usedPercent == 45.0)
        #expect(usageSnapshot.accountEmail(for: .cursor) == "user@example.com")
        #expect(usageSnapshot.identity(for: .cursor)?.accountID == "auth0|12345")
        #expect(usageSnapshot.loginMethod(for: .cursor) == "Cursor Pro")
        #expect(usageSnapshot.secondary != nil)
        #expect(usageSnapshot.secondary?.usedPercent == 5.0)
        #expect(usageSnapshot.primary?.windowMinutes == 44640)
        #expect(usageSnapshot.secondary?.windowMinutes == 44640)
        #expect(usageSnapshot.providerCost?.used == 5.0)
        #expect(usageSnapshot.providerCost?.limit == 100.0)
        #expect(usageSnapshot.providerCost?.currencyCode == "USD")

        let roundTripped = try JSONDecoder().decode(
            UsageSnapshot.self,
            from: JSONEncoder().encode(usageSnapshot))
        #expect(roundTripped.identity(for: .cursor)?.accountID == "auth0|12345")
    }

    @Test
    func `provider cost includes on demand budget before first spend`() {
        let snapshot = CursorStatusSnapshot(
            planPercentUsed: 10.0,
            autoPercentUsed: 5.0,
            apiPercentUsed: nil,
            planUsedUSD: 5.0,
            planLimitUSD: 50.0,
            onDemandUsedUSD: 0,
            onDemandLimitUSD: 75.0,
            teamOnDemandUsedUSD: nil,
            teamOnDemandLimitUSD: nil,
            billingCycleEnd: nil,
            membershipType: "pro",
            accountEmail: nil,
            accountName: nil,
            rawJSON: nil)

        let usageSnapshot = snapshot.toUsageSnapshot()

        #expect(usageSnapshot.providerCost != nil)
        #expect(usageSnapshot.providerCost?.used == 0.0)
        #expect(usageSnapshot.providerCost?.limit == 75.0)
        #expect(usageSnapshot.providerCost?.period == "Monthly")
    }

    @Test
    func `uses individual on demand when no team usage`() {
        let snapshot = CursorStatusSnapshot(
            planPercentUsed: 10.0,
            autoPercentUsed: 20.0,
            apiPercentUsed: nil,
            planUsedUSD: 5.0,
            planLimitUSD: 50.0,
            onDemandUsedUSD: 12.0,
            onDemandLimitUSD: 60.0,
            teamOnDemandUsedUSD: nil,
            teamOnDemandLimitUSD: nil,
            billingCycleEnd: nil,
            membershipType: "pro",
            accountEmail: nil,
            accountName: nil,
            rawJSON: nil)

        let usageSnapshot = snapshot.toUsageSnapshot()

        #expect(usageSnapshot.secondary?.usedPercent == 20.0)
        #expect(usageSnapshot.providerCost?.used == 12.0)
        #expect(usageSnapshot.providerCost?.limit == 60.0)
    }

    @Test
    func `uses team on demand budget when individual usage has no cap`() {
        let snapshot = CursorStatusSnapshot(
            planPercentUsed: 0,
            autoPercentUsed: 0,
            apiPercentUsed: 0,
            planUsedUSD: 0,
            planLimitUSD: 20,
            onDemandUsedUSD: 0,
            onDemandLimitUSD: nil,
            teamOnDemandUsedUSD: 0,
            teamOnDemandLimitUSD: 2349,
            billingCycleEnd: nil,
            membershipType: "enterprise",
            accountEmail: nil,
            accountName: nil,
            rawJSON: nil)

        let usageSnapshot = snapshot.toUsageSnapshot()

        #expect(usageSnapshot.providerCost?.used == 0)
        #expect(usageSnapshot.providerCost?.limit == 2349)
        #expect(usageSnapshot.providerCost?.currencyCode == "USD")
    }

    @Test
    func `formats membership types`() {
        let testCases: [(input: String, expected: String)] = [
            ("pro", "Cursor Pro"),
            ("hobby", "Cursor Hobby"),
            ("enterprise", "Cursor Enterprise"),
            ("team", "Cursor Team"),
            ("custom", "Cursor Custom"),
        ]

        for testCase in testCases {
            let snapshot = CursorStatusSnapshot(
                planPercentUsed: 0,
                planUsedUSD: 0,
                planLimitUSD: 0,
                onDemandUsedUSD: 0,
                onDemandLimitUSD: nil,
                teamOnDemandUsedUSD: nil,
                teamOnDemandLimitUSD: nil,
                billingCycleEnd: nil,
                membershipType: testCase.input,
                accountEmail: nil,
                accountName: nil,
                rawJSON: nil)

            let usageSnapshot = snapshot.toUsageSnapshot()
            #expect(usageSnapshot.loginMethod(for: .cursor) == testCase.expected)
        }
    }

    @Test
    func `handles nil on demand limit`() {
        let snapshot = CursorStatusSnapshot(
            planPercentUsed: 50.0,
            planUsedUSD: 25.0,
            planLimitUSD: 50.0,
            onDemandUsedUSD: 10.0,
            onDemandLimitUSD: nil,
            teamOnDemandUsedUSD: nil,
            teamOnDemandLimitUSD: nil,
            billingCycleEnd: nil,
            membershipType: "pro",
            accountEmail: nil,
            accountName: nil,
            rawJSON: nil)

        let usageSnapshot = snapshot.toUsageSnapshot()

        // Should still have provider cost
        #expect(usageSnapshot.providerCost != nil)
        #expect(usageSnapshot.providerCost?.used == 10.0)
        #expect(usageSnapshot.providerCost?.limit == 0.0)
        // Secondary should be nil when no on-demand limit
        #expect(usageSnapshot.secondary == nil)
    }

    // MARK: - Legacy Request-Based Plan

    @Test
    func `parses legacy request based plan`() {
        let snapshot = CursorStatusSnapshot(
            planPercentUsed: 100.0,
            planUsedUSD: 0,
            planLimitUSD: 0,
            onDemandUsedUSD: 43.64,
            onDemandLimitUSD: 200.0,
            teamOnDemandUsedUSD: 92.91,
            teamOnDemandLimitUSD: 20000.0,
            billingCycleEnd: nil,
            membershipType: "enterprise",
            accountEmail: "user@company.com",
            accountName: "Test User",
            rawJSON: nil,
            requestsUsed: 500,
            requestsLimit: 500)

        #expect(snapshot.isLegacyRequestPlan == true)
        #expect(snapshot.requestsUsed == 500)
        #expect(snapshot.requestsLimit == 500)

        let usageSnapshot = snapshot.toUsageSnapshot()

        #expect(usageSnapshot.cursorRequests != nil)
        #expect(usageSnapshot.cursorRequests?.used == 500)
        #expect(usageSnapshot.cursorRequests?.limit == 500)
        #expect(usageSnapshot.cursorRequests?.usedPercent == 100.0)
        #expect(usageSnapshot.cursorRequests?.remainingPercent == 0.0)

        // Primary RateWindow should use request-based percentage for legacy plans
        #expect(usageSnapshot.primary?.usedPercent == 100.0)
    }

    @Test
    func `legacy plan primary uses requests not dollars`() {
        // Regression: Legacy plans report planPercentUsed as 0 while requests are used
        let snapshot = CursorStatusSnapshot(
            planPercentUsed: 0.0, // Dollar-based shows 0
            planUsedUSD: 0,
            planLimitUSD: 0,
            onDemandUsedUSD: 0,
            onDemandLimitUSD: nil,
            teamOnDemandUsedUSD: nil,
            teamOnDemandLimitUSD: nil,
            billingCycleEnd: nil,
            membershipType: "enterprise",
            accountEmail: "user@company.com",
            accountName: nil,
            rawJSON: nil,
            requestsUsed: 250,
            requestsLimit: 500)

        #expect(snapshot.isLegacyRequestPlan == true)

        let usageSnapshot = snapshot.toUsageSnapshot()

        // Primary should reflect request usage (50%), not dollar usage (0%)
        #expect(usageSnapshot.primary?.usedPercent == 50.0)
        #expect(usageSnapshot.cursorRequests?.usedPercent == 50.0)
    }

    @Test
    func `parse usage summary prefers request total`() {
        let summary = CursorUsageSummary(
            billingCycleStart: nil,
            billingCycleEnd: nil,
            membershipType: nil,
            limitType: nil,
            isUnlimited: nil,
            autoModelSelectedDisplayMessage: nil,
            namedModelSelectedDisplayMessage: nil,
            individualUsage: nil,
            teamUsage: nil)
        let requestUsage = CursorUsageResponse(
            gpt4: CursorModelUsage(
                numRequests: 120,
                numRequestsTotal: 240,
                numTokens: nil,
                maxRequestUsage: 500,
                maxTokenUsage: nil),
            startOfMonth: nil)

        let snapshot = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0)).parseUsageSummary(
            summary,
            userInfo: nil,
            rawJSON: nil,
            requestUsage: requestUsage)

        #expect(snapshot.requestsUsed == 240)
        #expect(snapshot.requestsLimit == 500)
    }

    @Test
    func `detects non legacy plan`() {
        let snapshot = CursorStatusSnapshot(
            planPercentUsed: 50.0,
            planUsedUSD: 25.0,
            planLimitUSD: 50.0,
            onDemandUsedUSD: 0,
            onDemandLimitUSD: 100.0,
            teamOnDemandUsedUSD: nil,
            teamOnDemandLimitUSD: nil,
            billingCycleEnd: nil,
            membershipType: "pro",
            accountEmail: nil,
            accountName: nil,
            rawJSON: nil)

        #expect(snapshot.isLegacyRequestPlan == false)
        #expect(snapshot.requestsUsed == nil)
        #expect(snapshot.requestsLimit == nil)

        let usageSnapshot = snapshot.toUsageSnapshot()
        #expect(usageSnapshot.cursorRequests == nil)
    }

    // MARK: - Session Store Serialization

    @Test
    func `session store saves and loads cookies`() async {
        let store = CursorSessionStore.shared

        // Clear any existing cookies
        await store.clearCookies()

        // Create test cookies with Date properties
        let cookieProps: [HTTPCookiePropertyKey: Any] = [
            .name: "testCookie",
            .value: "testValue",
            .domain: "cursor.com",
            .path: "/",
            .expires: Date(timeIntervalSince1970: 1_800_000_000),
            .secure: true,
        ]

        guard let cookie = HTTPCookie(properties: cookieProps) else {
            Issue.record("Failed to create test cookie")
            return
        }

        // Save cookies
        await store.setCookies([cookie])

        // Verify cookies are stored
        let storedCookies = await store.getCookies()
        #expect(storedCookies.count == 1)
        #expect(storedCookies.first?.name == "testCookie")
        #expect(storedCookies.first?.value == "testValue")

        // Clean up
        await store.clearCookies()
    }

    @Test
    func `session store reloads from disk when needed`() async {
        let store = CursorSessionStore.shared
        await store.resetForTesting()

        let cookieProps: [HTTPCookiePropertyKey: Any] = [
            .name: "diskCookie",
            .value: "diskValue",
            .domain: "cursor.com",
            .path: "/",
            .expires: Date(timeIntervalSince1970: 1_800_000_000),
            .secure: true,
        ]

        guard let cookie = HTTPCookie(properties: cookieProps) else {
            Issue.record("Failed to create test cookie")
            return
        }

        await store.setCookies([cookie])
        await store.resetForTesting(clearDisk: false)

        let reloaded = await store.getCookies()
        #expect(reloaded.count == 1)
        #expect(reloaded.first?.name == "diskCookie")
        #expect(reloaded.first?.value == "diskValue")

        await store.clearCookies()
    }

    @Test
    func `session store has valid session loads from disk`() async {
        let store = CursorSessionStore.shared
        await store.resetForTesting()

        let cookieProps: [HTTPCookiePropertyKey: Any] = [
            .name: "validCookie",
            .value: "validValue",
            .domain: "cursor.com",
            .path: "/",
            .expires: Date(timeIntervalSince1970: 1_800_000_000),
            .secure: true,
        ]

        guard let cookie = HTTPCookie(properties: cookieProps) else {
            Issue.record("Failed to create test cookie")
            return
        }

        await store.setCookies([cookie])
        await store.resetForTesting(clearDisk: false)

        let hasSession = await store.hasValidSession()
        #expect(hasSession)

        await store.clearCookies()
    }
}

private final class CursorStatusProbeTestSession {
    let urlSession: URLSession
    private let sessionID: String

    init(handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CursorStatusProbeStubURLProtocol.self]
        self.sessionID = CursorStatusProbeStubURLProtocol.configure(config, handler: handler)
        self.urlSession = URLSession(configuration: config)
    }

    deinit {
        self.urlSession.invalidateAndCancel()
        CursorStatusProbeStubURLProtocol.removeSession(self.sessionID)
    }

    var requestCount: Int {
        CursorStatusProbeStubURLProtocol.requests(for: self.sessionID).count
    }

    var requestPaths: [String] {
        CursorStatusProbeStubURLProtocol.requests(for: self.sessionID).compactMap { $0.url?.path }
    }

    var requestCookies: [String] {
        CursorStatusProbeStubURLProtocol.requests(for: self.sessionID)
            .compactMap { $0.value(forHTTPHeaderField: "Cookie") }
    }
}

private func makeCursorStatusProbeResponse(
    url: URL,
    body: String,
    statusCode: Int,
    contentType: String = "application/json") -> (HTTPURLResponse, Data)
{
    let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": contentType])!
    return (response, Data(body.utf8))
}

extension CursorStatusProbeTests {
    @Test
    func `app auth store reads Cursor global state database`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-app-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let dbURL = directory.appendingPathComponent("state.vscdb")
        var db: OpaquePointer?
        try #require(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        let sql = """
        CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value BLOB);
        INSERT INTO ItemTable VALUES('cursorAuth/accessToken', 'app-token');
        """
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)

        let session = try #require(try CursorAppAuthStore(dbPath: dbURL.path).loadSession())
        #expect(session == CursorAppAuthSession(accessToken: "app-token"))
    }

    @Test
    func `fetch ignores user info failure when usage summary succeeds`() async throws {
        let testSession = CursorStatusProbeTestSession { request in
            let requestURL = try #require(request.url)

            switch requestURL.path {
            case "/api/usage-summary":
                return makeCursorStatusProbeResponse(
                    url: requestURL,
                    body: """
                    {
                      "membershipType": "pro",
                      "individualUsage": {
                        "plan": {
                          "used": 1500,
                          "limit": 5000,
                          "totalPercentUsed": 30.0
                        }
                      }
                    }
                    """,
                    statusCode: 200)
            case "/api/auth/me":
                return makeCursorStatusProbeResponse(
                    url: requestURL,
                    body: #"{"error":"nope"}"#,
                    statusCode: 500)
            default:
                throw URLError(.badURL)
            }
        }

        let baseURL = try #require(URL(string: "https://cursor.test"))
        let snapshot = try await CursorStatusProbe(
            baseURL: baseURL,
            browserDetection: BrowserDetection(cacheTTL: 0),
            urlSession: testSession.urlSession).fetchWithManualCookies("auth=test")

        #expect(snapshot.planPercentUsed == 30.0)
        #expect(snapshot.accountEmail == nil)
        #expect(testSession.requestCount == 2)
    }

    @Test
    func `fetch fails cleanly when usage summary fails`() async {
        let testSession = CursorStatusProbeTestSession { request in
            let requestURL = try #require(request.url)

            switch requestURL.path {
            case "/api/usage-summary":
                return makeCursorStatusProbeResponse(
                    url: requestURL,
                    body: #"{"error":"denied"}"#,
                    statusCode: 500)
            case "/api/auth/me":
                return makeCursorStatusProbeResponse(
                    url: requestURL,
                    body: """
                    {
                      "email": "user@example.com",
                      "email_verified": true,
                      "name": "Test User",
                      "sub": "auth0|12345"
                    }
                    """,
                    statusCode: 200)
            default:
                throw URLError(.badURL)
            }
        }

        do {
            let baseURL = try #require(URL(string: "https://cursor.test"))
            _ = try await CursorStatusProbe(
                baseURL: baseURL,
                browserDetection: BrowserDetection(cacheTTL: 0),
                urlSession: testSession.urlSession).fetchWithManualCookies("auth=test")
            Issue.record("Expected usage summary failure to be surfaced")
        } catch let error as CursorStatusProbeError {
            guard case let .networkError(message) = error else {
                Issue.record("Expected networkError, got: \(error)")
                return
            }
            #expect(message == "HTTP 500")
            #expect(testSession.requestPaths.contains("/api/usage-summary"))
        } catch {
            Issue.record("Expected CursorStatusProbeError, got: \(error)")
        }
    }

    @Test
    func `fetch uses Cursor app local auth when browser cookies are unavailable`() async throws {
        let accessToken = try makeCursorAppAuthToken()
        let expectedCookie = "WorkosCursorSessionToken=user_test%3A%3A\(accessToken)"
        let testSession = CursorStatusProbeTestSession { request in
            let requestURL = try #require(request.url)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Cookie") == expectedCookie)
            #expect(request.httpMethod == "GET")

            switch requestURL.path {
            case "/api/usage-summary":
                return makeCursorStatusProbeResponse(
                    url: requestURL,
                    body: """
                    {
                      "membershipType": "pro",
                      "billingCycleStart": "2026-05-23T10:27:04.000Z",
                      "billingCycleEnd": "2026-06-23T10:27:04.000Z",
                      "individualUsage": {
                        "plan": {
                          "used": 388,
                          "limit": 2000,
                          "totalPercentUsed": 19.4
                        },
                        "onDemand": {
                          "used": 450,
                          "limit": 1000
                        }
                      }
                    }
                    """,
                    statusCode: 200)
            case "/api/auth/me":
                return makeCursorStatusProbeResponse(
                    url: requestURL,
                    body: #"{"email":"user@example.com","name":"Test User","sub":"auth0|user_test"}"#,
                    statusCode: 200)
            case "/api/usage":
                return makeCursorStatusProbeResponse(
                    url: requestURL,
                    body: #"{"gpt-4":{},"startOfMonth":"2026-05-23"}"#,
                    statusCode: 200)
            default:
                throw URLError(.badURL)
            }
        }

        CookieHeaderCache.clear(provider: .cursor)
        defer { CookieHeaderCache.clear(provider: .cursor) }
        let baseURL = try #require(URL(string: "https://cursor-web.test"))
        let snapshot = try await CursorStatusProbe(
            baseURL: baseURL,
            browserDetection: BrowserDetection(cacheTTL: 0),
            browserCookieImportOrder: [],
            urlSession: testSession.urlSession,
            appAuthStore: CursorAppAuthSessionProviderStub(session: CursorAppAuthSession(
                accessToken: accessToken))).fetch(allowCachedSessions: false)

        #expect(abs(snapshot.planPercentUsed - 19.4) < 0.0001)
        #expect(snapshot.planUsedUSD == 3.88)
        #expect(snapshot.planLimitUSD == 20.0)
        #expect(snapshot.onDemandUsedUSD == 4.5)
        #expect(snapshot.onDemandLimitUSD == 10.0)
        #expect(snapshot.membershipType == "pro")
        #expect(snapshot.accountID == "auth0|user_test")
        #expect(snapshot.accountEmail == "user@example.com")
        #expect(snapshot.accountName == "Test User")
        #expect(testSession.requestPaths.sorted() == [
            "/api/auth/me",
            "/api/usage",
            "/api/usage-summary",
        ])
    }

    @Test
    func `fetch can disable Cursor app auth during browser login verification`() async throws {
        let testSession = CursorStatusProbeTestSession { request in
            Issue.record("Disabled app auth unexpectedly requested \(request.url?.path ?? "<unknown>")")
            throw URLError(.badURL)
        }

        let baseURL = try #require(URL(string: "https://cursor-web.test"))
        let accessToken = try makeCursorAppAuthToken()
        let probe = CursorStatusProbe(
            baseURL: baseURL,
            browserDetection: BrowserDetection(cacheTTL: 0),
            browserCookieImportOrder: [],
            urlSession: testSession.urlSession,
            appAuthStore: CursorAppAuthSessionProviderStub(session: CursorAppAuthSession(
                accessToken: accessToken)))

        await #expect(throws: CursorStatusProbeError.self) {
            _ = try await probe.fetch(
                allowCachedSessions: false,
                allowAppAuthFallback: false)
        }
        #expect(testSession.requestCount == 0)
    }

    @Test
    func `fetch prefers stored session cookies before Cursor app auth fallback`() async throws {
        let store = CursorSessionStore.shared
        await store.clearCookies()
        defer {
            Task { await store.clearCookies() }
        }

        guard let cookie = HTTPCookie(properties: [
            .name: "WorkosCursorSessionToken",
            .value: "stored-session",
            .domain: "cursor.com",
            .path: "/",
            .secure: true,
        ]) else {
            Issue.record("Failed to create stored Cursor session cookie")
            return
        }
        await store.setCookies([cookie])

        let testSession = CursorStatusProbeTestSession { request in
            let requestURL = try #require(request.url)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Cookie") == "WorkosCursorSessionToken=stored-session")

            switch requestURL.path {
            case "/api/usage-summary":
                return makeCursorStatusProbeResponse(
                    url: requestURL,
                    body: """
                    {
                      "membershipType": "pro",
                      "individualUsage": {
                        "plan": {
                          "used": 1500,
                          "limit": 5000,
                          "totalPercentUsed": 30.0
                        }
                      }
                    }
                    """,
                    statusCode: 200)
            case "/api/auth/me":
                return makeCursorStatusProbeResponse(
                    url: requestURL,
                    body: #"{"email":"stored@example.com","name":"Stored User"}"#,
                    statusCode: 200)
            default:
                Issue.record("Stored-session precedence test unexpectedly requested \(requestURL.path)")
                throw URLError(.badURL)
            }
        }

        CookieHeaderCache.clear(provider: .cursor)
        defer { CookieHeaderCache.clear(provider: .cursor) }
        let baseURL = try #require(URL(string: "https://cursor.test"))
        let accessToken = try makeCursorAppAuthToken()
        let snapshot = try await CursorStatusProbe(
            baseURL: baseURL,
            browserDetection: BrowserDetection(cacheTTL: 0),
            browserCookieImportOrder: [],
            urlSession: testSession.urlSession,
            appAuthStore: CursorAppAuthSessionProviderStub(session: CursorAppAuthSession(
                accessToken: accessToken))).fetch()

        #expect(snapshot.planPercentUsed == 30.0)
        #expect(snapshot.accountEmail == "stored@example.com")
        #expect(testSession.requestPaths.sorted() == [
            "/api/auth/me",
            "/api/usage-summary",
        ])
    }

    @Test
    func `fetch with Cursor app auth preserves legacy request quotas`() async throws {
        let accessToken = try makeCursorAppAuthToken()
        let expectedCookie = "WorkosCursorSessionToken=user_test%3A%3A\(accessToken)"
        let testSession = CursorStatusProbeTestSession { request in
            let requestURL = try #require(request.url)
            #expect(request.value(forHTTPHeaderField: "Cookie") == expectedCookie)

            switch requestURL.path {
            case "/api/usage-summary":
                return makeCursorStatusProbeResponse(
                    url: requestURL,
                    body: """
                    {
                      "membershipType": "enterprise",
                      "individualUsage": {}
                    }
                    """,
                    statusCode: 200)
            case "/api/auth/me":
                return makeCursorStatusProbeResponse(
                    url: requestURL,
                    body: #"{"error":"temporary"}"#,
                    statusCode: 500)
            case "/api/usage":
                #expect(URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "user" })?.value == "user_test")
                return makeCursorStatusProbeResponse(
                    url: requestURL,
                    body: """
                    {
                      "gpt-4": {
                        "numRequests": 200,
                        "numRequestsTotal": 240,
                        "maxRequestUsage": 500
                      }
                    }
                    """,
                    statusCode: 200)
            default:
                throw URLError(.badURL)
            }
        }

        let baseURL = try #require(URL(string: "https://cursor.test"))
        let probe = CursorStatusProbe(
            baseURL: baseURL,
            browserDetection: BrowserDetection(cacheTTL: 0),
            urlSession: testSession.urlSession)

        let snapshot = try await probe.fetchWithAppAuthSession(CursorAppAuthSession(accessToken: accessToken))
        #expect(snapshot.requestsUsed == 240)
        #expect(snapshot.requestsLimit == 500)
        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 48)
        #expect(snapshot.accountEmail == nil)
        #expect(testSession.requestPaths.sorted() == [
            "/api/auth/me",
            "/api/usage",
            "/api/usage-summary",
        ])
    }

    @Test
    func `malformed Cursor app auth token is rejected before network access`() {
        let session = CursorAppAuthSession(accessToken: "not-a-jwt")
        #expect(throws: CursorStatusProbeError.self) {
            _ = try session.cookieHeader()
        }
        #expect(!session.isUsable)
    }

    @Test
    func `expired Cursor app auth token is skipped before network access`() async throws {
        let testSession = CursorStatusProbeTestSession { request in
            Issue.record("Expired app auth unexpectedly requested \(request.url?.path ?? "<unknown>")")
            throw URLError(.badURL)
        }

        let accessToken = try makeCursorAppAuthToken(expiration: Date(timeIntervalSinceNow: -60))
        let baseURL = try #require(URL(string: "https://cursor-web.test"))
        let probe = CursorStatusProbe(
            baseURL: baseURL,
            browserDetection: BrowserDetection(cacheTTL: 0),
            browserCookieImportOrder: [],
            urlSession: testSession.urlSession,
            appAuthStore: CursorAppAuthSessionProviderStub(session: CursorAppAuthSession(
                accessToken: accessToken)))

        await #expect(throws: CursorStatusProbeError.self) {
            _ = try await probe.fetch(allowCachedSessions: false)
        }
        #expect(testSession.requestCount == 0)
    }

    @Test
    func `Cursor app auth transient failure is preserved`() async throws {
        let testSession = CursorStatusProbeTestSession { request in
            let requestURL = try #require(request.url)
            return makeCursorStatusProbeResponse(
                url: requestURL,
                body: #"{"error":"temporary"}"#,
                statusCode: 500)
        }

        let accessToken = try makeCursorAppAuthToken()
        let baseURL = try #require(URL(string: "https://cursor-web.test"))
        let probe = CursorStatusProbe(
            baseURL: baseURL,
            browserDetection: BrowserDetection(cacheTTL: 0),
            browserCookieImportOrder: [],
            urlSession: testSession.urlSession,
            appAuthStore: CursorAppAuthSessionProviderStub(session: CursorAppAuthSession(
                accessToken: accessToken)))

        do {
            _ = try await probe.fetch(allowCachedSessions: false)
            Issue.record("Expected Cursor.app auth request to fail")
        } catch let error as CursorStatusProbeError {
            guard case .networkError = error else {
                Issue.record("Expected network error, got \(error)")
                return
            }
        }
    }

    @Test
    func `cached session transient failure does not switch to Cursor app auth`() async throws {
        CookieHeaderCache.store(provider: .cursor, cookieHeader: "cached=bad", sourceLabel: "test")
        defer {
            CookieHeaderCache.clear(provider: .cursor)
        }

        let accessToken = try makeCursorAppAuthToken()
        let appCookie = "WorkosCursorSessionToken=user_test%3A%3A\(accessToken)"
        let testSession = CursorStatusProbeTestSession { request in
            let requestURL = try #require(request.url)
            let cookie = request.value(forHTTPHeaderField: "Cookie")
            switch requestURL.path {
            case "/api/usage-summary" where cookie == "cached=bad":
                return makeCursorStatusProbeResponse(
                    url: requestURL,
                    body: #"{"error":"temporary"}"#,
                    statusCode: 500)
            case _ where cookie == appCookie:
                Issue.record("Transient cached-session failure unexpectedly switched to Cursor.app auth")
                throw URLError(.userAuthenticationRequired)
            default:
                throw URLError(.badURL)
            }
        }

        let baseURL = try #require(URL(string: "https://cursor-web.test"))
        let probe = CursorStatusProbe(
            baseURL: baseURL,
            browserDetection: BrowserDetection(cacheTTL: 0),
            browserCookieImportOrder: [],
            urlSession: testSession.urlSession,
            appAuthStore: CursorAppAuthSessionProviderStub(session: CursorAppAuthSession(
                accessToken: accessToken)))

        await #expect(throws: CursorStatusProbeError.self) {
            _ = try await probe.fetch()
        }
        #expect(testSession.requestCookies.contains("cached=bad"))
        #expect(!testSession.requestCookies.contains(appCookie))
    }

    @Test
    func `rejected selected session does not fall back to another account`() async throws {
        let selectedSession = CursorStatusProbe.BrowserLoginSession(
            cookieHeader: "selected=expired",
            sourceLabel: "Selected browser")
        #expect(CursorStatusProbe.commitBrowserLoginSession(selectedSession))
        defer { CookieHeaderCache.clear(provider: .cursor) }

        let accessToken = try makeCursorAppAuthToken()
        let appSession = CursorAppAuthSession(accessToken: accessToken)
        let appCookie = try appSession.cookieHeader()
        let testSession = CursorStatusProbeTestSession { request in
            let requestURL = try #require(request.url)
            let cookie = request.value(forHTTPHeaderField: "Cookie")
            if cookie == appCookie {
                Issue.record("Rejected selected session unexpectedly switched to Cursor.app auth")
                throw URLError(.userAuthenticationRequired)
            }
            return makeCursorStatusProbeResponse(
                url: requestURL,
                body: #"{"error":"unauthorized"}"#,
                statusCode: 401)
        }

        let baseURL = try #require(URL(string: "https://cursor-web.test"))
        let probe = CursorStatusProbe(
            baseURL: baseURL,
            browserDetection: BrowserDetection(cacheTTL: 0),
            browserCookieImportOrder: [],
            urlSession: testSession.urlSession,
            appAuthStore: CursorAppAuthSessionProviderStub(session: appSession))

        await #expect(throws: CursorStatusProbeError.self) {
            _ = try await probe.fetch()
        }
        await #expect(throws: CursorStatusProbeError.self) {
            _ = try await probe.fetch()
        }
        #expect(testSession.requestCookies.contains("selected=expired"))
        #expect(!testSession.requestCookies.contains(appCookie))
        #expect(CookieHeaderCache.load(provider: .cursor)?.authenticationFailurePolicy == .stopFallback)
    }

    @Test
    func `rejected stale request retries a concurrently selected session`() async throws {
        let staleSession = CursorStatusProbe.BrowserLoginSession(
            cookieHeader: "selected=stale",
            sourceLabel: "Stale browser")
        let replacementSession = CursorStatusProbe.BrowserLoginSession(
            cookieHeader: "selected=replacement",
            sourceLabel: "Replacement browser")
        #expect(CursorStatusProbe.commitBrowserLoginSession(staleSession))
        defer { CookieHeaderCache.clear(provider: .cursor) }

        let testSession = CursorStatusProbeTestSession { request in
            let requestURL = try #require(request.url)
            let cookie = request.value(forHTTPHeaderField: "Cookie")
            if cookie == staleSession.cookieHeader {
                #expect(CursorStatusProbe.commitBrowserLoginSession(replacementSession))
                return makeCursorStatusProbeResponse(
                    url: requestURL,
                    body: #"{"error":"unauthorized"}"#,
                    statusCode: 401)
            }
            #expect(cookie == replacementSession.cookieHeader)
            switch requestURL.path {
            case "/api/usage-summary":
                return makeCursorStatusProbeResponse(
                    url: requestURL,
                    body: #"{"membershipType":"pro","individualUsage":{}}"#,
                    statusCode: 200)
            case "/api/auth/me":
                return makeCursorStatusProbeResponse(
                    url: requestURL,
                    body: #"{"email":"replacement@example.com","sub":"auth0|replacement"}"#,
                    statusCode: 200)
            default:
                throw URLError(.badURL)
            }
        }

        let baseURL = try #require(URL(string: "https://cursor-web.test"))
        let snapshot = try await CursorStatusProbe(
            baseURL: baseURL,
            browserDetection: BrowserDetection(cacheTTL: 0),
            browserCookieImportOrder: [],
            urlSession: testSession.urlSession,
            appAuthStore: CursorAppAuthSessionProviderStub(session: nil)).fetch()

        #expect(snapshot.accountEmail == "replacement@example.com")
        #expect(CookieHeaderCache.load(provider: .cursor)?.cookieHeader == replacementSession.cookieHeader)
        #expect(CookieHeaderCache.load(provider: .cursor)?.authenticationFailurePolicy == .stopFallback)
    }

    @Test
    func `rejected selected session ignores an unselected cache replacement`() async throws {
        let selectedSession = CursorStatusProbe.BrowserLoginSession(
            cookieHeader: "selected=stale",
            sourceLabel: "Selected browser")
        #expect(CursorStatusProbe.commitBrowserLoginSession(selectedSession))
        defer { CookieHeaderCache.clear(provider: .cursor) }

        let testSession = CursorStatusProbeTestSession { request in
            let requestURL = try #require(request.url)
            let cookie = request.value(forHTTPHeaderField: "Cookie")
            if cookie == selectedSession.cookieHeader {
                #expect(!CookieHeaderCache.storeResult(
                    provider: .cursor,
                    cookieHeader: "background=replacement",
                    sourceLabel: "Background refresh"))
            } else {
                Issue.record("Rejected selected session unexpectedly switched to \(cookie ?? "<none>")")
            }
            return makeCursorStatusProbeResponse(
                url: requestURL,
                body: #"{"error":"unauthorized"}"#,
                statusCode: 401)
        }

        let baseURL = try #require(URL(string: "https://cursor-web.test"))
        let probe = CursorStatusProbe(
            baseURL: baseURL,
            browserDetection: BrowserDetection(cacheTTL: 0),
            browserCookieImportOrder: [],
            urlSession: testSession.urlSession,
            appAuthStore: CursorAppAuthSessionProviderStub(session: nil))

        await #expect(throws: CursorStatusProbeError.self) {
            _ = try await probe.fetch()
        }
        #expect(!testSession.requestCookies.contains("background=replacement"))
        #expect(CookieHeaderCache.load(provider: .cursor)?.cookieHeader == selectedSession.cookieHeader)
        #expect(CookieHeaderCache.load(provider: .cursor)?.authenticationFailurePolicy == .stopFallback)
    }
}

private func makeCursorAppAuthToken(
    subject: String = "auth0|user_test",
    expiration: Date = Date(timeIntervalSinceNow: 3600)) throws -> String
{
    let payload = try JSONSerialization.data(
        withJSONObject: [
            "exp": Int(expiration.timeIntervalSince1970),
            "sub": subject,
        ],
        options: [.sortedKeys])
    let encodedPayload = payload.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(encodedPayload).signature"
}

private struct CursorAppAuthSessionProviderStub: CursorAppAuthSessionProviding {
    let session: CursorAppAuthSession?

    func loadSession() throws -> CursorAppAuthSession? {
        self.session
    }
}

final class CursorStatusProbeStubURLProtocol: URLProtocol {
    private struct SessionState {
        var requests: [URLRequest] = []
        let handler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    }

    private static let sessionHeader = "X-CodexBar-Cursor-Test-Session"
    private static let lock = NSLock()
    private nonisolated(unsafe) static var sessions: [String: SessionState] = [:]

    static func configure(
        _ configuration: URLSessionConfiguration,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) -> String
    {
        let sessionID = UUID().uuidString
        self.lock.lock()
        self.sessions[sessionID] = SessionState(handler: handler)
        self.lock.unlock()
        configuration.httpAdditionalHeaders = [self.sessionHeader: sessionID]
        return sessionID
    }

    static func removeSession(_ sessionID: String) {
        self.lock.lock()
        self.sessions.removeValue(forKey: sessionID)
        self.lock.unlock()
    }

    static func requests(for sessionID: String) -> [URLRequest] {
        self.lock.lock()
        defer { Self.lock.unlock() }
        return self.sessions[sessionID]?.requests ?? []
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
        let sessionID = self.request.value(forHTTPHeaderField: Self.sessionHeader)
        Self.lock.lock()
        if let sessionID, var state = Self.sessions[sessionID] {
            state.requests.append(self.request)
            handler = state.handler
            Self.sessions[sessionID] = state
        } else {
            handler = nil
        }
        Self.lock.unlock()

        do {
            guard let handler else {
                throw URLError(.cancelled)
            }
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
