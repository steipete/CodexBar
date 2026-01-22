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
    func prefersAPIUsedRatioWhenAllowanceMissing() {
        let snapshot = FactoryStatusSnapshot(
            standardUserTokens: 72_311_737,
            standardOrgTokens: 72_311_737,
            standardAllowance: 0,
            standardUsedRatio: 0.3615586850,
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

        #expect(usage.primary?.usedPercent ?? 0 > 36)
        #expect(usage.primary?.usedPercent ?? 0 < 37)
    }

    @Test
    func usesPercentScaleRatioWhenAllowanceMissing() {
        let snapshot = FactoryStatusSnapshot(
            standardUserTokens: 0,
            standardOrgTokens: 0,
            standardAllowance: 0,
            standardUsedRatio: 10.0,
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

        #expect(usage.primary?.usedPercent == 10)
    }

    @Test
    func fallsBackToCalculationWhenAPIRatioMissing() {
        let snapshot = FactoryStatusSnapshot(
            standardUserTokens: 50_000_000,
            standardOrgTokens: 0,
            standardAllowance: 100_000_000,
            standardUsedRatio: nil,
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

        #expect(usage.primary?.usedPercent == 50)
    }

    @Test
    func fallsBackWhenAPIRatioIsInvalid() {
        let snapshot = FactoryStatusSnapshot(
            standardUserTokens: 50_000_000,
            standardOrgTokens: 0,
            standardAllowance: 100_000_000,
            standardUsedRatio: 1.5,
            premiumUserTokens: 0,
            premiumOrgTokens: 0,
            premiumAllowance: 0,
            premiumUsedRatio: -0.5,
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
    func clampsSlightlyOutOfRangeRatios() {
        let snapshot = FactoryStatusSnapshot(
            standardUserTokens: 100_000_000,
            standardOrgTokens: 0,
            standardAllowance: 100_000_000,
            standardUsedRatio: 1.0005,
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
