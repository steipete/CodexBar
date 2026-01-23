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
        let data = json.data(using: .utf8)!
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
        let data = json.data(using: .utf8)!
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
        let data = json.data(using: .utf8)!
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
        let data = json.data(using: .utf8)!
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

        // Primary meter shows effective percentage for non-legacy plans
        // totalUsed: $27.50, effectiveBudget: $40 (Pro) + $100 (on-demand) = $140
        // effectivePercent: 27.50/140 * 100 = 19.64%
        let expectedPercent = (27.50 / 140.0) * 100
        #expect(usageSnapshot.primary?.usedPercent == expectedPercent)
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
    func sessionStoreSavesAndLoadsCookies() async throws {
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
    func sessionStoreReloadsFromDiskWhenNeeded() async throws {
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
    func sessionStoreHasValidSessionLoadsFromDisk() async throws {
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

    // MARK: - Plan Tier Detection

    @Test
    func detectsPlanTierFromMembershipType() {
        let testCases: [(input: String?, expected: CursorPlanTier)] = [
            ("hobby", .hobby),
            ("pro", .pro),
            ("pro+", .proPlus),
            ("pro_plus", .proPlus),
            ("proplus", .proPlus),
            ("ultra", .ultra),
            ("team", .team),
            ("enterprise", .enterprise),
            ("PRO+", .proPlus), // Case insensitive
            ("ULTRA", .ultra),
            (nil, .unknown),
            ("unknown_plan", .unknown),
        ]

        for testCase in testCases {
            let tier = CursorPlanTier(membershipType: testCase.input)
            #expect(tier == testCase.expected, "Expected \(testCase.expected) for '\(testCase.input ?? "nil")', got \(tier)")
        }
    }

    @Test
    func planTierEffectiveBudgets() {
        #expect(CursorPlanTier.hobby.effectiveBudgetUSD == 20)
        #expect(CursorPlanTier.pro.effectiveBudgetUSD == 40)
        #expect(CursorPlanTier.proPlus.effectiveBudgetUSD == 120)
        #expect(CursorPlanTier.ultra.effectiveBudgetUSD == 800)
        #expect(CursorPlanTier.team.effectiveBudgetUSD == 60)
        #expect(CursorPlanTier.enterprise.effectiveBudgetUSD == 40)
        #expect(CursorPlanTier.unknown.effectiveBudgetUSD == 40)
    }

    // MARK: - Effective Budget Calculations

    @Test
    func calculatesEffectivePercentageForUltraPlan() {
        // Ultra user with $300 used, $200 on-demand limit
        // Effective budget = $800 (Ultra) + $200 (on-demand) = $1000
        // Effective percentage = $300 / $1000 = 30%
        let snapshot = CursorStatusSnapshot(
            planPercentUsed: 150.0, // Old calculation would show 150% (300/200)
            planUsedUSD: 300.0,
            planLimitUSD: 200.0, // API returns nominal price
            onDemandUsedUSD: 100.0,
            onDemandLimitUSD: 200.0,
            teamOnDemandUsedUSD: nil,
            teamOnDemandLimitUSD: nil,
            billingCycleEnd: nil,
            membershipType: "ultra",
            accountEmail: "user@example.com",
            accountName: nil,
            rawJSON: nil,
            planTier: .ultra)

        // Verify effective calculations
        #expect(snapshot.totalUsedUSD == 400.0) // 300 plan + 100 on-demand
        #expect(snapshot.effectiveBudgetUSD == 1000.0) // 800 Ultra + 200 on-demand
        #expect(snapshot.effectivePercentUsed == 40.0) // 400 / 1000 * 100
        #expect(snapshot.isPlanExhausted == true) // on-demand > 0
    }

    @Test
    func calculatesEffectivePercentageForProPlusPlan() {
        // Pro+ user with $80 used, no on-demand yet
        // Effective budget = $120 (Pro+) + $0 = $120
        // Effective percentage = $80 / $120 = 66.67%
        let snapshot = CursorStatusSnapshot(
            planPercentUsed: 133.33, // Old calculation: 80/60 = 133%
            planUsedUSD: 80.0,
            planLimitUSD: 60.0, // API returns nominal price
            onDemandUsedUSD: 0,
            onDemandLimitUSD: 100.0,
            teamOnDemandUsedUSD: nil,
            teamOnDemandLimitUSD: nil,
            billingCycleEnd: nil,
            membershipType: "pro+",
            accountEmail: nil,
            accountName: nil,
            rawJSON: nil,
            planTier: .proPlus)

        #expect(snapshot.totalUsedUSD == 80.0)
        #expect(snapshot.effectiveBudgetUSD == 220.0) // 120 Pro+ + 100 on-demand limit
        #expect(abs(snapshot.effectivePercentUsed - 36.36) < 0.1) // ~36.36%
        #expect(snapshot.isPlanExhausted == false)
    }

    @Test
    func usageSnapshotUsesEffectivePercentageForHigherTiers() {
        let snapshot = CursorStatusSnapshot(
            planPercentUsed: 150.0,
            planUsedUSD: 300.0,
            planLimitUSD: 200.0,
            onDemandUsedUSD: 100.0,
            onDemandLimitUSD: 200.0,
            teamOnDemandUsedUSD: nil,
            teamOnDemandLimitUSD: nil,
            billingCycleEnd: nil,
            membershipType: "ultra",
            accountEmail: nil,
            accountName: nil,
            rawJSON: nil,
            planTier: .ultra)

        let usageSnapshot = snapshot.toUsageSnapshot()

        // Primary window uses effective percentage for higher-tier plans
        // totalUsed: $400, effectiveBudget: $800 (Ultra) + $200 (on-demand) = $1000
        // effectivePercent: 400/1000 * 100 = 40%
        #expect(usageSnapshot.primary?.usedPercent == 40.0)

        // cursorEffectiveUsage is populated for menu display context
        #expect(usageSnapshot.cursorEffectiveUsage != nil)
        #expect(usageSnapshot.cursorEffectiveUsage?.planTier == .ultra)
        #expect(usageSnapshot.cursorEffectiveUsage?.totalUsedUSD == 400.0)
        #expect(usageSnapshot.cursorEffectiveUsage?.effectiveBudgetUSD == 1000.0)
        #expect(usageSnapshot.cursorEffectiveUsage?.isPlanExhausted == true)
    }

    @Test
    func effectiveUsageNotPopulatedForLegacyPlans() {
        let snapshot = CursorStatusSnapshot(
            planPercentUsed: 100.0,
            planUsedUSD: 0,
            planLimitUSD: 0,
            onDemandUsedUSD: 0,
            onDemandLimitUSD: nil,
            teamOnDemandUsedUSD: nil,
            teamOnDemandLimitUSD: nil,
            billingCycleEnd: nil,
            membershipType: "enterprise",
            accountEmail: nil,
            accountName: nil,
            rawJSON: nil,
            requestsUsed: 250,
            requestsLimit: 500)

        let usageSnapshot = snapshot.toUsageSnapshot()

        // Legacy plans should not have cursorEffectiveUsage
        #expect(usageSnapshot.cursorEffectiveUsage == nil)
        // But should still have cursorRequests
        #expect(usageSnapshot.cursorRequests != nil)
        #expect(usageSnapshot.cursorRequests?.used == 250)
    }

    @Test
    func parseUsageSummaryIncludesPlanTier() {
        let summary = CursorUsageSummary(
            billingCycleStart: nil,
            billingCycleEnd: nil,
            membershipType: "ultra",
            limitType: nil,
            isUnlimited: nil,
            autoModelSelectedDisplayMessage: nil,
            namedModelSelectedDisplayMessage: nil,
            individualUsage: CursorIndividualUsage(
                plan: CursorPlanUsage(
                    enabled: true,
                    used: 30000, // $300 in cents
                    limit: 20000, // $200 in cents
                    remaining: nil,
                    breakdown: nil,
                    autoPercentUsed: nil,
                    apiPercentUsed: nil,
                    totalPercentUsed: nil),
                onDemand: CursorOnDemandUsage(
                    enabled: true,
                    used: 10000, // $100 in cents
                    limit: 20000, // $200 in cents
                    remaining: nil)),
            teamUsage: nil)

        let snapshot = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0)).parseUsageSummary(
            summary,
            userInfo: nil,
            rawJSON: nil)

        #expect(snapshot.planTier == .ultra)
        #expect(snapshot.effectiveBudgetUSD == 1000.0) // 800 Ultra + 200 on-demand
        #expect(snapshot.totalUsedUSD == 400.0) // 300 plan + 100 on-demand
        #expect(snapshot.effectivePercentUsed == 40.0)
    }
}
