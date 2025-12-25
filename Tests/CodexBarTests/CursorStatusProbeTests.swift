import CodexBarCore
import Foundation
import Testing

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

        #expect(usageSnapshot.primary.usedPercent == 45.0)
        #expect(usageSnapshot.accountEmail == "user@example.com")
        #expect(usageSnapshot.loginMethod == "Cursor Pro")
        #expect(usageSnapshot.secondary != nil)
        #expect(usageSnapshot.providerCost != nil)
        #expect(usageSnapshot.providerCost?.currencyCode == "USD")
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
            #expect(usageSnapshot.loginMethod == testCase.expected)
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
        // Secondary should be nil when no team limit
        #expect(usageSnapshot.secondary == nil)
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
}

