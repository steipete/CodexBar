import Foundation
import Testing
@testable import CodexBarCore

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
        #expect(snapshot.toUsageSnapshot().primary?.remainingPercent == 99.55897435897436)
    }

    @Test
    func `converts snapshot to usage snapshot`() {
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
            billingCycleEnd: Date(timeIntervalSince1970: 1_738_368_000), // Feb 1, 2025
            membershipType: "pro",
            accountEmail: "user@example.com",
            accountName: "Test User",
            rawJSON: nil)

        let usageSnapshot = snapshot.toUsageSnapshot()

        #expect(usageSnapshot.primary?.usedPercent == 45.0)
        #expect(usageSnapshot.accountEmail(for: .cursor) == "user@example.com")
        #expect(usageSnapshot.loginMethod(for: .cursor) == "Cursor Pro")
        #expect(usageSnapshot.secondary != nil)
        #expect(usageSnapshot.secondary?.usedPercent == 5.0)
        #expect(usageSnapshot.providerCost?.used == 5.0)
        #expect(usageSnapshot.providerCost?.limit == 100.0)
        #expect(usageSnapshot.providerCost?.currencyCode == "USD")
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
