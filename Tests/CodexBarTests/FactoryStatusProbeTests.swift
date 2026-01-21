import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct FactoryStatusSnapshotTests {
    @Test
    func mapsUsageSnapshotWindowsAndLoginMethod() {
        let periodEnd = Date(timeIntervalSince1970: 1_738_368_000) // Feb 1, 2025
        let snapshot = FactoryStatusSnapshot(
            standardUserTokens: 50,
            standardOrgTokens: 0,
            standardAllowance: 100,
            premiumUserTokens: 25,
            premiumOrgTokens: 0,
            premiumAllowance: 50,
            periodStart: nil,
            periodEnd: periodEnd,
            planName: "Pro",
            tier: "enterprise",
            organizationName: "Acme",
            accountEmail: "user@example.com",
            userId: "user-1",
            rawJSON: nil)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 50)
        #expect(usage.primary?.resetsAt == periodEnd)
        #expect(usage.primary?.resetDescription?.hasPrefix("Resets ") == true)
        #expect(usage.secondary?.usedPercent == 50)
        #expect(usage.loginMethod(for: .factory) == "Factory Enterprise - Pro")
    }

    @Test
    func treatsLargeAllowancesAsUnlimited() {
        let snapshot = FactoryStatusSnapshot(
            standardUserTokens: 50_000_000,
            standardOrgTokens: 0,
            standardAllowance: 2_000_000_000_000,
            premiumUserTokens: 0,
            premiumOrgTokens: 0,
            premiumAllowance: 0,
            periodStart: nil,
            periodEnd: nil,
            planName: nil,
            tier: nil,
            organizationName: nil,
            accountEmail: nil,
            userId: nil,
            rawJSON: nil)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 50)
    }

    @Test
    func prefersAPIUsedRatioOverCalculation() {
        // Simulates Factory Max plan where totalAllowance may be missing/zero
        // but usedRatio is provided by the API (72,311,737 / 200,000,000 ≈ 0.3616)
        let snapshot = FactoryStatusSnapshot(
            standardUserTokens: 72_311_737,
            standardOrgTokens: 72_311_737,
            standardAllowance: 0, // API may not return allowance
            standardUsedRatio: 0.3615586850, // API provides correct ratio
            premiumUserTokens: 0,
            premiumOrgTokens: 0,
            premiumAllowance: 0,
            premiumUsedRatio: 0.0,
            periodStart: nil,
            periodEnd: nil,
            planName: "Max",
            tier: nil,
            organizationName: nil,
            accountEmail: nil,
            userId: nil,
            rawJSON: nil)

        let usage = snapshot.toUsageSnapshot()

        // Should use API ratio (36.16%) instead of falling back to 0%
        #expect(usage.primary?.usedPercent ?? 0 > 36)
        #expect(usage.primary?.usedPercent ?? 0 < 37)
    }

    @Test
    func fallsBackToCalculationWhenAPIRatioMissing() {
        let snapshot = FactoryStatusSnapshot(
            standardUserTokens: 50_000_000,
            standardOrgTokens: 0,
            standardAllowance: 100_000_000,
            standardUsedRatio: nil, // No API ratio provided
            premiumUserTokens: 0,
            premiumOrgTokens: 0,
            premiumAllowance: 0,
            premiumUsedRatio: nil,
            periodStart: nil,
            periodEnd: nil,
            planName: nil,
            tier: nil,
            organizationName: nil,
            accountEmail: nil,
            userId: nil,
            rawJSON: nil)

        let usage = snapshot.toUsageSnapshot()

        // Should calculate: 50M / 100M = 50%
        #expect(usage.primary?.usedPercent == 50)
    }

    @Test
    func fallsBackWhenAPIRatioIsInvalid() {
        // Test with out-of-range ratio (> 1.0) - should fall back to calculation
        let snapshot = FactoryStatusSnapshot(
            standardUserTokens: 50_000_000,
            standardOrgTokens: 0,
            standardAllowance: 100_000_000,
            standardUsedRatio: 1.5, // Invalid: > 1.0
            premiumUserTokens: 0,
            premiumOrgTokens: 0,
            premiumAllowance: 0,
            premiumUsedRatio: -0.5, // Invalid: < 0
            periodStart: nil,
            periodEnd: nil,
            planName: nil,
            tier: nil,
            organizationName: nil,
            accountEmail: nil,
            userId: nil,
            rawJSON: nil)

        let usage = snapshot.toUsageSnapshot()

        // Should fall back to calculation: 50M / 100M = 50%
        #expect(usage.primary?.usedPercent == 50)
    }

    @Test
    func clampsSlightlyOutOfRangeRatios() {
        // Test with ratio slightly > 1.0 due to floating point (should clamp, not fall back)
        let snapshot = FactoryStatusSnapshot(
            standardUserTokens: 100_000_000,
            standardOrgTokens: 0,
            standardAllowance: 100_000_000,
            standardUsedRatio: 1.0005, // Slightly over due to rounding
            premiumUserTokens: 0,
            premiumOrgTokens: 0,
            premiumAllowance: 0,
            premiumUsedRatio: nil,
            periodStart: nil,
            periodEnd: nil,
            planName: nil,
            tier: nil,
            organizationName: nil,
            accountEmail: nil,
            userId: nil,
            rawJSON: nil)

        let usage = snapshot.toUsageSnapshot()

        // Should clamp to 100% (not fall back)
        #expect(usage.primary?.usedPercent == 100)
    }
}

@Suite
struct FactoryStatusProbeWorkOSTests {
    @Test
    func detectsMissingRefreshTokenPayload() {
        let payload = Data("""
        {"error":"invalid_request","error_description":"Missing refresh token."}
        """.utf8)

        #expect(FactoryStatusProbe.isMissingWorkOSRefreshToken(payload))
    }
}
