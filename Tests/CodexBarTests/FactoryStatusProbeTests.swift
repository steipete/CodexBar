import Foundation
import Testing
@testable import CodexBarCore

struct FactoryStatusSnapshotTests {
    @Test
    func `maps usage snapshot windows and login method`() {
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
    func `treats large allowances as unlimited`() {
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
    func `prefers API used ratio when allowance missing`() {
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
    func `uses percent scale ratio when allowance missing`() {
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
    func `falls back to calculation when API ratio is zero but usage and allowance are present`() {
        let snapshot = FactoryStatusSnapshot(
            standardUserTokens: 5_826_293,
            standardOrgTokens: 0,
            standardAllowance: 20_000_000,
            standardUsedRatio: 0,
            premiumUserTokens: 0,
            premiumOrgTokens: 0,
            premiumAllowance: 0,
            premiumUsedRatio: 0,
            periodStart: nil,
            periodEnd: nil,
            planName: nil,
            tier: nil,
            organizationName: nil,
            accountEmail: nil,
            userId: nil,
            rawJSON: nil)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent ?? 0 > 29)
        #expect(usage.primary?.usedPercent ?? 0 < 30)
        #expect(usage.secondary?.usedPercent == 0)
    }

    @Test
    func `falls back to calculation when API ratio missing`() {
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
    func `falls back when API ratio is invalid`() {
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
    func `clamps slightly out of range ratios`() {
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

struct FactoryStatusProbeWorkOSTests {
    @Test
    func `detects missing refresh token payload`() {
        let payload = Data("""
        {"error":"invalid_request","error_description":"Missing refresh token."}
        """.utf8)

        #expect(FactoryStatusProbe.isMissingWorkOSRefreshToken(payload))
    }
}
