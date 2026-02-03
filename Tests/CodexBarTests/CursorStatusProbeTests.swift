import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct CursorStatusProbeTests {
    // MARK: - Usage Summary Parsing

    @Test
    func parsesBasicUsageSummary() throws {
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
    func parsesMinimalUsageSummary() throws {
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
    func parsesEnterpriseUsageSummary() throws {
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
    func parsesUserInfo() throws {
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
    func prefersPlanRatioOverPercentField() {
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

        #expect(snapshot.planPercentUsed == 9.8)
    }

    @Test
    func usesPercentFieldWhenLimitMissing() {
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

        #expect(snapshot.planPercentUsed == 50.0)
    }

    @Test
    func convertsSnapshotToUsageSnapshot() {
        let snapshot = CursorStatusSnapshot(
            planPercentUsed: 45.0,
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
        // Uses individual on-demand values (what users see in their dashboard)
        #expect(usageSnapshot.secondary?.usedPercent == 5.0)
        #expect(usageSnapshot.providerCost?.used == 5.0)
        #expect(usageSnapshot.providerCost?.limit == 100.0)
        #expect(usageSnapshot.providerCost?.currencyCode == "USD")
    }

    @Test
    func usesIndividualOnDemandWhenNoTeamUsage() {
        let snapshot = CursorStatusSnapshot(
            planPercentUsed: 10.0,
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
    func formatsMembershipTypes() {
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
    func handlesNilOnDemandLimit() {
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
    func parsesLegacyRequestBasedPlan() {
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
    func legacyPlanPrimaryUsesRequestsNotDollars() {
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
    func parseUsageSummaryPrefersRequestTotal() {
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
    func detectsNonLegacyPlan() {
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
    func sessionStoreSavesAndLoadsCookies() async {
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
    func sessionStoreReloadsFromDiskWhenNeeded() async {
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
    func sessionStoreHasValidSessionLoadsFromDisk() async {
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
